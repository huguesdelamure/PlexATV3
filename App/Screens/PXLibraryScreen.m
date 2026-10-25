// Library: poster grid of a whole section, loaded by pages of 60 as the
// focus moves, with cell recycling (only visible rows exist as layers).

#import "PXRouter.h"
#import "PXServer.h"
#import "PXUI.h"
#import "PXPosterLayer.h"
#import "PXPlex.h"
#import "PXItem.h"
#import "PXLog.h"
#import "PXSettings.h"
#import "PXAmbientPlex.h"

static const NSInteger kPage = 60;
static const CGFloat kGapX = 44, kGapY = 30, kTop = 250;

// Libraries of mostly unmatched files (TV recordings, home videos)
// have 16:9 video frames as artwork, unreadable once cropped into posters.
// Decided from the first page of items and remembered per section, so the
// grid opens directly in the right layout next time.
BOOL PXSectionIsLandscape(NSDictionary *section) {
    NSString *key = [section[@"key"] description];
    return key && [PXSettingGet(@"landscapeSections") containsObject:key];
}

static void PXRememberSectionLayout(NSDictionary *section, BOOL landscape) {
    NSString *key = [section[@"key"] description];
    if (!key || PXSectionIsLandscape(section) == landscape) return;
    NSMutableArray *list = [PXSettingGet(@"landscapeSections") mutableCopy] ?: [NSMutableArray array];
    if (landscape) [list addObject:key]; else [list removeObject:key];
    PXSettingSet(@"landscapeSections", list);
}

@interface PXLibraryScreen : PXScreen
@property (nonatomic, copy) NSDictionary *section;
@end

@implementation PXLibraryScreen {
    NSMutableArray *_items;          // PXItem or NSNull (not loaded yet)
    NSMutableSet *_loadingPages;
    NSInteger _total, _focus, _firstRow;
    CALayer *_grid;
    NSMutableDictionary *_cells;     // @(index) -> PXPosterLayer
    NSMutableArray *_pool;
    CATextLayer *_title, *_count;
    CGFloat _rowH, _left;
    NSInteger _cols;
    BOOL _landscape;
    CGSize _cellSize;
    PXArtwork _artwork;
    PXAmbientLayer *_ambient;
    CALayer *_chipsBar;
    NSArray *_filters;              // {title, query}
    NSMutableArray *_chips;         // {pill, text}
    NSInteger _filterIndex;
    BOOL _chipsFocused;
    NSString *_ambientKey;
}

