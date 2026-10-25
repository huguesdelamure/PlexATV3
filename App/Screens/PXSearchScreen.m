// Search: on-screen keyboard (letter grid) + live results by type
// (movies, shows, episodes) from /hubs/search, debounced while typing.

#import "PXRouter.h"
#import "PXKeyboard.h"
#import "PXUI.h"
#import "PXAmbientPlex.h"
#import "PXShelfLayer.h"
#import "PXPlex.h"
#import "PXPosterLayer.h"
#import "PXServer.h"
#import "PXItem.h"
#import "PXLog.h"

static const NSInteger kRowCount = 4;   // letter / digit rows of the layout (PXKeyboard.h)
static const CGFloat kKey = 76, kKeyGap = 10, kKbX = 110;
#define kKbY (200 + _top)

@interface PXSearchScreen : PXScreen
@end

@implementation PXSearchScreen {
    PXAmbientLayer *_ambient;
    CATextLayer *_query, *_hint;
    CALayer *_cursor;
    CALayer *_keyboard;
    NSMutableArray *_keys;          // rows of {layer, text, value}
    NSInteger _kr, _kc;             // focused key
    NSString *_kbLayout;            // layout the keyboard was built with
    BOOL _inResults;
    CALayer *_resultsLayer;
    NSMutableArray *_shelves;
    NSInteger _shelfIndex;
    NSMutableString *_text;
    NSInteger _searchSerial;
    CGFloat _top;                   // extra top offset under the home tab bar
}

- (instancetype)initEmbedded:(BOOL)embedded {
    if ((self = [super init])) {
        self.embedded = embedded;
        _top = embedded ? 70 : 0;
        _ambient = [[PXAmbientLayer alloc] initWithFrame:self.layer.bounds style:PXAmbientHome];
        [self.layer addSublayer:_ambient];
        _text = [NSMutableString string];
        _query = PXText(PXFontHeavy(64), PXColorText());
        _query.frame = CGRectMake(kKbX, 80 + _top, 1500, 80);
        [self.layer addSublayer:_query];
        _hint = PXText(PXFontHeavy(64), PXColorTextFaint());
        _hint.string = PXL(@"Rechercher");
        _hint.frame = _query.frame;
        [self.layer addSublayer:_hint];
        _cursor = [CALayer layer];
        _cursor.bounds = CGRectMake(0, 0, 5, 64);
        _cursor.backgroundColor = PXColorAccent();
        _cursor.cornerRadius = 2.5;
        CABasicAnimation *blink = [CABasicAnimation animationWithKeyPath:@"opacity"];
        blink.fromValue = @1; blink.toValue = @0; blink.duration = 0.6;
        blink.autoreverses = YES; blink.repeatCount = HUGE_VALF; blink.removedOnCompletion = NO;
        [_cursor addAnimation:blink forKey:@"blink"];
        [self.layer addSublayer:_cursor];
        [self buildKeyboard];
        _resultsLayer = [CALayer layer];
        _resultsLayer.anchorPoint = CGPointZero;
        _resultsLayer.position = CGPointMake(0, kKbY + 5 * (kKey + kKeyGap) + 30);
        [self.layer addSublayer:_resultsLayer];
        _shelves = [NSMutableArray array];
        [self updateQuery];
        [self updateKeys];
        [self showSuggestions];
    }
    return self;
}

// Before typing: continue watching and recent additions instead of an empty screen.
- (void)showSuggestions {
    NSInteger serial = _searchSerial;
    __weak PXSearchScreen *weak = self;
    [[PXPlex shared] get:@"/hubs?count=12" done:^(NSDictionary *mc, NSError *err) {
        PXSearchScreen *me = weak;
        if (!me || serial != me->_searchSerial || me->_text.length) return;
        NSMutableArray *rows = [NSMutableArray array];
        NSDictionary *wanted = @{ @"home.continue": PXL(@"Continuer à regarder"), @"home.movies.recent": PXL(@"Films ajoutés récemment"),
                                  @"home.television.recent": PXL(@"Séries ajoutées récemment") };
        for (NSString *hid in @[ @"home.continue", @"home.movies.recent", @"home.television.recent" ]) {
            for (NSDictionary *h in mc[@"Hub"]) {
                if (![h[@"hubIdentifier"] isEqual:hid]) continue;
                NSArray *items = [PXItem itemsWithJSON:h[@"Metadata"]];
                if (items.count) [rows addObject:@{ @"title": wanted[hid], @"items": items, @"type": [hid isEqual:@"home.continue"] ? @"episode" : @"movie" }];
            }
        }
        [me showResults:rows];
    }];
}

