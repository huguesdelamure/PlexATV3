#import "PXListLayer.h"
#import "PXUI.h"

@implementation PXListRow
+ (instancetype)title:(NSString *)title value:(NSString *)value action:(void (^)(void))action {
    PXListRow *r = [PXListRow new];
    r.title = title;
    r.value = value;
    r.action = action;
    r.enabled = YES;
    return r;
}
@end

@implementation PXListLayer {
    CGFloat _rowH;
    CALayer *_content;
    CALayer *_highlight;
    NSMutableArray *_rowLayers;   // {title, value, check}
}

- (instancetype)initWithFrame:(CGRect)frame rowHeight:(CGFloat)rowHeight {
    if ((self = [super init])) {
        self.frame = frame;
        self.masksToBounds = YES;
        _rowH = rowHeight;
        _content = [CALayer layer];
        _content.anchorPoint = CGPointZero;
        _content.bounds = CGRectMake(0, 0, frame.size.width, frame.size.height);
        [self addSublayer:_content];
        _highlight = [CALayer layer];
        _highlight.backgroundColor = PXColorText();
        _highlight.cornerRadius = 12;
        _highlight.anchorPoint = CGPointZero;
        _highlight.bounds = CGRectMake(0, 0, frame.size.width, rowHeight - 6);
        [_content addSublayer:_highlight];
        _rowLayers = [NSMutableArray array];
        _active = YES;
    }
    return self;
}

- (void)setRows:(NSArray *)rows {
    _rows = [rows copy];
    for (NSDictionary *d in _rowLayers) for (CALayer *l in d.allValues) [l removeFromSuperlayer];
    [_rowLayers removeAllObjects];
    CGFloat w = self.bounds.size.width;
    UIFont *f = PXFontMedium(_rowH * 0.4);
    PXNoAnim(^{
        for (NSUInteger i = 0; i < rows.count; i++) {
            PXListRow *r = rows[i];
            CGFloat y = i * self->_rowH + (self->_rowH - 6 - f.lineHeight) / 2;
            CATextLayer *check = PXText(f, PXColorText());
            check.frame = CGRectMake(18, y, 40, f.lineHeight + 4);
            check.string = r.checked ? @"✓" : @"";
            CATextLayer *t = PXText(f, r.enabled ? PXColorText() : PXColorTextDim());
            t.frame = CGRectMake(62, y, w * 0.62 - 62, f.lineHeight + 4);
            t.string = r.title ?: @"";
            CATextLayer *v = PXText(f, PXColorTextDim());
            v.alignmentMode = kCAAlignmentRight;
            v.frame = CGRectMake(w * 0.62, y, w * 0.38 - 24, f.lineHeight + 4);
            v.string = r.value ?: @"";
            for (CALayer *l in @[ check, t, v ]) [self->_content addSublayer:l];
            [self->_rowLayers addObject:@{ @"check": check, @"title": t, @"value": v }];
        }
        self->_content.bounds = CGRectMake(0, 0, w, MAX(self.bounds.size.height, rows.count * self->_rowH));
    });
    _focusIndex = MAX(0, MIN(_focusIndex, (NSInteger)rows.count - 1));
    [self update:NO];
}

- (void)setFocusIndex:(NSInteger)i { _focusIndex = MAX(0, MIN(i, (NSInteger)_rows.count - 1)); [self update:NO]; }
- (void)setActive:(BOOL)active { _active = active; [self update:YES]; }

- (void)update:(BOOL)animated {
    void (^apply)(void) = ^{
        self->_highlight.hidden = !self->_active || !self->_rows.count;
        self->_highlight.position = CGPointMake(0, self->_focusIndex * self->_rowH);
        for (NSInteger i = 0; i < (NSInteger)self->_rowLayers.count; i++) {
            BOOL f = self->_active && i == self->_focusIndex;
            PXListRow *r = self->_rows[i];
            NSDictionary *d = self->_rowLayers[i];
            [d[@"title"] setForegroundColor:f ? PXColorBlack(0.9) : (r.enabled ? PXColorText() : PXColorTextDim())];
            [d[@"value"] setForegroundColor:f ? [UIColor colorWithWhite:0 alpha:0.7].CGColor : PXColorTextDim()];
            [d[@"check"] setForegroundColor:f ? PXColorBlack(0.9) : PXColorAccent()];
        }
        // Keep the focused row visible.
        CGFloat h = self.bounds.size.height, rowY = self->_focusIndex * self->_rowH;
        CGFloat off = -self->_content.position.y;
        if (rowY < off) off = rowY;
        if (rowY + self->_rowH > off + h) off = rowY + self->_rowH - h;
        self->_content.position = CGPointMake(0, -off);
    };
    if (animated) PXAnim(0.15, apply); else PXNoAnim(apply);
}

- (BOOL)handleUp {
    if (_focusIndex <= 0) return NO;
    _focusIndex--;
    [self update:YES];
    return YES;
}

- (BOOL)handleDown {
    if (_focusIndex >= (NSInteger)_rows.count - 1) return NO;
    _focusIndex++;
    [self update:YES];
    return YES;
}

- (void)activate {
    if (_focusIndex < 0 || _focusIndex >= (NSInteger)_rows.count) return;
    PXListRow *r = _rows[_focusIndex];
    if (r.enabled && r.action) r.action();
}

@end