- (void)setup {
    self.layer.backgroundColor = PXColorBackground();
    _ambient = [[PXAmbientLayer alloc] initWithFrame:self.layer.bounds style:PXAmbientBlurOnly];
    [self.layer addSublayer:_ambient];
    _items = [NSMutableArray array];
    _loadingPages = [NSMutableSet set];
    _cells = [NSMutableDictionary dictionary];
    _pool = [NSMutableArray array];
    _grid = [CALayer layer];
    _grid.anchorPoint = CGPointZero;
    [self.layer addSublayer:_grid];
    [self setLandscape:PXSectionIsLandscape(self.section)];

    CAGradientLayer *topFade = [CAGradientLayer layer];
    topFade.frame = CGRectMake(0, 0, 1920, kTop);
    topFade.colors = @[ (__bridge id)PXColorBlack(0.55), (__bridge id)PXColorBlack(0.35), (__bridge id)PXColorBlack(0) ];
    topFade.locations = @[ @0, @0.75, @1 ];
    [self.layer addSublayer:topFade];

    _title = PXText(PXFontHeavy(60), PXColorText());
    _title.frame = CGRectMake(_left, 50, 1200, 76);
    _title.string = self.section[@"title"] ?: @"";
    _count = PXText(PXFontMedium(28), PXColorTextDim());
    _count.alignmentMode = kCAAlignmentRight;
    _count.frame = CGRectMake(1920 - _left - 600, 72, 600, 40);
    [self.layer addSublayer:_title];
    [self.layer addSublayer:_count];
    if (self.embedded) {
        // Inside the home tabs: the tab names the library; count on the chips row.
        _title.hidden = YES;
        _count.frame = CGRectMake(1920 - _left - 600, 154, 600, 40);
    }
    BOOL shows = [self.section[@"type"] isEqual:@"show"];
    _filters = @[ @{ @"title": PXL(@"Tous"), @"query": @"sort=titleSort" },
                  @{ @"title": PXL(@"Non vus"), @"query": @"sort=titleSort&unwatched=1" },
                  @{ @"title": PXL(@"Ajouts récents"), @"query": @"sort=addedAt:desc" },
                  @{ @"title": PXL(@"Mieux notés"), @"query": @"sort=audienceRating:desc" },
                  @{ @"title": shows ? PXL(@"Dernière diffusion") : PXL(@"Les plus récents"), @"query": shows ? @"sort=episode.originallyAvailableAt:desc" : @"sort=originallyAvailableAt:desc" } ];
    _chipsBar = [CALayer layer];
    _chipsBar.frame = CGRectMake(_left, 150, 1700, 52);
    [self.layer addSublayer:_chipsBar];
    _chips = [NSMutableArray array];
    UIFont *f = PXFontSemi(24);
    CGFloat x = 0;
    for (NSDictionary *fd in _filters) {
        CGFloat w = PXTextWidth(fd[@"title"], f) + 40;
        CALayer *pill = [CALayer layer];
        pill.frame = CGRectMake(x, 0, w, 48);
        pill.cornerRadius = 24;
        CATextLayer *t = PXText(f, PXColorTextDim());
        t.alignmentMode = kCAAlignmentCenter;
        t.string = fd[@"title"];
        t.frame = CGRectMake(0, (48 - f.lineHeight) / 2 - 1, w, f.lineHeight + 2);
        [pill addSublayer:t];
        [_chipsBar addSublayer:pill];
        [_chips addObject:@{ @"pill": pill, @"text": t }];
        x += w + 10;
    }
    [self updateChips];
    [self loadPage:0];
}

- (void)setLandscape:(BOOL)landscape {
    _landscape = landscape;
    _cols = landscape ? 4 : 7;
    _cellSize = landscape ? CGSizeMake(380, 214) : CGSizeMake(200, 300);
    _artwork = landscape ? PXArtworkThumb : PXArtworkPoster;
    PXPosterLayer *probe = [[PXPosterLayer alloc] initWithImageSize:_cellSize artwork:_artwork];
    _rowH = probe.cellHeight + kGapY;
    _left = (1920 - (_cols * _cellSize.width + (_cols - 1) * kGapX)) / 2;
    // Cells of the other size cannot be reused.
    for (CALayer *c in [_grid.sublayers copy]) [c removeFromSuperlayer];   // visible and hidden (pooled) cells
    [_cells removeAllObjects];
    [_pool removeAllObjects];
    _firstRow = 0;
    PXNoAnim(^{ self->_grid.position = CGPointMake(self->_left, kTop); });
}

- (NSString *)pathForPage:(NSInteger)page {
    return [NSString stringWithFormat:@"/library/sections/%@/all?%@&X-Plex-Container-Start=%ld&X-Plex-Container-Size=%ld",
            self.section[@"key"], _filters[_filterIndex][@"query"], (long)(page * kPage), (long)kPage];
}

