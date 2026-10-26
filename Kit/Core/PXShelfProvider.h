// Contract between an appliance and a launcher (informal protocol, checked
// with -respondsToSelector:, so neither side links against the other).
//
// A launcher shows the "Top Shelf" of the focused app: the appliance's
// principal object can provide it, and open an item from it.

#import <Foundation/Foundation.h>

@protocol PXShelfProvider <NSObject>
@optional
// Calls completion on the main queue with:
// @{ @"title": NSString,
//    @"items": @[ @{ @"id": NSString, @"title": NSString, @"subtitle": NSString,
//                    @"image": NSString (URL, 16:9 when "wide" else 2:3),
//                    @"background": NSString (URL, ~1280x720 backdrop),
//                    @"colors": NSDictionary (4 corner hex colors, optional),
//                    @"wide": NSNumber (BOOL), @"progress": NSNumber (0..1) } ] }
// or nil when there is nothing to show.
- (void)shelfContent:(void (^)(NSDictionary *shelf))completion;
// BackRow controller to push for an item of the shelf (play = start playback).
- (id)controllerForShelfItem:(NSString *)identifier play:(BOOL)play;
// Active user of the app when it has several (Plex Home profiles), for a
// launcher's profile badge: @{ @"name", @"thumb" (avatar URL), @"id" }, or nil.
// Changes are announced with the NSNotification "PXHomeUserDidChange".
- (NSDictionary *)homeUser;
// BackRow controller of the app's profile picker, for the launcher to push.
- (id)controllerForUserSwitch;
@end
