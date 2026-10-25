#import "PXButtonRow.h"

@implementation PXButton
+ (instancetype)icon:(PXIcon)icon title:(NSString *)title action:(void (^)(void))action {
    PXButton *b = [PXButton new];
    b.icon = icon;
    b.hasIcon = YES;
    b.title = title;
    b.action = action;
    return b;
}
+ (instancetype)title:(NSString *)title action:(void (^)(void))action {
    PXButton *b = [self icon:PXIconPlay title:title action:action];
    b.hasIcon = NO;
    return b;
}
@end

static const CGFloat kH = 72;

@implementation PXButtonRow {
    NSMutableArray *_views;   // {pill, text, icon}
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super init])) {
        self.frame = frame;
        _views = [NSMutableArray array];
        _active = YES;
    }
    return self;
}

- (void)setButtons:(NSArray *)buttons {
    _buttons = [buttons copy];
    for (NSDictionary *v in _views) [v[@"pill"] removeFromSuperlayer];
    [_views removeAllObjects];
    UIFont *f = PXFontSemi(27);
    CGFloat x = 0, maxW = self.bounds.size.width;
    for (PXButton *b in buttons) {
        CGFloat textW = MIN(PXTextWidth(b.title, f), 330);
        CGFloat iconW = b.hasIcon ? 30 : 0, gap = b.hasIcon && b.title.length ? 14 : 0;
        CGFloat w = (b.title.length ? textW : 0) + iconW + gap + (b.title.length ? 64 : 42);
        if (x + w > maxW) break;
        CALayer *pill = [CALayer layer];
        pill.frame = CGRectMake(x, 0, w, kH);
        pill.cornerRadius = kH / 2;
        pill.backgroundColor = PXColorPanel();
        pill.shadowColor = [UIColor blackColor].CGColor;
        pill.shadowPath = [UIBezierPath bezierPathWithRoundedRect:pill.bounds cornerRadius:kH / 2].CGPath;
        pill.shadowOffset = CGSizeMake(0, 10);
        pill.shadowRadius = 16;
        pill.shadowOpacity = 0;
        CGFloat cx = b.title.length ? 32 : (w - iconW) / 2;
        CAShapeLayer *icon = nil;
        if (b.hasIcon) {
            icon = PXIconLayer(b.icon, iconW, PXColorText());
            icon.position = CGPointMake(cx, (kH - iconW) / 2);
            [pill addSublayer:icon];
        }
        CATextLayer *t = PXText(f, PXColorText());
        t.string = b.title ?: @"";
        t.frame = CGRectMake(cx + iconW + gap, (kH - f.lineHeight) / 2 - 1, textW + 4, f.lineHeight + 2);
        [pill addSublayer:t];
        PXNoAnim(^{ [self addSublayer:pill]; });
        NSMutableDictionary *v = [@{ @"pill": pill, @"text": t } mutableCopy];
        if (icon) v[@"icon"] = icon;
        [_views addObject:v];
        x += w + 18;
    }
    _focusIndex = MAX(0, MIN(_focusIndex, (NSInteger)_views.count - 1));
    [self update:NO];
}

- (void)setActive:(BOOL)active { _active = active; [self update:YES]; }
- (void)setFocusIndex:(NSInteger)i { _focusIndex = MAX(0, MIN(i, (NSInteger)_views.count - 1)); [self update:YES]; }

static void recolorIcon(CAShapeLayer *icon, CGColorRef c) {
    if (icon.fillColor) icon.fillColor = c;
    if (icon.lineWidth > 0) icon.strokeColor = c;
    for (CAShapeLayer *sub in icon.sublayers) { if (sub.fillColor) sub.fillColor = c; sub.strokeColor = c; }
}

- (void)update:(BOOL)animated {
    for (NSInteger i = 0; i < (NSInteger)_views.count; i++) {
        NSDictionary *v = _views[i];
        BOOL f = _active && i == _focusIndex;
        CALayer *pill = v[@"pill"];
        BOOL was = [[pill valueForKey:@"pxFocused"] boolValue];
        [pill setValue:@(f) forKey:@"pxFocused"];
        void (^apply)(void) = ^{
            pill.backgroundColor = f ? PXColorText() : PXColorPanel();
            pill.shadowOpacity = f ? 0.5 : 0;
            CGColorRef c = f ? PXColorBlack(0.9) : PXColorText();
            [v[@"text"] setForegroundColor:c];
            recolorIcon(v[@"icon"], c);
        };
        if (animated) PXAnim(0.2, apply); else PXNoAnim(apply);
        if (f != was) {
            if (animated) PXSpringScale(pill, f ? 1.08 : 1.0);
            else PXNoAnim(^{ pill.transform = CATransform3DMakeScale(f ? 1.08 : 1, f ? 1.08 : 1, 1); });
        }
    }
}

- (BOOL)moveBy:(NSInteger)delta {
    NSInteger t = _focusIndex + delta;
    if (t < 0 || t >= (NSInteger)_views.count) return NO;
    _focusIndex = t;
    [self update:YES];
    return YES;
}

- (void)activate {
    if (_focusIndex < 0 || _focusIndex >= (NSInteger)_buttons.count) return;
    PXButton *b = _buttons[_focusIndex];
    if (b.action) b.action();
}

@end