- (void)loadPage:(NSInteger)page {
    if ([_loadingPages containsObject:@(page)]) return;
    [_loadingPages addObject:@(page)];
    __weak PXLibraryScreen *weak = self;
    NSInteger filter = _filterIndex;
    [[[PXPlex shared] serverFor:self.section] get:[self pathForPage:page] done:^(NSDictionary *mc, NSError *err) {
        PXLibraryScreen *me = weak;
        if (!me || me->_filterIndex != filter) return;
        if (err) { [me->_loadingPages removeObject:@(page)]; PXSetText(me->_count, err.localizedDescription); return; }
        NSInteger total = [mc[@"totalSize"] integerValue] ?: [mc[@"size"] integerValue];
        if (me->_total != total) {
            me->_total = total;
            while ((NSInteger)me->_items.count < total) [me->_items addObject:[NSNull null]];
            PXSetText(me->_count, total > 1 ? PXLF(@"%ld titres", (long)total) : PXLF(@"%ld titre", (long)total));
        }
        NSArray *items = [PXItem itemsWithJSON:mc[@"Metadata"]];
        if (page == 0 && me->_filterIndex == 0) {
            BOOL landscape = PXItemsPreferLandscape(items);
            PXRememberSectionLayout(me.section, landscape);
            if (landscape != me->_landscape) {
                PXLog(@"library: %@ -> %@", me.section[@"title"], landscape ? @"16:9 cards" : @"posters");
                [me setLandscape:landscape];
            }
        }
        NSInteger start = page * kPage;
        for (NSUInteger i = 0; i < items.count && start + (NSInteger)i < (NSInteger)me->_items.count; i++)
            me->_items[start + i] = items[i];
        [me layoutCells:NO];
    }];
}

- (CGPoint)positionForIndex:(NSInteger)i {
    return CGPointMake((i % _cols) * (_cellSize.width + kGapX), (i / _cols) * _rowH);
}

- (void)layoutCells:(BOOL)animated {
    NSInteger rows = (_total + _cols - 1) / _cols;
    NSInteger focusRow = _focus / _cols;
    // The focused row is the first visible line: the next one only peeks in
    // below, so the focused card and its titles stay inside the TV safe area.
    _firstRow = MAX(0, MIN(focusRow, MAX(0, rows - 1)));

    NSInteger lo = MAX(0, (_firstRow - 1) * _cols), hi = MIN(_total - 1, (_firstRow + 3) * _cols - 1);
    // Recycled cells stay in the grid, hidden, and keep their content until
    // reused: detaching / re-attaching and clearing them cost 10-34 ms per
    // row change on the A5 (measured).
    PXNoAnim(^{
        for (NSNumber *k in self->_cells.allKeys) {
            NSInteger i = k.integerValue;
            if (i >= lo && i <= hi) continue;
            PXPosterLayer *c = self->_cells[k];
            c.hidden = YES;
            c.focused = NO;
            [self->_pool addObject:c];
            [self->_cells removeObjectForKey:k];
        }
    });
    for (NSInteger i = lo; i <= hi; i++) {
        id it = _items[i];
        if (it == [NSNull null]) [self loadPage:i / kPage];
        PXPosterLayer *c = _cells[@(i)];
        if (!c) {
            c = _pool.lastObject;
            if (c) [_pool removeLastObject];
            else c = [[PXPosterLayer alloc] initWithImageSize:_cellSize artwork:_artwork];
            c.focused = NO;
            PXNoAnim(^{
                c.position = [self positionForIndex:i];
                c.hidden = NO;
                if (c.superlayer != self->_grid) [self->_grid addSublayer:c];
            });
            _cells[@(i)] = c;
        }
        c.item = it == [NSNull null] ? nil : it;
        // Rows scrolled above the first line fade out instead of showing
        // through the filter chips and the tab bar.
        float alpha = i / _cols < _firstRow ? 0 : 1;
        if (c.opacity != alpha) PXAnim(0.25, ^{ c.opacity = alpha; });
        c.anchorLeft = i % _cols == 0;
        c.focused = i == _focus && !_chipsFocused && self.hasFocus;
    }
    CGPoint p = CGPointMake(_left, kTop - _firstRow * _rowH);
    if (animated) PXAnim(0.25, ^{ self->_grid.position = p; }); else PXNoAnim(^{ self->_grid.position = p; });
}

- (void)moveTo:(NSInteger)i {
    if (i < 0 || i >= _total) return;
    _focus = i;
    [self layoutCells:YES];
    [self updateAmbient];
}

- (void)updateAmbient {
    id it = _focus < (NSInteger)_items.count ? _items[_focus] : nil;
    if (![it isKindOfClass:[PXItem class]] || [[it ratingKey] isEqual:_ambientKey]) return;
    _ambientKey = [it ratingKey];
    [_ambient showItem:it];
}

