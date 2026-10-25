// Plex Companion player: control from the Plex mobile apps (see PXCompanion.m).

#import <Foundation/Foundation.h>

@interface PXCompanion : NSObject
+ (instancetype)shared;
+ (BOOL)enabled;          // setting "companion", default YES
- (void)start;
- (void)stop;
@end
