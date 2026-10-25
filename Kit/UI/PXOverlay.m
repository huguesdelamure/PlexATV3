#import "PXOverlay.h"
#import "PXUI.h"

static const CGFloat kW = 760;

@implementation PXOverlay

+ (instancetype)overlayInLayer:(CALayer *)parent title:(NSString *)title rows:(NSArray *)rows {
    PXOverlay *o = [PXOverlay layer];
    CGSize s = parent.bounds.size;
    o.frame = parent.bounds;
    o.zPosition = 100;

    CALayer *dim = [CALayer layer];
    dim.frame = o.bounds;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45].CGColor;
    [o addSublayer:dim];

    CALayer *panel = [CALayer layer];
    panel.frame = CGRectMake(s.width - kW, 0, kW, s.height);
    panel.backgroundColor = [UIColor colorWithRed:0.07 green:0.075 blue:0.09 alpha:0.96].CGColor;
    panel.shadowColor = [UIColor blackColor].CGColor;
    panel.shadowOpacity = 0.6;
    panel.shadowRadius = 30;
    panel.shadowPath = [UIBezierPath bezierPathWithRect:panel.bounds].CGPath;
    [o addSublayer:panel];

    CATextLayer *t = PXText(PXFontHeavy(42), PXColorText());
    t.string = title;
    t.frame = CGRectMake(60, 90, kW - 120, 52);
    [panel addSublayer:t];

    PXListLayer *list = [[PXListLayer alloc] initWithFrame:CGRectMake(40, 180, kW - 80, s.height - 260) rowHeight:72];
    list.rows = rows;
    NSUInteger checked = [rows indexOfObjectPassingTest:^BOOL(PXListRow *r, NSUInteger i, BOOL *stop) { return r.checked; }];
    if (checked != NSNotFound) list.focusIndex = checked;
    [panel addSublayer:list];
    o->_list = list;

    PXNoAnim(^{ [parent addSublayer:o]; });
    // Slide in from the right.
    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"position.x"];
    slide.fromValue = @(panel.position.x + kW);
    slide.duration = 0.25;
    slide.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [panel addAnimation:slide forKey:@"in"];
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0;
    fade.duration = 0.25;
    [dim addAnimation:fade forKey:@"in"];
    return o;
}

- (void)close {
    PXNoAnim(^{ [self removeFromSuperlayer]; });
    if (self.onClose) self.onClose();
}

- (BOOL)handleKey:(PXKey)key {
    switch (key) {
        case PXKeyUp: [self.list handleUp]; break;
        case PXKeyDown: [self.list handleDown]; break;
        case PXKeySelect: case PXKeyPlayPause: [self.list activate]; break;
        case PXKeyMenu: case PXKeyLeft: [self close]; break;
        default: break;
    }
    return YES;
}

@end