- (void)focusChanged {
    // Entering from the tab bar lands on the filter chips.
    if (self.hasFocus && self.embedded) _chipsFocused = YES;
    [self updateChips];
    [self layoutCells:NO];
}

- (void)updateChips {
    PXAnim(0.2, ^{
        for (NSInteger i = 0; i < (NSInteger)self->_chips.count; i++) {
            BOOL sel = i == self->_filterIndex, foc = sel && self->_chipsFocused && self.hasFocus;
            CALayer *pill = self->_chips[i][@"pill"];
            CATextLayer *t = self->_chips[i][@"text"];
            pill.backgroundColor = foc ? PXColorText() : (sel ? PXColorPanelStrong() : PXColorWhite(0.06));
            t.foregroundColor = foc ? PXColorBlack(0.9) : (sel ? PXColorText() : PXColorTextDim());
            CGFloat k = foc ? 1.08 : 1.0;
            pill.transform = CATransform3DMakeScale(k, k, 1);
        }
    });
}

- (void)applyFilter:(NSInteger)index {
    if (index == _filterIndex) return;
    _filterIndex = index;
    [self updateChips];
    // Reset the grid and reload page 0 with the new sort/filter.
    for (PXPosterLayer *c in _cells.allValues) { c.hidden = YES; c.focused = NO; [_pool addObject:c]; }
    [_cells removeAllObjects];
    [_items removeAllObjects];
    [_loadingPages removeAllObjects];
    _total = 0;
    _focus = 0;
    _firstRow = 0;
    PXSetText(_count, @"");
    [self loadPage:0];
}

- (void)didAppear {
    [super didAppear];
    // Back from a detail screen: progress / watched state may have changed.
    if (_total) {
        NSInteger page = _focus / kPage;
        [_loadingPages removeObject:@(page)];
        [self loadPage:page];
    }
}

- (BOOL)handleKey:(PXKey)key {
    if (_chipsFocused) {
        switch (key) {
            case PXKeyLeft:  [self applyFilter:MAX(0, _filterIndex - 1)]; return YES;
            case PXKeyRight: [self applyFilter:MIN((NSInteger)_filters.count - 1, _filterIndex + 1)]; return YES;
            case PXKeyDown: case PXKeySelect:
                if (_total) { _chipsFocused = NO; [self updateChips]; [self layoutCells:YES]; }
                return YES;
            default: return NO;
        }
    }
    if (key == PXKeyUp && _focus < _cols) { _chipsFocused = YES; [self updateChips]; [self layoutCells:YES]; return YES; }
    switch (key) {
        case PXKeyLeft:  if (_focus % _cols) [self moveTo:_focus - 1]; return YES;
        case PXKeyRight: if (_focus % _cols < _cols - 1) [self moveTo:_focus + 1]; return YES;
        case PXKeyUp:    [self moveTo:_focus - _cols]; return YES;
        case PXKeyDown:  [self moveTo:MIN(_focus + _cols, _total - 1)]; return YES;
        case PXKeyFastForward: [self moveTo:MIN(_focus + _cols * 3, _total - 1)]; return YES;
        case PXKeyRewind: [self moveTo:MAX(_focus - _cols * 3, 0)]; return YES;
        case PXKeySelect: {
            id it = _focus < (NSInteger)_items.count ? _items[_focus] : nil;
            if ([it isKindOfClass:[PXItem class]]) [self push:PXScreenForItem(it)];
            return YES;
        }
        case PXKeyPlayPause: {
            PXItem *it = _focus < (NSInteger)_items.count ? _items[_focus] : nil;
            if ([it isKindOfClass:[PXItem class]] && it.type == PXItemMovie) [self push:PXPlayerScreenNew(it, it.viewOffset)];
            return YES;
        }
        default: return NO;
    }
}

@end

PXScreen *PXLibraryScreenNew(NSDictionary *section, BOOL embedded) {
    PXLibraryScreen *s = [PXLibraryScreen new];
    s.section = section;
    s.embedded = embedded;
    [s setup];
    return s;
}
