// Scrub preview thumbnails from the PMS "BIF" index (/library/parts/<id>/indexes/sd).
// The file (often 10-30 MB) is downloaded to the cache directory and memory-
// mapped, so only the thumbnails actually shown are paged in.

#import <UIKit/UIKit.h>
@class PXServer;

@interface PXBif : NSObject
+ (instancetype)bifForPartID:(NSString *)partID server:(PXServer *)server;   // starts the download if needed
@property (nonatomic, readonly) BOOL ready;
// Decoded thumbnail at a media time (seconds), or NULL. Caller does not own it.
- (CGImageRef)imageAt:(double)seconds;
@end
