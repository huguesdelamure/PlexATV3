#import "PXUI.h"
#import "PXLocalize.h"
#import "PXLog.h"
#import <CoreText/CoreText.h>

#pragma mark - Fonts

static BOOL gInter;

void PXRegisterFonts(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = [[PXKitBundle() bundlePath] stringByAppendingPathComponent:@"Fonts"];
        int ok = 0;
        for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL]) {
            if (![f.pathExtension isEqualToString:@"ttf"]) continue;
            CFErrorRef err = NULL;
            NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:f]];
            if (CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &err)) ok++;
            else if (err) { PXLog(@"fonts: %@ failed: %@", f, err); CFRelease(err); }
        }
        gInter = [UIFont fontWithName:@"Inter-Regular" size:12] != nil;
        PXLog(@"fonts: %d registered, Inter %@", ok, gInter ? @"OK" : @"MISSING (Helvetica fallback)");
    });
}

UIFont *PXFontW(CGFloat size, PXWeight w) {
    static NSString *inter[] = { @"Inter-Regular", @"Inter-Medium", @"Inter-SemiBold", @"Inter-Bold", @"Inter-ExtraBold" };
    static NSString *helv[]  = { @"HelveticaNeue", @"HelveticaNeue-Medium", @"HelveticaNeue-Medium", @"HelveticaNeue-Bold", @"HelveticaNeue-Bold" };
    // Font objects are looked up by name: keep them (called for every cell).
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    NSNumber *key = @((NSInteger)w * 10000 + (NSInteger)lround(size * 10));
    UIFont *f;
    @synchronized (cache) { f = cache[key]; }
    if (f) return f;
    f = gInter ? [UIFont fontWithName:inter[w] size:size] : nil;
    f = f ?: [UIFont fontWithName:helv[w] size:size];
    if (f) @synchronized (cache) { cache[key] = f; }
    return f;
}
UIFont *PXFont(CGFloat s)       { return PXFontW(s, PXRegular); }
UIFont *PXFontMedium(CGFloat s) { return PXFontW(s, PXMedium); }
UIFont *PXFontSemi(CGFloat s)   { return PXFontW(s, PXSemibold); }
UIFont *PXFontBold(CGFloat s)   { return PXFontW(s, PXBold); }
UIFont *PXFontHeavy(CGFloat s)  { return PXFontW(s, PXHeavy); }
UIFont *PXFontLight(CGFloat s)  { return PXFontW(s, PXRegular); }

#pragma mark - Colors

static CGColorRef keep(UIColor *c) { return CGColorRetain(c.CGColor); }
#define PXCOLOR(name, expr) CGColorRef name(void) { static CGColorRef c; if (!c) c = keep(expr); return c; }
PXCOLOR(PXColorBackground, [UIColor colorWithRed:0.055 green:0.06 blue:0.075 alpha:1])
PXCOLOR(PXColorAccent,     [UIColor colorWithRed:0.898 green:0.627 blue:0.051 alpha:1])
PXCOLOR(PXColorText,       [UIColor whiteColor])
PXCOLOR(PXColorTextDim,    [UIColor colorWithWhite:1 alpha:0.62])
PXCOLOR(PXColorTextFaint,  [UIColor colorWithWhite:1 alpha:0.40])
PXCOLOR(PXColorPanel,      [UIColor colorWithWhite:1 alpha:0.14])
PXCOLOR(PXColorPanelStrong,[UIColor colorWithWhite:1 alpha:0.24])

CGColorRef PXColorWhite(CGFloat a) { return [UIColor colorWithWhite:1 alpha:a].CGColor; }
CGColorRef PXColorBlack(CGFloat a) { return [UIColor colorWithWhite:0 alpha:a].CGColor; }

CGColorRef PXColorHex(NSString *hex, CGFloat a) {
    unsigned int v = 0;
    [[NSScanner scannerWithString:hex ?: @"000000"] scanHexInt:&v];
    return [UIColor colorWithRed:((v >> 16) & 0xff) / 255.0 green:((v >> 8) & 0xff) / 255.0 blue:(v & 0xff) / 255.0 alpha:a].CGColor;
}