// Keyboard layout changed in Réglages since this screen was built.
- (void)didAppear {
    [super didAppear];
    if (_keyboard && ![_kbLayout isEqual:PXKeyboardLayout()]) { [self buildKeyboard]; [self updateKeys]; }
}

#pragma mark - Keyboard

- (void)buildKeyboard {
    CALayer *old = _keyboard;
    _keyboard = [CALayer layer];
    _keyboard.frame = CGRectMake(kKbX, kKbY, 1700, 5 * (kKey + kKeyGap));
    if (old) { [self.layer replaceSublayer:old with:_keyboard]; _kr = _kc = 0; }
    else [self.layer addSublayer:_keyboard];
    _kbLayout = PXKeyboardLayout();
    _keys = [NSMutableArray array];
    UIFont *f = PXFontSemi(34);
    NSArray *layoutRows = PXKeyboardRows();
    for (NSInteger r = 0; r <= kRowCount; r++) {
        NSMutableArray *row = [NSMutableArray array];
        NSArray *values;
        if (r < kRowCount) {
            NSMutableArray *v = [NSMutableArray array];
            NSString *row = layoutRows[r];
            for (NSUInteger i = 0; i < row.length; i++) [v addObject:[row substringWithRange:NSMakeRange(i, 1)]];
            values = v;
        } else {
            values = @[ @"espace", @"effacer", @"tout effacer" ];
        }
        CGFloat x = 0;
        for (NSString *v in values) {
            BOOL wide = v.length > 1;
            // Wide keys sized to their label in the UI language.
            CGFloat w = wide ? MAX(230, PXTextWidth(PXL(v), PXFontSemi(26)) + 70) : kKey;
            CALayer *k = [CALayer layer];
            k.frame = CGRectMake(x, r * (kKey + kKeyGap), w, kKey);
            k.cornerRadius = 14;
            k.backgroundColor = PXColorWhite(0.08);
            CATextLayer *t = PXText(wide ? PXFontSemi(26) : f, PXColorTextDim());
            t.alignmentMode = kCAAlignmentCenter;
            t.string = wide ? PXL(v) : [v uppercaseString];
            UIFont *tf = wide ? PXFontSemi(26) : f;
            t.frame = CGRectMake(0, (kKey - tf.lineHeight) / 2 - 1, w, tf.lineHeight + 2);
            [k addSublayer:t];
            [_keyboard addSublayer:k];
            [row addObject:@{ @"layer": k, @"text": t, @"value": v }];
            x += w + kKeyGap;
        }
        [_keys addObject:row];
    }
}

- (void)updateKeys {
    for (NSInteger r = 0; r < (NSInteger)_keys.count; r++) {
        for (NSInteger c = 0; c < (NSInteger)[_keys[r] count]; c++) {
            NSDictionary *k = _keys[r][c];
            BOOL f = !_inResults && self.hasFocus && r == _kr && c == _kc;
            CALayer *l = k[@"layer"];
            BOOL was = [[l valueForKey:@"pxFocused"] boolValue];
            [l setValue:@(f) forKey:@"pxFocused"];
            PXAnim(0.15, ^{
                l.backgroundColor = f ? PXColorText() : PXColorWhite(0.08);
                [k[@"text"] setForegroundColor:f ? PXColorBlack(0.9) : PXColorTextDim()];
            });
            if (f != was) PXSpringScale(l, f ? 1.12 : 1.0);
        }
    }
    PXAnim(0.3, ^{ self->_keyboard.opacity = self->_inResults ? 0 : 1; });
}

- (void)pressKey {
    NSString *v = _keys[_kr][_kc][@"value"];
    if ([v isEqual:@"espace"]) [_text appendString:@" "];
    else if ([v isEqual:@"effacer"]) { if (_text.length) [_text deleteCharactersInRange:NSMakeRange(_text.length - 1, 1)]; }
    else if ([v isEqual:@"tout effacer"]) [_text setString:@""];
    else [_text appendString:v];
    [self updateQuery];
    [self scheduleSearch];
}

