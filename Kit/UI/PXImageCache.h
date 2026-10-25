// Image loading: memory cache (decoded, cost-limited) -> disk cache (JPEG as
// served) -> network. Decoding happens off the main thread at display size so
// scrolling never decodes on the main thread. Callbacks run on the main queue.

#import <UIKit/UIKit.h>

typedef void (^PXImageBlock)(CGImageRef image);

@interface PXImageCache : NSObject
+ (instancetype)shared;
- (CGImageRef)cachedImageForURL:(NSURL *)url;   // memory only
- (CGImageRef)cachedImageForURL:(NSURL *)url radius:(CGFloat)radius;
- (void)loadURL:(NSURL *)url size:(CGSize)size done:(PXImageBlock)done;
// Rounded corners are baked into the bitmap (no masksToBounds offscreen pass).
- (void)loadURL:(NSURL *)url size:(CGSize)size radius:(CGFloat)radius done:(PXImageBlock)done;
// Backdrops: alpha fades baked in (fraction of width faded from the left,
// fraction of height faded at the bottom), so they blend into what is below.
- (void)loadURL:(NSURL *)url size:(CGSize)size fadeLeft:(CGFloat)left fadeBottom:(CGFloat)bottom done:(PXImageBlock)done;
- (void)trimDiskCache;                           // keep the disk cache bounded
@end
