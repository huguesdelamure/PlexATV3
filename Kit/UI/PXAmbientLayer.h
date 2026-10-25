// Full-screen ambient background, like current Plex apps:
//  - "UltraBlur" 4-corner color gradient (from PMS UltraBlurColors), rendered
//    as a 2x2 bitmap stretched with bilinear filtering (free on the GPU);
//  - optional backdrop art on top (faded on the left / bottom for text);
//  - crossfades when the item changes.

#import <QuartzCore/QuartzCore.h>

typedef NS_ENUM(NSInteger, PXAmbientStyle) {
    PXAmbientHome,      // art on the right two thirds, strong fade (hero behind shelves)
    PXAmbientDetail,    // full-bleed art, fade left and bottom
    PXAmbientBlurOnly,  // colors only
};

@interface PXAmbientLayer : CALayer
- (instancetype)initWithFrame:(CGRect)frame style:(PXAmbientStyle)style;
// colors: {topLeft, topRight, bottomLeft, bottomRight} hex strings (PMS
// UltraBlurColors format), nil = default. artURL: backdrop (≈1280x720), nil = none.
- (void)showColors:(NSDictionary *)colors artURL:(NSURL *)artURL;
- (void)setArtOpacity:(CGFloat)opacity;   // e.g. dim the art while scrolling down
// Decoded size of the backdrop. Every new image is copied to the render
// server at commit time (main thread): smaller is faster. Default 1280x720,
// 768x432 for the home where it changes with the focus.
@property (nonatomic, assign) CGSize artSize;
@end