- (void)updateQuery {
    PXNoAnim(^{
        PXSetText(self->_query, self->_text);
        self->_hint.hidden = self->_text.length > 0;
        CGFloat w = MIN(PXTextWidth(self->_text, PXFontHeavy(64)), 1500);
        self->_cursor.position = CGPointMake(kKbX + w + 8, 80 + 40 + self->_top);
    });
}

#pragma mark - Search

- (void)scheduleSearch {
    NSInteger serial = ++_searchSerial;
    NSString *q = [_text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    __weak PXSearchScreen *weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 450 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        PXSearchScreen *me = weak;
        if (!me || serial != me->_searchSerial) return;
        if (!q.length) { [me showSuggestions]; return; }
        if (q.length < 2) { [me showResults:@[]]; return; }
        [me searchAllServers:q serial:serial];
    });
}

// Unified search: every online server in parallel (primary first), results
// merged by type; servers slower than 5 s are left out of this round.
- (void)searchAllServers:(NSString *)q serial:(NSInteger)serial {
    PXPlex *plex = [PXPlex shared];
    NSMutableArray *servers = [NSMutableArray array];
    if (plex.primaryServer) [servers addObject:plex.primaryServer];
    for (PXServer *s in plex.servers) if (s.online && s != plex.primaryServer) [servers addObject:s];
    NSMutableDictionary *results = [NSMutableDictionary dictionary];   // identifier -> hubs
    __block NSInteger pending = servers.count;
    __block BOOL done = NO;
    __weak PXSearchScreen *weak = self;
    void (^finish)(void) = ^{
        if (done) return;
        done = YES;
        PXSearchScreen *me = weak;
        if (!me || serial != me->_searchSerial) return;
        NSDictionary *titles = @{ @"movie": PXL(@"Films"), @"show": PXL(@"Séries"), @"episode": PXL(@"Épisodes"), @"season": PXL(@"Saisons") };
        NSMutableDictionary *byType = [NSMutableDictionary dictionary];
        for (PXServer *s in servers)
            for (NSDictionary *h in results[s.identifier]) {
                NSString *type = h[@"type"];
                if (!titles[type ?: @""]) continue;
                NSMutableArray *list = byType[type] ?: (byType[type] = [NSMutableArray array]);
                for (PXItem *it in [PXItem itemsWithJSON:h[@"Metadata"]]) if (list.count < 30) [list addObject:it];
            }
        NSMutableArray *rows = [NSMutableArray array];
        for (NSString *type in @[ @"movie", @"show", @"season", @"episode" ])
            if ([byType[type] count]) [rows addObject:@{ @"title": titles[type], @"items": byType[type], @"type": type }];
        PXLog(@"search: '%@' %lu/%lu servers answered", q, (unsigned long)results.count, (unsigned long)servers.count);
        [me showResults:rows];
    };
    if (!pending) { finish(); return; }
    NSString *path = [NSString stringWithFormat:@"/hubs/search?query=%@&limit=10", PXEncode(q)];
    for (PXServer *s in servers) {
        [s get:path done:^(NSDictionary *mc, NSError *err) {
            if ([mc[@"Hub"] isKindOfClass:[NSArray class]]) results[s.identifier] = mc[@"Hub"];
            if (--pending == 0) finish();
        }];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), finish);
}

