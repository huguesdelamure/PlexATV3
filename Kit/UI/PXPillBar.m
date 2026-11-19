#import "PXPillBar.h"
#import "PXUI.h"

@implementation PXPillBar {
    CGFloat _height;
    NSMutableArray *_texts;
}

- (instancetype)initWithHeight:(CGFloat)height {
    if ((self = [super init])) {
        _height = height;
        _font = PXFontSemi(24);
        _padding = 40;
        _gap = 10;
        _selectedColor = [UIColor colorWithCGColor:PXColorPanelStrong()];
        _pills = @[];
        _texts = [NSMutableArray array];
    }
    return self;
}

- (void)setTitles:(NSArray *)titles {
    _titles = [titles copy];
    for (CALayer *p in _pills) [p removeFromSuperlayer];
    [_texts removeAllObjects];
    NSMutableArray *pills = [NSMutableArray array];
    UIFont *f = _font;
    CGFloat x = 0, h = _height;
    for (NSString *title in titles) {
        CGFloat w = PXTextWidth(title, f) + _padding;
        CALayer *pill = [CALayer layer];
        pill.frame = CGRectMake(x, 0, w, h);
        pill.cornerRadius = h / 2;
        CATextLayer *t = PXText(f, PXColorTextDim());
        t.alignmentMode = kCAAlignmentCenter;
        t.string = title;
        t.frame = CGRectMake(0, (h - f.lineHeight) / 2 - 1, w, f.lineHeight + 2);
        [pill addSublayer:t];
        PXNoAnim(^{ [self addSublayer:pill]; });
        [pills addObject:pill];
        [_texts addObject:t];
        x += w + _gap;
    }
    _pills = pills;
}

- (void)setSelected:(NSInteger)selected focused:(NSInteger)focused {
    PXAnim(0.2, ^{
        for (NSInteger i = 0; i < (NSInteger)self->_pills.count; i++) {
            BOOL foc = i == focused, sel = i == selected;
            CALayer *pill = self->_pills[i];
            CATextLayer *t = self->_texts[i];
            pill.backgroundColor = foc ? PXColorText() : (sel ? self->_selectedColor.CGColor : self->_idleColor.CGColor);
            t.foregroundColor = foc ? PXColorBlack(0.9) : (sel ? PXColorText() : PXColorTextDim());
            CGFloat k = foc ? 1.08 : 1.0;
            pill.transform = CATransform3DMakeScale(k, k, 1);
        }
    });
}

@end