#pragma mark - Text

// CATextLayer given a font *name* resolves it at every render with
// CGFontCreateWithFontName, which on iOS 8 rescans font files for fonts
// registered by the process: up to 1 s of main thread per screen (measured
// with the stall sampler). Resolve each font once and hand over the object.
static CGFontRef graphicsFont(UIFont *font) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    id hit = cache[font.fontName];
    if (hit) return (__bridge CGFontRef)hit;
    CTFontRef ct = CTFontCreateWithName((__bridge CFStringRef)font.fontName, font.pointSize, NULL);
    CGFontRef cg = CTFontCopyGraphicsFont(ct, NULL);
    CFRelease(ct);
    if (!cg) return NULL;
    cache[font.fontName] = (__bridge_transfer id)cg;
    return cg;
}

CATextLayer *PXText(UIFont *font, CGColorRef color) {
    CATextLayer *t = [CATextLayer layer];
    CGFontRef cg = graphicsFont(font);
    t.font = cg ? (CFTypeRef)cg : (__bridge CFTypeRef)font.fontName;
    t.fontSize = font.pointSize;
    t.foregroundColor = color;
    t.contentsScale = [UIScreen mainScreen].scale;
    t.truncationMode = kCATruncationEnd;
    t.wrapped = NO;
    t.actions = @{ @"contents": [NSNull null], @"string": [NSNull null] };
    return t;
}

void PXSetText(CATextLayer *layer, NSString *text) {
    if (![layer.string isEqual:text]) layer.string = text ?: @"";
}

// Text measuring costs 1-5 ms on the A5 and grids measure every title when
// cells are recycled: remember the results (main thread only).
static NSCache *measureCache(void) {
    static NSCache *cache;
    if (!cache) { cache = [NSCache new]; cache.countLimit = 2000; }
    return cache;
}

CGFloat PXTextHeight(NSString *text, UIFont *font, CGFloat width) {
    if (!text.length) return 0;
    BOOL main = [NSThread isMainThread];
    NSString *key = main ? [NSString stringWithFormat:@"h|%@|%.1f|%.0f|%@", font.fontName, font.pointSize, width, text] : nil;
    NSNumber *hit = key ? [measureCache() objectForKey:key] : nil;
    if (hit) return hit.doubleValue;
    CGRect r = [text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin
                               attributes:@{ NSFontAttributeName: font } context:nil];
    CGFloat h = ceil(r.size.height);
    if (key) [measureCache() setObject:@(h) forKey:key];
    return h;
}

CGFloat PXTextWidth(NSString *text, UIFont *font) {
    if (!text.length) return 0;
    BOOL main = [NSThread isMainThread];
    NSString *key = main ? [NSString stringWithFormat:@"w|%@|%.1f|%@", font.fontName, font.pointSize, text] : nil;
    NSNumber *hit = key ? [measureCache() objectForKey:key] : nil;
    if (hit) return hit.doubleValue;
    CGFloat w = ceil([text sizeWithAttributes:@{ NSFontAttributeName: font }].width);
    if (key) [measureCache() setObject:@(w) forKey:key];
    return w;
}

static UIFont *self_fit(NSString *text, PXWeight weight, CGFloat maxSize, CGFloat minSize, CGFloat width, NSInteger maxLines);

UIFont *PXFitFont(NSString *text, PXWeight weight, CGFloat maxSize, CGFloat minSize, CGFloat width, NSInteger maxLines) {
    // Text measuring is slow on the A5: remember results.
    static NSCache *cache;
    if (!cache) { cache = [NSCache new]; cache.countLimit = 300; }
    NSString *key = [NSString stringWithFormat:@"%@|%ld|%.0f|%.0f|%.0f|%ld", text, (long)weight, maxSize, minSize, width, (long)maxLines];
    UIFont *hit = [cache objectForKey:key];
    if (hit) return hit;
    UIFont *f = self_fit(text, weight, maxSize, minSize, width, maxLines);
    if (f) [cache setObject:f forKey:key];
    return f;
}

