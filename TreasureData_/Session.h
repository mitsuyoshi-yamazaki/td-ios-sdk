//
//  Session.h
//  TreasureData
//
//  Created by Mitsunori Komatsu on 6/22/16.
//  Copyright © 2016 Mitsunori Komatsu. All rights reserved.
//

#ifndef Session_h
#define Session_h

@interface Session : NSObject
@property long sessionPendingMillis;

+ (Session*) new;
- (void) start;
- (void) finish;
- (NSString*) getId;
@end

#endif /* Session_h */
