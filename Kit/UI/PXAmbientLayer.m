#import "PXAmbientLayer.h"
#import "PXUI.h"
#import "PXImageCache.h"

// 2x2 RGB bitmap from the 4 corner colors; bilinear magnification turns it
// into a smooth full-screen gradient.
static CGImageRef blurImage(NSDictionary *c) CF_RETURNS_RETAINED;
static CGImageRef blurImage(NSDictionary *c) {
    NSArray *keys = @[ @"topLeft", @"topRight", @"bottomLeft", @"bottomRight" ];
    uint8_t px[16];
    for (int i = 0; i < 4; i++) {
        unsigned int v = 0;
        [[NSScanner scannerWithString:c[keys[i]] ?: @"202530"] scanHexInt:&v];
        // Darken a bit so white text keeps its contrast.
        px[i * 4 + 0] = (uint8_t)((v & 0xff) * 0.75);          // B
        px[i * 4 + 1] = (uint8_t)(((v >> 8) & 0xff) * 0.75);   // G
        px[i * 4 + 2] = (uint8_t)(((v >> 16) & 0xff) * 0.75);  // R
        px[i * 4 + 3] = 255;
    }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, 2, 2, 8, 8, cs, kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
    CGColorSpaceRelease(cs);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return img;
}

@implementation PXAmbientLayer {
    PXAmbientStyle _style;
    CALayer *_blur, *_art;
    NSString *_artPath;
    NSString *_blurKey;
    CGFloat _artOpacity;
}

- (instancetype)initWithFrame:(CGRect)frame style:(PXAmbientStyle)style {
    if ((self = [super init])) {
        self.frame = frame;
        _style = style;
        _artOpacity = style == PXAmbientHome ? 0.55 : 0.9;
        _artSize = style == PXAmbientHome ? CGSizeMake(768, 432) : CGSizeMake(1280, 720);
        self.backgroundColor = PXColorBackground();

        _blur = [CALayer layer];
        // Sample the 2x2 bitmap at pixel centres so corners hold their colors.
        _blur.frame = CGRectInset(self.bounds, -frame.size.width / 2, -frame.size.height / 2);
        _blur.magnificationFilter = kCAFilterLinear;
        _blur.contentsGravity = kCAGravityResize;
        [self addSublayer:_blur];

        _art = [CALayer layer];
        CGRect af = self.bounds;
        if (style == PXAmbientHome) af = CGRectMake(frame.size.width * 0.32, 0, frame.size.width * 0.68, frame.size.height * 0.72);
        _art.frame = af;
        _art.contentsGravity = kCAGravityResizeAspectFill;
        _art.opacity = 0;
        [self addSublayer:_art];

        // Detail: soft scrim on the left third so the text column stays readable.
        if (style == PXAmbientDetail) {
            CAGradientLayer *scrim = [CAGradientLayer layer];
            scrim.frame = self.bounds;
            scrim.startPoint = CGPointMake(0, 0.5);
            scrim.endPoint = CGPointMake(1, 0.5);
            // The text column reaches ~62 % of the width: keep it dark up to
            // there, even on bright or busy artwork.
            scrim.colors = @[ (__bridge id)PXColorBlack(0.78), (__bridge id)PXColorBlack(0.62), (__bridge id)PXColorBlack(0.25), (__bridge id)PXColorBlack(0) ];
            scrim.locations = @[ @0, @0.45, @0.68, @0.85 ];
            [self addSublayer:scrim];
        }
        // Global vignette, dark at the bottom (shelves / buttons area).
        CAGradientLayer *vignette = [CAGradientLayer layer];
        vignette.frame = self.bounds;
        vignette.colors = @[ (__bridge id)PXColorBlack(0.15), (__bridge id)PXColorBlack(0.0), (__bridge id)PXColorBlack(0.55) ];
        vignette.locations = @[ @0, @0.35, @1 ];
        [self addSublayer:vignette];
        [self setColors:nil animated:NO];
    }
    return self;
}

- (void)setColors:(NSDictionary *)colors animated:(BOOL)animated {
    NSString *key = colors.description ?: @"default";
    if ([key isEqual:_blurKey]) return;
    _blurKey = key;
    CGImageRef img = blurImage(colors ?: @{ @"topLeft": @"1a2233", @"topRight": @"141820", @"bottomLeft": @"10131a", @"bottomRight": @"1c1a24" });
    if (animated) PXFadeContents(_blur, 0.8);
    PXNoAnim(^{ self->_blur.contents = (__bridge id)img; });
    CGImageRelease(img);
}

- (void)setArtOpacity:(CGFloat)opacity {
    _artOpacity = opacity;
    if (_art.contents) PXAnim(0.4, ^{ self->_art.opacity = opacity; });
}

- (void)showColors:(NSDictionary *)colors artURL:(NSURL *)url {
    [self setColors:([colors isKindOfClass:[NSDictionary class]] ? colors : nil) animated:YES];
    if (_style == PXAmbientBlurOnly) return;
    NSString *path = url.absoluteString;
    if ([path isEqual:_artPath] || (!path && !_artPath)) return;
    _artPath = path;
    if (!url) { PXAnim(0.5, ^{ self->_art.opacity = 0; }); return; }
    CGSize s = _artSize;
    // Fades baked into the bitmap: the art melts into the ambient colors.
    CGFloat fl = _style == PXAmbientHome ? 0.5 : 0.62, fb = _style == PXAmbientHome ? 0.55 : 0.5;
    __weak PXAmbientLayer *weak = self;
    [[PXImageCache shared] loadURL:url size:s fadeLeft:fl fadeBottom:fb done:^(CGImageRef img) {
        PXAmbientLayer *me = weak;
        if (!me || ![path isEqual:me->_artPath] || !img) return;
        PXFadeContents(me->_art, 0.6);
        PXNoAnim(^{ me->_art.contents = (__bridge id)img; });
        PXAnim(0.6, ^{ me->_art.opacity = me->_artOpacity; });
    }];
}

@end