static UIFont *self_fit(NSString *text, PXWeight weight, CGFloat maxSize, CGFloat minSize, CGFloat width, NSInteger maxLines) {
    UIFont *f = PXFontW(maxSize, weight);
    for (CGFloat size = maxSize; size >= minSize; size -= 4) {
        f = PXFontW(size, weight);
        // Small safety margin: CATextLayer wraps a little earlier than NSString measuring.
        if (PXTextHeight(text, f, width - 12) <= ceil(f.lineHeight) * maxLines + 2) return f;
    }
    return f;
}

static UIImage *cachedImage(NSString *key, CGSize size, void (^draw)(void)) {
    static NSCache *cache;
    if (!cache) { cache = [NSCache new]; cache.countLimit = 200; }
    UIImage *img = [cache objectForKey:key];
    if (img) return img;
    UIGraphicsBeginImageContextWithOptions(size, NO, [UIScreen mainScreen].scale);
    draw();
    img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (img) [cache setObject:img forKey:key];
    return img;
}

CALayer *PXPillLayer(NSString *text, CGPoint origin) {
    UIFont *f = PXFontSemi(20);
    CGFloat w = PXTextWidth(text, f) + 22, h = 34;
    UIImage *img = cachedImage([@"pill|" stringByAppendingString:text], CGSizeMake(w, h), ^{
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(1, 1, w - 2, h - 2) cornerRadius:7];
        p.lineWidth = 2;
        [[UIColor colorWithWhite:1 alpha:0.55] setStroke];
        [p stroke];
        CGSize ts = [text sizeWithAttributes:@{ NSFontAttributeName: f }];
        [text drawAtPoint:CGPointMake((w - ts.width) / 2, (h - ts.height) / 2)
           withAttributes:@{ NSFontAttributeName: f, NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.92] }];
    });
    CALayer *l = [CALayer layer];
    l.frame = CGRectMake(origin.x, origin.y + 2, w, h);
    l.contents = (__bridge id)img.CGImage;
    l.contentsScale = img.scale;
    return l;
}

CALayer *PXCachedLabel(NSString *text, UIFont *font, UIColor *color, CGPoint origin) {
    CGSize ts = [text sizeWithAttributes:@{ NSFontAttributeName: font }];
    CGSize size = CGSizeMake(ceil(ts.width) + 2, ceil(ts.height) + 2);
    NSString *key = [NSString stringWithFormat:@"label|%@|%@|%.0f|%@", text, font.fontName, font.pointSize, color];
    UIImage *img = cachedImage(key, size, ^{
        [text drawAtPoint:CGPointMake(1, 1) withAttributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: color }];
    });
    CALayer *l = [CALayer layer];
    l.frame = CGRectMake(origin.x, origin.y, size.width, size.height);
    l.contents = (__bridge id)img.CGImage;
    l.contentsScale = img.scale;
    return l;
}

