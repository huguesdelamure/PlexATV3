#import "PXDecor.h"
#import "PXServer.h"
#import "PXUI.h"
#import "PXPlex.h"
#import "PXImageCache.h"

static const CGFloat kBadgeH = 38;

static CALayer *textBox(NSString *text, UIFont *f, CGColorRef fg, CGColorRef bg, CGFloat x, CGFloat padding) {
    CGFloat w = PXTextWidth(text, f) + padding * 2;
    CALayer *b = [CALayer layer];
    b.frame = CGRectMake(x, 0, w, kBadgeH);
    b.cornerRadius = 6;
    b.backgroundColor = bg;
    CATextLayer *t = PXText(f, fg);
    t.alignmentMode = kCAAlignmentCenter;
    t.string = text;
    t.frame = CGRectMake(0, (kBadgeH - f.lineHeight) / 2 - 1, w, f.lineHeight + 2);
    [b addSublayer:t];
    return b;
}

static CALayer *tomato(BOOL fresh) {
    CALayer *l = [CALayer layer];
    l.bounds = CGRectMake(0, 0, 34, 34);
    l.anchorPoint = CGPointZero;
    CAShapeLayer *fruit = [CAShapeLayer layer];
    fruit.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(2, 7, 30, 26)].CGPath;
    fruit.fillColor = fresh ? PXColorHex(@"fa320a", 1) : PXColorHex(@"0ac855", 1);
    CAShapeLayer *leaf = [CAShapeLayer layer];
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(17, 9)];
    [p addQuadCurveToPoint:CGPointMake(8, 3) controlPoint:CGPointMake(10, 9)];
    [p addQuadCurveToPoint:CGPointMake(17, 6) controlPoint:CGPointMake(14, 2)];
    [p addQuadCurveToPoint:CGPointMake(26, 3) controlPoint:CGPointMake(20, 2)];
    [p addQuadCurveToPoint:CGPointMake(17, 9) controlPoint:CGPointMake(24, 9)];
    leaf.path = p.CGPath;
    leaf.fillColor = PXColorHex(@"00912d", 1);
    [l addSublayer:fruit];
    if (fresh) [l addSublayer:leaf];
    return l;
}

static CALayer *popcorn(BOOL upright) {
    CALayer *l = [CALayer layer];
    l.bounds = CGRectMake(0, 0, 32, 34);
    l.anchorPoint = CGPointZero;
    for (int i = 0; i < 4; i++) {
        CAShapeLayer *k = [CAShapeLayer layer];
        k.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(3 + i * 6.5, 2 + (i % 2) * 3, 11, 11)].CGPath;
        k.fillColor = upright ? PXColorHex(@"ffe8a3", 1) : PXColorHex(@"b9b9b9", 1);
        [l addSublayer:k];
    }
    CAShapeLayer *bucket = [CAShapeLayer layer];
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(3, 11)]; [p addLineToPoint:CGPointMake(29, 11)];
    [p addLineToPoint:CGPointMake(25, 33)]; [p addLineToPoint:CGPointMake(7, 33)]; [p closePath];
    bucket.path = p.CGPath;
    bucket.fillColor = upright ? PXColorHex(@"fa320a", 1) : PXColorHex(@"6b7280", 1);
    [l addSublayer:bucket];
    CAShapeLayer *stripes = [CAShapeLayer layer];
    UIBezierPath *s = [UIBezierPath bezierPath];
    for (int i = 0; i < 3; i++) { [s moveToPoint:CGPointMake(10 + i * 6, 13)]; [s addLineToPoint:CGPointMake(11 + i * 5, 31)]; }
    stripes.path = s.CGPath;
    stripes.strokeColor = PXColorWhite(0.9);
    stripes.lineWidth = 2;
    [l addSublayer:stripes];
    return l;
}

