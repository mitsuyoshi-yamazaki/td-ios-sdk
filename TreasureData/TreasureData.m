//
//  TreasureData.m
//  TreasureData
//
//  Created by Mitsunori Komatsu on 5/19/14.
//  Copyright (c) 2014 Treasure Data Inc. All rights reserved.
//
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import "TreasureData.h"
#import "Deflate.h"
#import "KeenClient.h"

static bool isTraceLoggingEnabled = false;
static bool isEventCompressionEnabled = true;
static TreasureData *sharedInstance = nil;
static NSString *tableNamePattern = @"[^0-9a-z_]";
static NSString *version = @"0.1.5";
static NSString *defaultApiEndpoint = nil;
static NSString *storage_key_of_uuid = @"td_sdk_uuid";
static NSString *storage_key_of_first_run = @"td_sdk_first_run";
static NSString *key_of_uuid = @"td_uuid";
static NSString *key_of_board = @"td_board";
static NSString *key_of_brand = @"td_brand";
static NSString *key_of_device = @"td_device";
static NSString *key_of_display = @"td_display";
static NSString *key_of_model = @"td_model";
static NSString *key_of_os_ver = @"td_os_ver";
static NSString *key_of_os_type = @"td_os_type";
static NSString *os_type = @"iOS";

@interface TDClient : KeenClient
@property(nonatomic, strong) NSString *apiKey;
@property(nonatomic, strong) NSString *apiEndpoint;
@end

@implementation TDClient
- (NSData *)sendEvents:(NSData *)data returningResponse:(NSURLResponse **)response error:(NSError **)error {
    NSString *urlString = [NSString stringWithFormat:@"%@/%@", self.apiEndpoint, @"ios/v3/event"];
    KCLog(@"Sending events to: %@", urlString);
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:self.apiKey forHTTPHeaderField:@"X-TD-Write-Key"];
    [request setValue:@"k" forHTTPHeaderField:@"X-TD-Data-Type"];   // means KeenIO data type
    [request setValue:[NSString stringWithFormat:@"TD-iOS-SDK/%@ (%@ %@)", version, [[UIDevice currentDevice] systemName], [[UIDevice currentDevice] systemVersion]] forHTTPHeaderField:@"User-Agent"];

    if (isEventCompressionEnabled) {
        NSData *compressedData = [Deflate deflate:data];
        if (!compressedData) {
            KCLog(@"Compression failed");
        }
        else {
            KCLog(@"Compressed: before=%ld, after=%ld", (unsigned long)[data length], (unsigned long)[compressedData length]);
            data = compressedData;
            /*
             Byte* bytes = [data bytes];
             for (int i=0; i < [data length]; i++) {
             NSLog(@"byte[%d]: 0x%02x", i, bytes[i]);
             }
             */      
            [request setValue:@"deflate" forHTTPHeaderField:@"Content-Encoding"];
        }
    }

    [request setHTTPBody:data];

    NSData *responseData = [NSURLConnection sendSynchronousRequest:request returningResponse:response error:error];

    return responseData;
}

@end

@interface TreasureData ()
@property(nonatomic, strong) TDClient *client;
@property BOOL autoAppendUniqId;
@property BOOL autoAppendModelInformation;
@end

@implementation TreasureData
- (id)initWithApiKey:(NSString *)apiKey {
    [KeenClient disableGeoLocation];

    self = [self init];

    if (self) {
        /*
         * This client uses the parent's resources as follows:
         *
         *  - global_dispatch_queue
         *    - Although the client uses the same label when calling dispatch_queue_create(),
         *      dispatch_queue_create() returns the different queue and there is no conflict with
         *      the parent client.
         *
         *  - cache directory
         *    - Although the client uses the same root directory,
         *      the client uses a special project id which is not conflicted with
         *      the parent client's project ids.
         *
         */
        NSString *projectId = [NSString stringWithFormat:@"_td %@", [self md5:apiKey]];
        
        self.client = [[TDClient alloc] initWithProjectId:projectId andWriteKey:@"dummy_write_key" andReadKey:@"dummy_read_key"];
        if (self.client) {
            self.client.apiKey = apiKey;
            self.client.apiEndpoint = defaultApiEndpoint ? defaultApiEndpoint : @"https://in.treasuredata.com";
            self.client.globalPropertiesBlock = ^NSDictionary *(NSString *eventCollection) {
                if (!NSClassFromString(@"NSUUID")) {
                    return @{};
                }
                return @{@"#UUID": [[NSUUID UUID] UUIDString]};
            };
        }
        else {
            KCLog(@"Failed to initialize client");
        }
    }
    return self;
}