void PXDrawTextAsync(CALayer *layer, NSString *text, UIFont *font, CGColorRef color,
                     CGFloat width, NSInteger maxLines, CGFloat fitMinSize) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("px.text", DISPATCH_QUEUE_SERIAL); });
    // Rendered texts are kept (8 MB): grids redraw the same titles when rows
    // scroll back in, and every async completion costs main thread time.
    static NSCache *rendered;
    if (!rendered) { rendered = [NSCache new]; rendered.totalCostLimit = 8 * 1024 * 1024; }
    NSString *str = text ?: @"";
    CGFloat scale = [UIScreen mainScreen].scale;
    const CGFloat *comp = CGColorGetComponents(color);
    NSMutableString *colorKey = [NSMutableString string];
    for (size_t i = 0; i < CGColorGetNumberOfComponents(color); i++) [colorKey appendFormat:@"%.3f,", comp[i]];
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%.1f|%.0f|%ld|%.0f|%@|%@", font.fontName, font.pointSize, width, (long)maxLines, fitMinSize,
                          colorKey, str];
    UIImage *hit = [rendered objectForKey:cacheKey];
    if (hit) {
        [layer setValue:nil forKey:@"pxTextToken"];
        PXNoAnim(^{
            CGRect fr = layer.frame;
            layer.frame = CGRectMake(fr.origin.x, fr.origin.y, hit.size.width, str.length ? hit.size.height : 0);
            layer.contents = (__bridge id)hit.CGImage;
            layer.contentsScale = scale;
        });
        return;
    }
    // Token: only the latest request for a layer may set its contents.
    NSString *token = [[NSUUID UUID] UUIDString];
    [layer setValue:token forKey:@"pxTextToken"];
    UIColor *ui = [UIColor colorWithCGColor:color];
    dispatch_async(queue, ^{
        UIFont *f = font;
        if (fitMinSize > 0) {
            for (CGFloat size = font.pointSize; size >= fitMinSize; size -= 4) {
                f = [font fontWithSize:size];
                if (PXTextHeight(str, f, width - 12) <= ceil(f.lineHeight) * maxLines + 2) break;
            }
        }
        CGFloat maxH = ceil(f.lineHeight) * maxLines + 2;
        NSDictionary *attrs = @{ NSFontAttributeName: f, NSForegroundColorAttributeName: ui };
        CGRect r = [str boundingRectWithSize:CGSizeMake(width, maxH)
                                     options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                                  attributes:attrs context:nil];
        CGSize size = CGSizeMake(width, MAX(1, ceil(MIN(r.size.height, maxH))));
        UIGraphicsBeginImageContextWithOptions(size, NO, scale);
        [str drawWithRect:CGRectMake(0, 0, size.width, size.height)
                  options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
               attributes:attrs context:nil];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (img) [rendered setObject:img forKey:cacheKey cost:(NSUInteger)(size.width * size.height * scale * scale * 4)];
            if (![[layer valueForKey:@"pxTextToken"] isEqual:token]) return;
            PXNoAnim(^{
                CGRect fr = layer.frame;
                layer.frame = CGRectMake(fr.origin.x, fr.origin.y, size.width, str.length ? size.height : 0);
                layer.contents = (__bridge id)img.CGImage;
                layer.contentsScale = scale;
            });
        });
    });
}

CALayer *PXAsyncLabel(NSString *text, UIFont *font, CGColorRef color, CGRect frame, NSInteger maxLines, BOOL centered) {
    CALayer *l = [CALayer layer];
    l.anchorPoint = CGPointZero;
    l.contentsGravity = kCAGravityTopLeft;
    l.actions = @{ @"contents": [NSNull null], @"bounds": [NSNull null], @"position": [NSNull null] };
    CGRect f = frame;
    if (centered) {
        CGFloat w = MIN(frame.size.width, PXTextWidth(text, font) + 2);
        f = CGRectMake(frame.origin.x + floor((frame.size.width - w) / 2), frame.origin.y, w, frame.size.height);
    }
    l.frame = f;
    if (text.length) PXDrawTextAsync(l, text, font, color, f.size.width, maxLines, 0);
    return l;
}

CATextLayer *PXLabel(NSString *text, UIFont *font, CGColorRef color, CGPoint origin) {
    CATextLayer *t = PXText(font, color);
    t.string = text ?: @"";
    t.frame = CGRectMake(origin.x, origin.y, PXTextWidth(text, font) + 4, ceil(font.lineHeight) + 2);
    return t;
}

#pragma mark - Animation

void PXNoAnim(void (^block)(void)) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    block();
    [CATransaction commit];
}

void PXAnim(CFTimeInterval duration, void (^block)(void)) {
    [CATransaction begin];
    [CATransaction setAnimationDuration:duration];
    [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithControlPoints:0.2 :0.8 :0.2 :1.0]];
    block();
    [CATransaction commit];
}

