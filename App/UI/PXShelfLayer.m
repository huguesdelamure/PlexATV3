#import "PXShelfLayer.h"
#import "PXUI.h"

static const CGFloat kGap = 36;
static const CGFloat kTitleH = 56;

@implementation PXShelfLayer {
    CGFloat _width;
    CGSize _imageSize;
    PXArtwork _artwork;
    CATextLayer *_titleLayer;
    CALayer *_content;
    NSMutableDictionary *_cells;   // @(index) -> PXPosterLayer
    NSMutableArray *_pool;
    NSInteger _first;              // first visible index
}

- (instancetype)initWithTitle:(NSString *)title width:(CGFloat)width imageSize:(CGSize)size artwork:(PXArtwork)artwork {
    if ((self = [super init])) {
        _width = width;
        _imageSize = size;
        _artwork = artwork;
        _leftMargin = 110;
        _cells = [NSMutableDictionary dictionary];
        _pool = [NSMutableArray array];
        _titleLayer = PXText(PXFontBold(30), PXColorWhite(0.92));
        [self addSublayer:_titleLayer];
        _content = [CALayer layer];
        _content.anchorPoint = CGPointZero;
        [self addSublayer:_content];
        PXPosterLayer *probe = [[PXPosterLayer alloc] initWithImageSize:size artwork:artwork];
        _height = kTitleH + probe.cellHeight + 30;
        self.anchorPoint = CGPointZero;
        self.bounds = CGRectMake(0, 0, width, _height);
        self.title = title;
        PXNoAnim(^{
            self->_titleLayer.frame = CGRectMake(self->_leftMargin, 0, width - 2 * self->_leftMargin, 42);
            self->_content.position = CGPointMake(self->_leftMargin, kTitleH);
        });
    }
    return self;
}

- (void)setTitle:(NSString *)title { _title = [title copy]; PXSetText(_titleLayer, title); }

- (void)setLeftMargin:(CGFloat)m {
    _leftMargin = m;
    PXNoAnim(^{
        self->_titleLayer.frame = CGRectMake(m, 0, self->_width - 2 * m, 42);
    });
    [self scrollAnimated:NO];
}

- (NSInteger)visibleCount {
    return MAX(1, (NSInteger)floor((_width - _leftMargin + kGap) / (_imageSize.width + kGap)));
}

- (void)setItems:(NSArray *)items {
    _items = [items copy];
    for (PXPosterLayer *c in _cells.allValues) { PXNoAnim(^{ c.hidden = YES; }); c.focused = NO; [_pool addObject:c]; }
    [_cells removeAllObjects];
    _focusIndex = MIN(_focusIndex, (NSInteger)items.count - 1);
    if (_focusIndex < 0) _focusIndex = 0;
    _first = MIN(_first, _focusIndex);
    [self scrollAnimated:NO];
}

- (void)reloadCells {
    for (NSNumber *k in _cells) {
        PXPosterLayer *c = _cells[k];
        NSInteger i = k.integerValue;
        if (i < (NSInteger)_items.count) {
            c.item = nil;      // force refresh
            [self configureCell:c index:i];
        }
    }
}

- (void)configureCell:(PXPosterLayer *)c index:(NSInteger)i {
    id it = _items[i];
    c.item = [it isKindOfClass:[NSNull class]] ? nil : it;
    if (self.configure) self.configure(c, it, i);
}

- (PXPosterLayer *)cellForIndex:(NSInteger)i {
    PXPosterLayer *c = _cells[@(i)];
    if (c) return c;
    c = _pool.lastObject;
    if (c) [_pool removeLastObject];
    else c = [[PXPosterLayer alloc] initWithImageSize:_imageSize artwork:_artwork];
    c.focused = NO;
    [self configureCell:c index:i];
    PXNoAnim(^{
        c.position = CGPointMake(i * (self->_imageSize.width + kGap), 0);
        c.hidden = NO;
        if (c.superlayer != self->_content) [self->_content addSublayer:c];
    });
    _cells[@(i)] = c;
    return c;
}

- (void)scrollAnimated:(BOOL)animated {
    NSInteger n = _items.count, v = [self visibleCount];
    if (_focusIndex < _first) _first = _focusIndex;
    if (_focusIndex >= _first + v) _first = _focusIndex - v + 1;
    _first = MAX(0, MIN(_first, MAX(0, n - v)));
    // Materialise visible cells (+2 each side), recycle the others.
    NSInteger lo = MAX(0, _first - 2), hi = MIN(n - 1, _first + v + 2);
    // Recycled cells stay attached, hidden, with their content until reused
    // (detach + clear measured at 10-30 ms per scroll step on the A5).
    for (NSNumber *k in _cells.allKeys) {
        NSInteger i = k.integerValue;
        if (i < lo || i > hi) {
            PXPosterLayer *c = _cells[k];
            PXNoAnim(^{ c.hidden = YES; });
            c.focused = NO;
            [_pool addObject:c];
            [_cells removeObjectForKey:k];
        }
    }
    for (NSInteger i = lo; i <= hi; i++) [self cellForIndex:i];
    CGPoint p = CGPointMake(_leftMargin - _first * (_imageSize.width + kGap), kTitleH);
    if (animated) PXAnim(0.25, ^{ self->_content.position = p; });
    else PXNoAnim(^{ self->_content.position = p; });
    for (NSNumber *k in _cells) {
        PXPosterLayer *c = _cells[k];
        c.anchorLeft = k.integerValue == _first;
        c.focused = _active && k.integerValue == _focusIndex;
    }
}

- (void)setActive:(BOOL)active {
    _active = active;
    [self scrollAnimated:NO];
}

- (BOOL)moveBy:(NSInteger)delta {
    NSInteger target = _focusIndex + delta;
    if (target < 0 || target >= (NSInteger)_items.count) return NO;
    _focusIndex = target;
    [self scrollAnimated:YES];
    return YES;
}

- (void)setFocusIndex:(NSInteger)index animated:(BOOL)animated {
    if (!_items.count) return;
    _focusIndex = MAX(0, MIN(index, (NSInteger)_items.count - 1));
    [self scrollAnimated:animated];
}

- (id)focusedItem {
    if (_focusIndex < 0 || _focusIndex >= (NSInteger)_items.count) return nil;
    id it = _items[_focusIndex];
    return [it isKindOfClass:[NSNull class]] ? nil : it;
}

@end