CALayer *PXRatingsRow(NSArray *ratings, CGPoint origin) {
    CALayer *row = [CALayer layer];
    row.anchorPoint = CGPointZero;
    row.position = origin;
    CGFloat x = 0;
    UIFont *vf = PXFontSemi(26), *lf = PXFontHeavy(20);
    for (NSDictionary *r in ratings) {
        NSString *img = r[@"image"];
        double v = [r[@"value"] doubleValue];
        if (v <= 0) continue;
        CALayer *icon = nil;
        NSString *value = nil;
        if ([img hasPrefix:@"imdb://"]) {
            icon = textBox(@"IMDb", lf, PXColorBlack(0.95), PXColorHex(@"f5c518", 1), 0, 9);
            value = [NSString stringWithFormat:@"%.1f", v];
        } else if ([img hasPrefix:@"rottentomatoes://image.rating.ripe"] || [img hasPrefix:@"rottentomatoes://image.rating.rotten"]) {
            icon = tomato([img hasSuffix:@"ripe"]);
            value = PXLF(@"%.0f %%", v * 10);
        } else if ([img hasPrefix:@"rottentomatoes://image.rating.upright"] || [img hasPrefix:@"rottentomatoes://image.rating.spilled"]) {
            icon = popcorn([img hasSuffix:@"upright"]);
            value = PXLF(@"%.0f %%", v * 10);
        } else if ([img hasPrefix:@"themoviedb://"]) {
            icon = textBox(@"TMDB", lf, PXColorBlack(0.95), PXColorHex(@"01d277", 1), 0, 9);
            value = PXLF(@"%.0f %%", v * 10);
        } else continue;
        PXNoAnim(^{
            icon.position = CGPointMake(x, icon.bounds.size.height < kBadgeH ? (kBadgeH - icon.bounds.size.height) / 2 : 0);
            if (icon.anchorPoint.x != 0) icon.position = CGPointMake(x + icon.bounds.size.width / 2, kBadgeH / 2);
            [row addSublayer:icon];
        });
        CGFloat ix = x + icon.bounds.size.width + 10;
        CATextLayer *t = PXLabel(value, vf, PXColorText(), CGPointMake(ix, (kBadgeH - vf.lineHeight) / 2 - 1));
        [row addSublayer:t];
        x = ix + t.bounds.size.width + 30;
    }
    row.bounds = CGRectMake(0, 0, x, kBadgeH);
    return row;
}

CALayer *PXPillsRow(NSArray *texts, CGPoint origin) {
    CALayer *row = [CALayer layer];
    row.anchorPoint = CGPointZero;
    row.position = origin;
    CGFloat x = 0;
    UIFont *f = PXFontSemi(20);
    for (NSString *s in texts) {
        CGFloat w = PXTextWidth(s, f) + 22;
        CALayer *b = [CALayer layer];
        b.frame = CGRectMake(x, 2, w, 34);
        b.cornerRadius = 7;
        b.borderWidth = 2;
        b.borderColor = PXColorWhite(0.55);
        CATextLayer *t = PXText(f, PXColorWhite(0.92));
        t.alignmentMode = kCAAlignmentCenter;
        t.string = s;
        t.frame = CGRectMake(0, (34 - f.lineHeight) / 2 - 1, w, f.lineHeight + 2);
        [b addSublayer:t];
        [row addSublayer:b];
        x += w + 10;
    }
    row.bounds = CGRectMake(0, 0, x, 38);
    return row;
}

#pragma mark - Cast row

static const CGFloat kD = 150, kGap = 44;

@implementation PXCastRow {
    CGFloat _width;
    CALayer *_content;
    NSMutableArray *_cells;    // {root, photo, ring, name, role}
    CATextLayer *_title;
}

- (instancetype)initWithWidth:(CGFloat)width {
    if ((self = [super init])) {
        _width = width;
        _height = 56 + kD + 90;
        self.anchorPoint = CGPointZero;
        self.bounds = CGRectMake(0, 0, width, _height);
        _title = PXText(PXFontBold(30), PXColorWhite(0.92));
        _title.string = PXL(@"Distribution");
        _title.frame = CGRectMake(110, 0, 800, 40);
        [self addSublayer:_title];
        _content = [CALayer layer];
        _content.anchorPoint = CGPointZero;
        _content.position = CGPointMake(110, 56);
        [self addSublayer:_content];
        _cells = [NSMutableArray array];
    }
    return self;
}