void PXSpringScale(CALayer *layer, CGFloat to) {
    CGFloat from = [[layer.presentationLayer ?: layer valueForKeyPath:@"transform.scale"] doubleValue] ?: 1.0;
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    CGFloat d = to - from;
    a.values = @[ @(from), @(from + d * 1.12), @(from + d * 0.96), @(from + d * 1.01), @(to) ];
    a.keyTimes = @[ @0, @0.45, @0.7, @0.88, @1 ];
    a.duration = 0.3;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    PXNoAnim(^{ layer.transform = CATransform3DMakeScale(to, to, 1); });
    [layer addAnimation:a forKey:@"spring"];
}

void PXGlossSweep(CALayer *layer, CGFloat radius) {
    // Light band moved by animating the gradient stops: no masksToBounds, so
    // no offscreen pass (the band barely touches the rounded corners).
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = layer.bounds;
    g.cornerRadius = radius;
    g.startPoint = CGPointMake(0, 0.25);
    g.endPoint = CGPointMake(1, 0.75);
    g.colors = @[ (__bridge id)PXColorWhite(0), (__bridge id)PXColorWhite(0.22), (__bridge id)PXColorWhite(0) ];
    g.locations = @[ @1.2, @1.35, @1.5 ];
    PXNoAnim(^{ [layer addSublayer:g]; });
    CABasicAnimation *m = [CABasicAnimation animationWithKeyPath:@"locations"];
    m.fromValue = @[ @-0.5, @-0.35, @-0.2 ];
    m.toValue = @[ @1.2, @1.35, @1.5 ];
    m.duration = 0.6;
    m.beginTime = CACurrentMediaTime() + 0.1;
    m.fillMode = kCAFillModeBackwards;
    m.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{ PXNoAnim(^{ [g removeFromSuperlayer]; }); }];
    [g addAnimation:m forKey:@"sweep"];
    [CATransaction commit];
}

void PXFadeContents(CALayer *layer, CFTimeInterval duration) {
    CATransition *t = [CATransition animation];
    t.duration = duration;
    t.type = kCATransitionFade;
    [layer addAnimation:t forKey:@"fade"];
}

#pragma mark - Icons