- (void)showResults:(NSArray *)rows {
    for (PXShelfLayer *s in _shelves) [s removeFromSuperlayer];
    [_shelves removeAllObjects];
    CGFloat y = 0;
    for (NSDictionary *r in rows) {
        BOOL episodes = [r[@"type"] isEqual:@"episode"];
        PXShelfLayer *s = [[PXShelfLayer alloc] initWithTitle:r[@"title"] width:1920
                                                    imageSize:episodes ? CGSizeMake(352, 198) : CGSizeMake(170, 255)
                                                      artwork:episodes ? PXArtworkThumb : PXArtworkPoster];
        // Results from other servers say where they are.
        s.configure = ^(PXPosterLayer *cell, PXItem *it, NSInteger i) {
            if (![it isKindOfClass:[PXItem class]] || it.server == [PXPlex shared].primaryServer) return;
            NSString *sub = it.type == PXItemEpisode ? it.episodeCode : it.shelfSubtitle;
            cell.subtitleOverride = sub.length ? [NSString stringWithFormat:@"%@ · %@", sub, it.server.name] : it.server.name;
        };
        s.items = r[@"items"];
        PXNoAnim(^{ s.position = CGPointMake(0, y); [self->_resultsLayer addSublayer:s]; });
        y += s.height - 10;
        [_shelves addObject:s];
    }
    _shelfIndex = 0;
    if (!_shelves.count) _inResults = NO;
    [self updateResultsFocus];
    PXItem *first = [_shelves.firstObject items].firstObject;
    if (first) [_ambient showItem:first];
}

- (void)updateResultsFocus {
    for (NSInteger i = 0; i < (NSInteger)_shelves.count; i++) [_shelves[i] setActive:_inResults && i == _shelfIndex];
    CGFloat base = kKbY + 5 * (kKey + kKeyGap) + 30;
    // In the results, the focused shelf moves up under the query line; the
    // keyboard, the empty-query hint and the shelves above it fade out.
    CGFloat y = _inResults ? 80 + _top + 110 - [_shelves[_shelfIndex] position].y : base;
    PXAnim(0.35, ^{
        self->_resultsLayer.position = CGPointMake(0, y);
        self->_keyboard.hidden = NO;
        self->_hint.opacity = self->_inResults ? 0 : 1;
        for (NSInteger i = 0; i < (NSInteger)self->_shelves.count; i++)
            [self->_shelves[i] setOpacity:self->_inResults && i < self->_shelfIndex ? 0 : 1];
    });
    [self updateKeys];
}

#pragma mark - Keys

- (BOOL)handleKey:(PXKey)key {
    if (_inResults) {
        PXShelfLayer *s = _shelves[_shelfIndex];
        switch (key) {
            case PXKeyLeft: case PXKeyRight:
                if ([s moveBy:key == PXKeyLeft ? -1 : 1] && s.focusedItem) [_ambient showItem:s.focusedItem];
                return YES;
            case PXKeyUp:
                if (_shelfIndex > 0) _shelfIndex--; else _inResults = NO;
                [self updateResultsFocus];
                return YES;
            case PXKeyDown:
                if (_shelfIndex < (NSInteger)_shelves.count - 1) { _shelfIndex++; [self updateResultsFocus]; }
                return YES;
            case PXKeySelect:
                if (s.focusedItem) [self push:PXScreenForItem(s.focusedItem)];
                return YES;
            case PXKeyMenu:
                _inResults = NO;
                [self updateResultsFocus];
                return YES;
            default: return NO;
        }
    }
    NSInteger rows = _keys.count;
    switch (key) {
        case PXKeyLeft:  if (_kc > 0) _kc--; [self updateKeys]; return YES;
        case PXKeyRight: if (_kc < (NSInteger)[_keys[_kr] count] - 1) _kc++; [self updateKeys]; return YES;
        case PXKeyUp:
            if (_kr > 0) { _kr--; _kc = MIN(_kc, (NSInteger)[_keys[_kr] count] - 1); [self updateKeys]; return YES; }
            return !self.embedded;   // top edge: back to the tabs
        case PXKeyDown:
            if (_kr < rows - 1) { _kr++; _kc = MIN(_kc * (_kr == rows - 1 ? 0 : 1), (NSInteger)[_keys[_kr] count] - 1); [self updateKeys]; }
            else if (_shelves.count) { _inResults = YES; [self updateResultsFocus]; }
            return YES;
        case PXKeySelect: [self pressKey]; return YES;
        case PXKeyPlayPause:
            // Play/pause = backspace, a common TV keyboard shortcut.
            if (_text.length) { [_text deleteCharactersInRange:NSMakeRange(_text.length - 1, 1)]; [self updateQuery]; [self scheduleSearch]; }
            return YES;
        default: return NO;
    }
}

- (void)focusChanged {
    [self updateKeys];
}

@end

PXScreen *PXSearchScreenNew(BOOL embedded) { return [[PXSearchScreen alloc] initEmbedded:embedded]; }