- (void)setPeople:(NSArray *)people {
    _people = [people copy];
    for (NSDictionary *c in _cells) [c[@"root"] removeFromSuperlayer];
    [_cells removeAllObjects];
    NSArray *list = people.count > 20 ? [people subarrayWithRange:NSMakeRange(0, 20)] : people;
    for (NSUInteger i = 0; i < list.count; i++) {
        NSDictionary *p = list[i];
        CALayer *root = [CALayer layer];
        root.frame = CGRectMake(i * (kD + kGap), 0, kD, kD + 90);
        CALayer *photo = [CALayer layer];
        photo.frame = CGRectMake(0, 0, kD, kD);
        photo.cornerRadius = kD / 2;
        photo.backgroundColor = PXColorWhite(0.1);
        [root addSublayer:photo];
        // Initials while the photo loads (or when there is none).
        NSArray *parts = [p[@"name"] componentsSeparatedByString:@" "];
        NSString *ini = [[NSString stringWithFormat:@"%@%@", [parts.firstObject substringToIndex:MIN(1, [parts.firstObject length])],
                          parts.count > 1 ? [parts.lastObject substringToIndex:MIN(1, [parts.lastObject length])] : @""] uppercaseString];
        // Off-main text: 20 people x 3 CATextLayers were rendered at commit.
        CALayer *initials = PXAsyncLabel(ini, PXFontSemi(44), PXColorTextFaint(), CGRectMake(0, (kD - 54) / 2, kD, 56), 1, YES);
        [photo addSublayer:initials];
        CAShapeLayer *ring = [CAShapeLayer layer];
        ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(photo.frame, -5, -5)].CGPath;
        ring.fillColor = NULL;
        ring.strokeColor = PXColorText();
        ring.lineWidth = 4;
        ring.opacity = 0;
        [root addSublayer:ring];
        // White text, dimmed by opacity: focus changes cost no redraw.
        CALayer *name = PXAsyncLabel(p[@"name"], PXFontSemi(22), PXColorText(), CGRectMake(-20, kD + 14, kD + 40, 30), 1, YES);
        name.opacity = 0.62;
        CALayer *role = PXAsyncLabel(p[@"role"], PXFont(19), PXColorTextFaint(), CGRectMake(-20, kD + 44, kD + 40, 26), 1, YES);
        [root addSublayer:name];
        [root addSublayer:role];
        PXNoAnim(^{ [self->_content addSublayer:root]; });
        [_cells addObject:@{ @"root": root, @"photo": photo, @"ring": ring, @"name": name, @"initials": initials }];
        NSString *thumb = p[@"thumb"];
        if (thumb.length) {
            NSURL *url = [(self.server ?: [PXPlex shared].primaryServer) imageURL:thumb width:(int)kD height:(int)kD];
            [[PXImageCache shared] loadURL:url size:CGSizeMake(kD, kD) radius:kD / 2 done:^(CGImageRef img) {
                if (!img) return;
                PXFadeContents(photo, 0.25);
                PXNoAnim(^{ photo.contents = (__bridge id)img; photo.backgroundColor = NULL; initials.hidden = YES; });
            }];
        }
    }
    [self update:NO];
}

- (void)setActive:(BOOL)active { _active = active; [self update:YES]; }

- (void)update:(BOOL)animated {
    NSInteger visible = MAX(1, (NSInteger)((_width - 110) / (kD + kGap)) - 1);
    NSInteger first = MAX(0, _focusIndex - visible + 1);
    for (NSInteger i = 0; i < (NSInteger)_cells.count; i++) {
        NSDictionary *c = _cells[i];
        BOOL f = _active && i == _focusIndex;
        CALayer *root = c[@"root"];
        BOOL was = [[root valueForKey:@"pxFocused"] boolValue];
        [root setValue:@(f) forKey:@"pxFocused"];
        if (f != was) PXSpringScale(root, f ? 1.1 : 1.0);
        PXAnim(0.2, ^{
            [c[@"ring"] setOpacity:f ? 1 : 0];
            [c[@"name"] setOpacity:f ? 1.0 : 0.62];
        });
    }
    CGPoint p = CGPointMake(110 - first * (kD + kGap), 56);
    if (animated) PXAnim(0.3, ^{ self->_content.position = p; }); else PXNoAnim(^{ self->_content.position = p; });
}

- (BOOL)moveBy:(NSInteger)delta {
    NSInteger t = _focusIndex + delta;
    if (t < 0 || t >= (NSInteger)_cells.count) return NO;
    _focusIndex = t;
    [self update:YES];
    return YES;
}

@end