CAShapeLayer *PXIconLayer(PXIcon icon, CGFloat s, CGColorRef color) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.bounds = CGRectMake(0, 0, s, s);
    l.anchorPoint = CGPointZero;
    l.fillColor = color;
    l.strokeColor = color;
    l.lineWidth = 0;
    l.lineCap = kCALineCapRound;
    l.lineJoin = kCALineJoinRound;
    UIBezierPath *p = [UIBezierPath bezierPath];
    CGFloat lw = MAX(2, s * 0.09);
    switch (icon) {
        case PXIconPlay:
            [p moveToPoint:CGPointMake(s * 0.22, s * 0.12)];
            [p addLineToPoint:CGPointMake(s * 0.86, s * 0.5)];
            [p addLineToPoint:CGPointMake(s * 0.22, s * 0.88)];
            [p closePath];
            break;
        case PXIconPause:
            [p appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(s * 0.2, s * 0.12, s * 0.2, s * 0.76) cornerRadius:s * 0.04]];
            [p appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(s * 0.6, s * 0.12, s * 0.2, s * 0.76) cornerRadius:s * 0.04]];
            break;
        case PXIconNext:
            [p moveToPoint:CGPointMake(s * 0.15, s * 0.15)];
            [p addLineToPoint:CGPointMake(s * 0.68, s * 0.5)];
            [p addLineToPoint:CGPointMake(s * 0.15, s * 0.85)];
            [p closePath];
            [p appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(s * 0.72, s * 0.15, s * 0.13, s * 0.7)]];
            break;
        case PXIconRestart: {
            l.fillColor = NULL; l.lineWidth = lw;
            [p addArcWithCenter:CGPointMake(s / 2, s / 2) radius:s * 0.34 startAngle:-M_PI * 0.9 endAngle:M_PI * 0.75 clockwise:YES];
            UIBezierPath *head = [UIBezierPath bezierPath];
            CGPoint a = CGPointMake(s / 2 + s * 0.34 * cos(-M_PI * 0.9), s / 2 + s * 0.34 * sin(-M_PI * 0.9));
            [head moveToPoint:CGPointMake(a.x - s * 0.02, a.y - s * 0.2)];
            [head addLineToPoint:a];
            [head addLineToPoint:CGPointMake(a.x + s * 0.2, a.y - s * 0.02)];
            [p appendPath:head];
            break;
        }
        case PXIconAudio: {
            UIBezierPath *spk = [UIBezierPath bezierPath];
            [spk moveToPoint:CGPointMake(s * 0.1, s * 0.38)];
            [spk addLineToPoint:CGPointMake(s * 0.28, s * 0.38)];
            [spk addLineToPoint:CGPointMake(s * 0.5, s * 0.16)];
            [spk addLineToPoint:CGPointMake(s * 0.5, s * 0.84)];
            [spk addLineToPoint:CGPointMake(s * 0.28, s * 0.62)];
            [spk addLineToPoint:CGPointMake(s * 0.1, s * 0.62)];
            [spk closePath];
            [p appendPath:spk];
            CAShapeLayer *waves = [CAShapeLayer layer];
            UIBezierPath *w = [UIBezierPath bezierPath];
            [w addArcWithCenter:CGPointMake(s * 0.5, s * 0.5) radius:s * 0.18 startAngle:-M_PI / 3.5 endAngle:M_PI / 3.5 clockwise:YES];
            [w moveToPoint:CGPointMake(s * 0.5 + s * 0.34 * cos(-M_PI / 3.5), s * 0.5 + s * 0.34 * sin(-M_PI / 3.5))];
            [w addArcWithCenter:CGPointMake(s * 0.5, s * 0.5) radius:s * 0.34 startAngle:-M_PI / 3.5 endAngle:M_PI / 3.5 clockwise:YES];
            waves.path = w.CGPath;
            waves.fillColor = NULL;
            waves.strokeColor = color;
            waves.lineWidth = lw;
            waves.lineCap = kCALineCapRound;
            [l addSublayer:waves];
            break;
        }
        case PXIconSubtitles: {
            l.fillColor = NULL; l.lineWidth = lw;
            [p appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(s * 0.08, s * 0.2, s * 0.84, s * 0.6) cornerRadius:s * 0.1]];
            [p moveToPoint:CGPointMake(s * 0.24, s * 0.44)]; [p addLineToPoint:CGPointMake(s * 0.48, s * 0.44)];
            [p moveToPoint:CGPointMake(s * 0.58, s * 0.44)]; [p addLineToPoint:CGPointMake(s * 0.76, s * 0.44)];
            [p moveToPoint:CGPointMake(s * 0.24, s * 0.6)];  [p addLineToPoint:CGPointMake(s * 0.4, s * 0.6)];
            [p moveToPoint:CGPointMake(s * 0.5, s * 0.6)];   [p addLineToPoint:CGPointMake(s * 0.76, s * 0.6)];
            break;
        }
        case PXIconCheck:
            l.fillColor = NULL; l.lineWidth = lw * 1.2;
            [p moveToPoint:CGPointMake(s * 0.16, s * 0.52)];
            [p addLineToPoint:CGPointMake(s * 0.4, s * 0.76)];
            [p addLineToPoint:CGPointMake(s * 0.86, s * 0.26)];
            break;
        case PXIconGear: {
            // Thick dashed ring = teeth, thinner ring = body.
            l.fillColor = NULL; l.lineWidth = s * 0.16;
            [p addArcWithCenter:CGPointMake(s / 2, s / 2) radius:s * 0.36 startAngle:0 endAngle:M_PI * 2 clockwise:YES];
            l.lineDashPattern = @[ @(s * 0.16), @(s * 0.12) ];
            l.lineCap = kCALineCapButt;
            CAShapeLayer *body = [CAShapeLayer layer];
            body.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(s / 2, s / 2) radius:s * 0.24 startAngle:0 endAngle:M_PI * 2 clockwise:YES].CGPath;
            body.fillColor = NULL;
            body.strokeColor = color;
            body.lineWidth = s * 0.13;
            [l addSublayer:body];
            break;
        }
        case PXIconSearch:
            l.fillColor = NULL; l.lineWidth = lw * 1.1;
            [p appendPath:[UIBezierPath bezierPathWithArcCenter:CGPointMake(s * 0.42, s * 0.42) radius:s * 0.26 startAngle:0 endAngle:M_PI * 2 clockwise:YES]];
            [p moveToPoint:CGPointMake(s * 0.62, s * 0.62)];
            [p addLineToPoint:CGPointMake(s * 0.86, s * 0.86)];
            break;
        case PXIconChapters:
            l.fillColor = NULL; l.lineWidth = lw;
            for (int i = 0; i < 3; i++) {
                CGFloat y = s * (0.25 + 0.25 * i);
                [p moveToPoint:CGPointMake(s * 0.14, y)]; [p addLineToPoint:CGPointMake(s * 0.18, y)];
                [p moveToPoint:CGPointMake(s * 0.32, y)]; [p addLineToPoint:CGPointMake(s * 0.86, y)];
            }
            break;
        case PXIconInfo:
            l.fillColor = NULL; l.lineWidth = lw;
            [p appendPath:[UIBezierPath bezierPathWithArcCenter:CGPointMake(s / 2, s / 2) radius:s * 0.4 startAngle:0 endAngle:M_PI * 2 clockwise:YES]];
            [p moveToPoint:CGPointMake(s / 2, s * 0.46)]; [p addLineToPoint:CGPointMake(s / 2, s * 0.7)];
            [p moveToPoint:CGPointMake(s / 2, s * 0.3)];  [p addLineToPoint:CGPointMake(s / 2, s * 0.31)];
            break;
        case PXIconStar: {
            for (int i = 0; i < 10; i++) {
                CGFloat r = (i % 2) ? s * 0.2 : s * 0.46, a = -M_PI / 2 + i * M_PI / 5;
                CGPoint pt = CGPointMake(s / 2 + r * cos(a), s / 2 + r * sin(a));
                if (i == 0) [p moveToPoint:pt]; else [p addLineToPoint:pt];
            }
            [p closePath];
            break;
        }
    }
    l.path = p.CGPath;
    return l;
}