- (NSString *) md5:(NSString *) input
{
    const char *cStr = [input UTF8String];
    unsigned char digest[16];
    CC_MD5(cStr, (CC_LONG)strlen(cStr), digest);
    
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    
    for(int i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
        [output appendFormat:@"%02x", digest[i]];
    
    return output;
}

- (void)event:(NSDictionary *)record table:(NSString *)table {
    [self addEvent:record table:table];
}

- (void)event:(NSDictionary *)record database:(NSString *)database table:(NSString *)table {
    [self addEvent:record database:database table:table];
}

- (void)addEvent:(NSDictionary *)record table:(NSString *)table {
    [self addEvent:record database:self.defaultDatabase table:table];
}

- (void)addEvent:(NSDictionary *)record database:(NSString *)database table:(NSString *)table {
    [self addEventWithCallback:record database:database table:table onSuccess:nil onError:nil];
}

- (void)addEventWithCallback:(NSDictionary *)record database:(NSString *)database table:(NSString *)table onSuccess:(void (^)())onSuccess onError:(void (^)(NSString*, NSString*))onError {
    if (self.client) {
        if (database && table) {
            NSError *error = nil;
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9a-z_]{3,255}$" options:0 error:&error];
            if (!([regex firstMatchInString:database options:0 range:NSMakeRange(0, [database length])] &&
                  [regex firstMatchInString:table    options:0 range:NSMakeRange(0, [table length])])) {
                NSString *errMsg = [NSString stringWithFormat:@"database and table need to be consist of lower letters, numbers or '_': database=%@, table=%@", database, table];
                KCLog(@"%@", errMsg);
                onError(ERROR_CODE_INVALID_PARAM, errMsg);
            }
            else {
                if (self.autoAppendUniqId) {
                    record = [self appendUniqId:record];
                }
                if (self.autoAppendModelInformation) {
                    record = [self appendModelInformation:record];
                }
                NSString *tag = [NSString stringWithFormat:@"%@.%@", database, table];
                [self.client addEventWithCallbacks:record toEventCollection:tag onSuccess:onSuccess onError:onError];
            }
        }
        else {
            NSString *errMsg = [NSString stringWithFormat:@"database or table is nil: database=%@, table=%@", database, table];
            KCLog(@"%@", errMsg);
            onError(ERROR_CODE_INVALID_PARAM, errMsg);
        }
    }
    else {
        NSString *errMsg = @"Client is nil";
        KCLog(@"%@", errMsg);
        onError(ERROR_CODE_INIT_ERROR, errMsg);
    }
}

- (void)addEventWithCallback:(NSDictionary *)record table:(NSString *)table onSuccess:(void (^)())onSuccess onError:(void (^)(NSString*, NSString*))onError {
    [self addEventWithCallback:record database:self.defaultDatabase table:table onSuccess:onSuccess onError:onError];
}

- (NSString*)getUUID {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *uuid = [ud stringForKey:storage_key_of_uuid];
    if (!uuid) {
        if (!NSClassFromString(@"NSUUID")) {
            uuid = @"";
        }
        uuid = [[NSUUID UUID] UUIDString];
        [ud setObject:uuid forKey:storage_key_of_uuid];
        [ud synchronize];
    }
    return uuid;
}

- (NSDictionary*)appendUniqId:(NSDictionary *)origRecord {
    NSMutableDictionary *record = [NSMutableDictionary dictionaryWithDictionary:origRecord];
    [record setValue:[self getUUID] forKey:key_of_uuid];
    return record;
}

- (NSDictionary*)appendModelInformation:(NSDictionary *)origRecord {
    NSMutableDictionary *record = [NSMutableDictionary dictionaryWithDictionary:origRecord];
    UIDevice *dev = [UIDevice currentDevice];
    // [record setValue:@"" forKey:key_of_board];
    // [record setValue:@"" forKey:key_of_brand];
    [record setValue:dev.name forKey:key_of_device];
    // [record setValue:@"" forKey:key_of_display];
    [record setValue:dev.model forKey:key_of_model];
    [record setValue:dev.systemVersion forKey:key_of_os_ver];
    [record setValue:os_type forKey:key_of_os_type];
    return record;
}

- (void)uploadWithBlock:(void (^)())block {
    [self uploadEventsWithBlock:block];
}

- (void)uploadEventsWithBlock:(void (^)())block {
    if (self.client) {
        [self.client uploadWithFinishedBlock:block];
    }
    else {
        KCLog(@"Client is nil");
    }
}

- (void)uploadEventsWithCallback:(void (^)())onSuccess onError:(void (^)(NSString*, NSString*))onError {
    if (self.client) {
        [self.client uploadWithCallbacks:onSuccess onError:onError];
    }
    else {
        NSString *errMsg = @"Client is nil";
        KCLog(@"%@", errMsg);
        onError(ERROR_CODE_INIT_ERROR, errMsg);
    }
}

- (void)uploadEvents {
    [self uploadEventsWithCallback:nil onError:nil];
}


- (void)setApiEndpoint:(NSString*)endpoint {
    self.client.apiEndpoint = endpoint;
}

- (void)disableAutoAppendUniqId {
    self.autoAppendUniqId = false;
}

- (void)enableAutoAppendUniqId {
    self.autoAppendUniqId = true;
}

- (void)disableAutoAppendModelInformation {
    self.autoAppendModelInformation = false;
}

- (void)enableAutoAppendModelInformation {
    self.autoAppendModelInformation = true;
}

- (BOOL)isFirstRun {
    NSInteger state = [[NSUserDefaults standardUserDefaults] integerForKey:storage_key_of_first_run];
    return state == 0;
}

- (void)clearFitstRun {
    [[NSUserDefaults standardUserDefaults] setInteger:1 forKey:storage_key_of_first_run];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (void)initializeWithApiKey:(NSString *)apiKey {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] initWithApiKey:apiKey];
    });
}

+ (void)initializeEncryptionKey:(NSString*)encryptionKey {
    [TDClient initializeEncryptionKey:encryptionKey];
}


+ (instancetype)sharedInstance {
    NSAssert(sharedInstance, @"%@ sharedInstance called before withSecret", self);
    return sharedInstance;
}

+ (void)initializeApiEndpoint:(NSString *)apiEndpoint {
    defaultApiEndpoint = apiEndpoint;
}

+ (void)disableEventCompression {
    isEventCompressionEnabled = false;
}

+ (void)enableEventCompression {
    isEventCompressionEnabled = true;
}

+ (void)disableLogging {
    [KeenClient disableLogging];
}

+ (void)enableLogging {
    [KeenClient enableLogging];
}

+ (void)disableTraceLogging {
    isTraceLoggingEnabled = false;
}

+ (void)enableTraceLogging {
    isTraceLoggingEnabled = true;
}

@end