CALayer *PXSpinner(CGFloat size) {
    CAShapeLayer *arc = [CAShapeLayer layer];
    arc.bounds = CGRectMake(0, 0, size, size);
    arc.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(size / 2, size / 2) radius:size / 2 - 3
                                          startAngle:0 endAngle:M_PI * 1.5 clockwise:YES].CGPath;
    arc.fillColor = NULL;
    arc.strokeColor = PXColorText();
    arc.lineWidth = 5;
    arc.lineCap = kCALineCapRound;
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @0;
    spin.toValue = @(M_PI * 2);
    spin.duration = 0.9;
    spin.repeatCount = HUGE_VALF;
    spin.removedOnCompletion = NO;
    [arc addAnimation:spin forKey:@"spin"];
    return arc;
}

#pragma mark - Time

NSString *PXClock(double s) {
    if (isnan(s) || s < 0) return @"--:--";
    long t = (long)s;
    return t >= 3600 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", t / 3600, (t / 60) % 60, t % 60]
                     : [NSString stringWithFormat:@"%02ld:%02ld", t / 60, t % 60];
}

NSString *PXDurationText(double s) {
    long m = (long)(s / 60);
    return m >= 60 ? PXLF(@"%ld h %02ld", m / 60, m % 60) : PXLF(@"%ld min", MAX(1L, m));
}

// Time of day in the UI language's convention (21:47 / 9:47 PM).
NSString *PXWallClock(NSDate *date) {
    static NSDateFormatter *f;
    static NSString *lang;
    if (!f || ![lang isEqual:PXLanguage()]) {
        lang = PXLanguage();
        f = [NSDateFormatter new];
        f.locale = PXUILocale();
        f.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"jmm" options:0 locale:PXUILocale()] ?: @"HH:mm";
    }
    return [f stringFromDate:date];
}
