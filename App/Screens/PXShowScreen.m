// TV show page (scrolls vertically):
//   header    backdrop, title, metadata, ratings, summary, buttons
//             (resume/play next episode, mark watched)
//   seasons   pill tabs
//   episodes  16:9 cards; the focused episode's summary is shown below
// Opened from a show or directly from a season (preselects it).

#import "PXRouter.h"
#import "PXMusicPlayer.h"
#import "PXSettings.h"
#import <AVFoundation/AVFoundation.h>
#import "PXServer.h"
#import "PXBackRow.h"
#import "PXUI.h"
#import "PXAmbientPlex.h"
#import "PXButtonRow.h"
#import "PXDecor.h"
#import "PXShelfLayer.h"
#import "PXPlex.h"
#import "PXItem.h"
#import "PXLog.h"

PXScreen *PXDetailScreenNew(PXItem *item);

static const CGFloat kLeft = 110, kTextW = 1100, kButtonsY = 660, kSeasonsY = 800, kEpisodesY = 880;

typedef NS_ENUM(NSInteger, PXShowZone) { PXShowButtons, PXShowSeasons, PXShowEpisodes };

@interface PXShowScreen : PXScreen
@property (nonatomic, copy) NSString *showKey;
@property (nonatomic, strong) PXServer *server;
@property (nonatomic, copy) NSString *seasonKey;    // season to preselect
@end

@implementation PXShowScreen {
    AVPlayer *_theme;               // theme song, once per visit
    BOOL _themePlayed;
    PXAmbientLayer *_ambient;
    CALayer *_page, *_header;
    PXButtonRow *_buttons;
    CALayer *_seasonsBar, *_seasonsContent;
    BOOL _userMovedSeason;
    NSArray *_seasons;              // PXItem
    NSMutableArray *_seasonPills;   // {pill, text}
    NSInteger _seasonIndex;
    PXShelfLayer *_episodes;
    CALayer *_epTitle, *_epSummary;   // drawn off the main thread
    PXShowZone _zone;
    PXItem *_show, *_onDeck;
    NSString *_loadedSeason;
}

- (void)setup {
    _ambient = [[PXAmbientLayer alloc] initWithFrame:self.layer.bounds style:PXAmbientDetail];
    [self.layer addSublayer:_ambient];
    _page = [CALayer layer];
    _page.anchorPoint = CGPointZero;
    _page.bounds = CGRectMake(0, 0, 1920, 1700);
    [self.layer addSublayer:_page];
    _header = [CALayer layer];
    _header.frame = CGRectMake(0, 0, 1920, kButtonsY);
    [_page addSublayer:_header];
    _buttons = [[PXButtonRow alloc] initWithFrame:CGRectMake(kLeft, kButtonsY, 1700, 80)];
    [_page addSublayer:_buttons];
    _seasonsBar = [CALayer layer];
    _seasonsBar.frame = CGRectMake(0, kSeasonsY - 10, 1920, 76);
    _seasonsBar.masksToBounds = YES;     // plain layer, no rounded corners: no offscreen pass
    [_page addSublayer:_seasonsBar];
    _seasonsContent = [CALayer layer];
    _seasonsContent.anchorPoint = CGPointZero;
    _seasonsContent.position = CGPointMake(kLeft, 10);
    [_seasonsBar addSublayer:_seasonsContent];
    _seasonPills = [NSMutableArray array];
    _episodes = [[PXShelfLayer alloc] initWithTitle:@"" width:1920 imageSize:CGSizeMake(400, 225) artwork:PXArtworkThumb];
    _episodes.leftMargin = kLeft;
    _episodes.position = CGPointMake(0, kEpisodesY - 56);   // shelf title row unused
    _episodes.configure = ^(PXPosterLayer *c, PXItem *ep, NSInteger i) {
        c.titleOverride = [NSString stringWithFormat:@"%ld. %@", (long)ep.index, ep.title];
        c.subtitleOverride = ep.remainingText ?: (ep.duration > 0 ? PXDurationText(ep.duration) : @"");
    };
    [_page addSublayer:_episodes];
    _epTitle = PXAsyncLabel(nil, PXFontBold(32), PXColorText(), CGRectZero, 1, NO);
    // Below the episode cards (titles may take 2 lines).
    _epTitle.frame = CGRectMake(kLeft, kEpisodesY + 362, kTextW, 42);
    _epSummary = PXAsyncLabel(nil, PXFont(26), PXColorWhite(0.8), CGRectZero, 4, NO);
    _epSummary.frame = CGRectMake(kLeft, kEpisodesY + 412, 1400, 150);
    [_page addSublayer:_epTitle];
    [_page addSublayer:_epSummary];
    [self loadShow];
}

#pragma mark - Data

- (void)loadShow {
    __weak PXShowScreen *weak = self;
    [self.server get:[NSString stringWithFormat:@"/library/metadata/%@?includeOnDeck=1", self.showKey] done:^(NSDictionary *mc, NSError *err) {
        PXShowScreen *me = weak;
        id m = [mc[@"Metadata"] isKindOfClass:[NSArray class]] ? [mc[@"Metadata"] firstObject] : nil;
        if (!me || !m) return;
        me->_show = [PXItem itemWithJSON:m];
        id od = m[@"OnDeck"][@"Metadata"];
        if ([od isKindOfClass:[NSArray class]]) od = [od firstObject];
        me->_onDeck = [PXItem itemWithJSON:od];
        [me->_ambient showItem:me->_show];
        [me selectOnDeckSeason];
        [me renderHeader];
        [me playTheme];
    }];
    [self loadSeasons];
}

- (void)renderHeader {
    PXItem *it = _show;
    for (CALayer *l in [_header.sublayers copy]) [l removeFromSuperlayer];
    CGFloat y = 130;
    UIFont *tf = PXFitFont(it.title, PXHeavy, 84, 48, kTextW, 2);
    CGFloat th = MIN(PXTextHeight(it.title, tf, kTextW - 12), ceil(tf.lineHeight) * 2) + 6;
    // Texts drawn off the main thread (CATextLayers stall the commit on the A5).
    [_header addSublayer:PXAsyncLabel(it.title, tf, PXColorText(), CGRectMake(kLeft, y, kTextW - 12, th), 2, NO)];
    y += th + 14;
    NSMutableArray *meta = [NSMutableArray array];
    if (it.year) [meta addObject:[@(it.year) stringValue]];
    if (it.childCount) [meta addObject:it.shelfSubtitle];
    if (it.leafCount) [meta addObject:it.leafCount > 1 ? PXLF(@"%ld épisodes", (long)it.leafCount) : PXLF(@"%ld épisode", (long)it.leafCount)];
    if (it.contentRating.length) [meta addObject:it.contentRating];
    if (it.studio.length) [meta addObject:it.studio];
    [_header addSublayer:PXAsyncLabel([meta componentsJoinedByString:@"   ·   "], PXFontMedium(28), PXColorTextDim(), CGRectMake(kLeft, y, kTextW, 38), 1, NO)];
    y += 54;
    CALayer *ratings = PXRatingsRow(it.ratings, CGPointMake(kLeft, y));
    if (ratings.bounds.size.width > 0) { [_header addSublayer:ratings]; y += 60; }
    UIFont *sf = PXFont(28);
    CGFloat sh = MIN(PXTextHeight(it.summary, sf, kTextW), floor((kButtonsY - 40 - y) / sf.lineHeight) * sf.lineHeight);
    NSInteger lines = MAX(0, (NSInteger)floor((kButtonsY - 40 - y) / sf.lineHeight));
    if (lines && sh > 0) [_header addSublayer:PXAsyncLabel(it.summary, sf, PXColorWhite(0.82), CGRectMake(kLeft, y, kTextW, sh), lines, NO)];

    __weak PXShowScreen *weak = self;
    NSMutableArray *b = [NSMutableArray array];
    PXItem *next = _onDeck;
    if (next) {
        NSString *label = next.viewOffset > 30 ? PXLF(@"Reprendre %@", next.episodeCode)
                                               : PXLF(@"Lire %@", next.episodeCode);
        [b addObject:[PXButton icon:PXIconPlay title:label action:^{
            PXShowScreen *me = weak;
            PXItem *n = me ? me->_onDeck : nil;
            if (n) [me push:PXPlayerScreenNew(n, n.viewOffset > 30 ? n.viewOffset : 0)];
        }]];
    }
    [b addObject:[PXButton icon:PXIconNext title:PXL(@"Aléatoire") action:^{ [weak shuffleShow]; }]];
    [b addObject:[PXButton icon:PXIconCheck title:it.watched ? PXL(@"Série vue") : PXL(@"Marquer la série vue") action:^{
        PXShowScreen *me = weak;
        if (!me) return;
        [[PXPlex shared] setWatched:!me->_show.watched item:me->_show.raw];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 800 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [weak refresh]; });
    }]];
    _buttons.buttons = b;
    _buttons.active = _zone == PXShowButtons;
}

- (void)loadSeasons {
    __weak PXShowScreen *weak = self;
    [self.server get:[NSString stringWithFormat:@"/library/metadata/%@/children", self.showKey] done:^(NSDictionary *mc, NSError *err) {
        PXShowScreen *me = weak;
        if (!me) return;
        NSMutableArray *seasons = [NSMutableArray array];
        for (PXItem *it in [PXItem itemsWithJSON:mc[@"Metadata"]]) if (it.type == PXItemSeason) [seasons addObject:it];
        me->_seasons = seasons;
        NSInteger pick = -1;
        for (NSUInteger i = 0; i < seasons.count; i++) if ([[seasons[i] ratingKey] isEqual:me.seasonKey]) pick = i;
        if (pick < 0 && !me->_loadedSeason) for (NSUInteger i = 0; i < seasons.count && pick < 0; i++) if ([seasons[i] unwatchedLeaves]) pick = i;
        if (pick >= 0) me->_seasonIndex = pick;
        if (me.seasonKey) { me->_zone = PXShowEpisodes; }
        me.seasonKey = nil;
        me->_seasonIndex = MIN(me->_seasonIndex, MAX(0, (NSInteger)seasons.count - 1));
        [me buildSeasonPills];
        [me loadEpisodes];
        [me selectOnDeckSeason];
        [me applyZone:NO];
    }];
}

// Default season: the one holding the next episode to watch.
- (void)selectOnDeckSeason {
    if (_userMovedSeason || !_onDeck.parentRatingKey || !_seasons.count) return;
    for (NSUInteger i = 0; i < _seasons.count; i++) {
        if (![[_seasons[i] ratingKey] isEqual:_onDeck.parentRatingKey] || (NSInteger)i == _seasonIndex) continue;
        _seasonIndex = i;
        [self updateSeasonPills];
        [self loadEpisodes];
        return;
    }
}

- (void)buildSeasonPills {
    for (NSDictionary *p in _seasonPills) [p[@"pill"] removeFromSuperlayer];
    [_seasonPills removeAllObjects];
    UIFont *f = PXFontSemi(26);
    CGFloat x = 0;
    for (PXItem *s in _seasons) {
        NSString *t = s.title;
        CGFloat w = PXTextWidth(t, f) + 44;
        CALayer *pill = [CALayer layer];
        pill.frame = CGRectMake(x, 0, w, 52);
        pill.cornerRadius = 26;
        CATextLayer *tl = PXText(f, PXColorTextDim());
        tl.alignmentMode = kCAAlignmentCenter;
        tl.string = t;
        tl.frame = CGRectMake(0, (52 - f.lineHeight) / 2 - 1, w, f.lineHeight + 2);
        [pill addSublayer:tl];
        // Unwatched dot on seasons with new episodes.
        if (s.unwatchedLeaves) {
            CALayer *dot = [CALayer layer];
            dot.frame = CGRectMake(w - 16, 8, 10, 10);
            dot.cornerRadius = 5;
            dot.backgroundColor = PXColorAccent();
            [pill addSublayer:dot];
        }
        PXNoAnim(^{ [self->_seasonsContent addSublayer:pill]; });
        [_seasonPills addObject:@{ @"pill": pill, @"text": tl }];
        x += w + 8;
    }
    [self updateSeasonPills];
}

- (void)updateSeasonPills {
    // Keep the selected pill inside the visible width.
    if (_seasonIndex < (NSInteger)_seasonPills.count) {
        CALayer *sel = _seasonPills[_seasonIndex][@"pill"];
        CGFloat x = -(_seasonsContent.position.x - kLeft);
        CGFloat left = CGRectGetMinX(sel.frame), right = CGRectGetMaxX(sel.frame), visible = 1920 - 2 * kLeft;
        if (left < x) x = left;
        if (right > x + visible) x = right - visible;
        PXAnim(0.3, ^{ self->_seasonsContent.position = CGPointMake(kLeft - x, 10); });
    }
    PXAnim(0.2, ^{
        for (NSInteger i = 0; i < (NSInteger)self->_seasonPills.count; i++) {
            BOOL selected = i == self->_seasonIndex;
            BOOL focused = selected && self->_zone == PXShowSeasons;
            CALayer *pill = self->_seasonPills[i][@"pill"];
            CATextLayer *t = self->_seasonPills[i][@"text"];
            pill.backgroundColor = focused ? PXColorText() : (selected ? PXColorPanelStrong() : [UIColor clearColor].CGColor);
            t.foregroundColor = focused ? PXColorBlack(0.9) : (selected ? PXColorText() : PXColorTextDim());
            CGFloat k = focused ? 1.08 : 1.0;
            pill.transform = CATransform3DMakeScale(k, k, 1);
        }
    });
}

- (void)loadEpisodes {
    if (_seasonIndex >= (NSInteger)_seasons.count) return;
    PXItem *season = _seasons[_seasonIndex];
    BOOL same = [season.ratingKey isEqual:_loadedSeason];
    _loadedSeason = season.ratingKey;
    __weak PXShowScreen *weak = self;
    [self.server get:[NSString stringWithFormat:@"/library/metadata/%@/children", season.ratingKey] done:^(NSDictionary *mc, NSError *err) {
        PXShowScreen *me = weak;
        if (!me || ![me->_loadedSeason isEqual:season.ratingKey]) return;
        NSArray *eps = [PXItem itemsWithJSON:mc[@"Metadata"]];
        NSInteger keep = same ? me->_episodes.focusIndex : -1;
        me->_episodes.items = eps;
        NSInteger pick = keep;
        for (NSUInteger i = 0; i < eps.count && pick < 0; i++) if (![eps[i] watched]) pick = i;
        [me->_episodes setFocusIndex:MAX(0, pick) animated:NO];
        [me showEpisodeInfo];
    }];
}

- (void)showEpisodeInfo {
    PXItem *ep = _episodes.focusedItem;
    CATransition *fade = [CATransition animation];
    fade.duration = 0.25;
    [_epSummary addAnimation:fade forKey:@"fade"];
    [_epTitle addAnimation:fade forKey:@"fade"];
    PXDrawTextAsync(_epTitle, ep ? [NSString stringWithFormat:@"%@ · %@", ep.episodeCode, ep.title] : @"", PXFontBold(32), PXColorText(), kTextW, 1, 0);
    PXDrawTextAsync(_epSummary, ep.summary ?: @"", PXFont(26), PXColorWhite(0.8), 1400, 4, 0);
}

- (void)refresh {
    [self loadShow];
}

#pragma mark - Focus

- (void)applyZone:(BOOL)animated {
    _buttons.active = _zone == PXShowButtons;
    _episodes.active = _zone == PXShowEpisodes;
    [self updateSeasonPills];
    CGFloat offset = _zone == PXShowButtons ? 0 : kSeasonsY - 330;
    BOOL lower = _zone != PXShowButtons;
    void (^apply)(void) = ^{
        self->_page.position = CGPointMake(0, -offset);
        self->_header.opacity = lower ? 0.0 : 1;
        self->_buttons.opacity = lower ? 0.35 : 1;
        // Also on the season pills: the lower half is otherwise empty.
        self->_epTitle.opacity = self->_epSummary.opacity = self->_zone == PXShowEpisodes ? 1 : (lower ? 0.7 : 0.0);
    };
    if (animated) PXAnim(0.4, apply); else PXNoAnim(apply);
    [_ambient setArtOpacity:lower ? 0.45 : 0.9];
}

- (void)didAppear {
    [super didAppear];
    if (_loadedSeason) { [self loadShow]; }   // refresh progress after playback
}

// Every episode of the show in random order.
- (void)shuffleShow {
    __weak PXShowScreen *weak = self;
    [self.server get:[NSString stringWithFormat:@"/library/metadata/%@/allLeaves", self.showKey] done:^(NSDictionary *mc, NSError *err) {
        PXShowScreen *me = weak;
        NSMutableArray *eps = [[PXItem itemsWithJSON:mc[@"Metadata"]] mutableCopy];
        if (!me || !eps.count) return;
        for (NSUInteger i = eps.count; i > 1; i--) [eps exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
        [me push:PXPlayerScreenNewQueue(eps)];
    }];
}

// Theme song of the show, quietly, like the official apps (Réglages can turn
// it off); not over music that is already playing.
- (void)playTheme {
    NSString *theme = _show.raw[@"theme"];
    if (_themePlayed || ![theme isKindOfClass:[NSString class]] || [PXSettingGet(@"themeMusic") isEqual:@NO]
        || [PXMusicPlayer shared].active || !self.isOnTop || !self.server.uri) return;
    _themePlayed = YES;
    NSURL *u = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@?%@", self.server.uri, theme, [self.server plexQuery]]];
    _theme = [AVPlayer playerWithURL:u];
    NSNumber *v = PXSettingGet(@"volume");
    _theme.volume = 0.35 * (v ? v.floatValue : 1);
    [_theme play];
    PXLog(@"show: theme song of '%@'", _show.title);
}

- (void)willDisappear {
    [_theme pause];
    _theme = nil;
    [super willDisappear];
}

- (BOOL)handleKey:(PXKey)key {
    switch (key) {
        case PXKeyLeft: case PXKeyRight: {
            NSInteger d = key == PXKeyLeft ? -1 : 1;
            if (_zone == PXShowButtons) [_buttons moveBy:d];
            else if (_zone == PXShowSeasons) {
                NSInteger t = _seasonIndex + d;
                if (t >= 0 && t < (NSInteger)_seasons.count) { _seasonIndex = t; _userMovedSeason = YES; [self updateSeasonPills]; [self loadEpisodes]; }
            } else if ([_episodes moveBy:d]) [self showEpisodeInfo];
            return YES;
        }
        case PXKeyDown:
            if (_zone == PXShowButtons && _seasons.count) _zone = PXShowSeasons;
            else if (_zone == PXShowSeasons && _episodes.items.count) _zone = PXShowEpisodes;
            [self applyZone:YES];
            return YES;
        case PXKeyUp:
            if (_zone == PXShowEpisodes) _zone = PXShowSeasons;
            else if (_zone == PXShowSeasons) _zone = PXShowButtons;
            [self applyZone:YES];
            return YES;
        case PXKeySelect:
            if (_zone == PXShowButtons) [_buttons activate];
            else if (_zone == PXShowSeasons) { if (_episodes.items.count) { _zone = PXShowEpisodes; [self applyZone:YES]; } }
            else if (_episodes.focusedItem) [self push:PXDetailScreenNew(_episodes.focusedItem)];
            return YES;
        case PXKeyPlayPause: {
            PXItem *ep = _zone == PXShowEpisodes ? _episodes.focusedItem : _onDeck;
            if (ep) [self push:PXPlayerScreenNew(ep, ep.viewOffset > 30 ? ep.viewOffset : 0)];
            return YES;
        }
        case PXKeyMenu:
            if (_zone != PXShowButtons) { _zone = PXShowButtons; [self applyZone:YES]; return YES; }
            return NO;
        default: return NO;
    }
}

@end

// Online title (watchlist, online search): the copy on one of the servers
// when there is one (playable), else the online page.
@interface PXOnlineItemScreen : PXScreen
@property (nonatomic, strong) PXItem *item;
@end

@implementation PXOnlineItemScreen
- (void)didAppear {
    [super didAppear];
    if (self.layer.sublayers.count) return;
    CALayer *spin = PXSpinner(64);
    spin.position = CGPointMake(960, 540);
    [self.layer addSublayer:spin];
    self.layer.backgroundColor = PXColorBackground();
    __weak PXOnlineItemScreen *weak = self;
    PXItem *it = self.item;
    [[PXPlex shared] findLocalForGuid:it.guid done:^(PXItem *local, NSError *err) {
        PXOnlineItemScreen *me = weak;
        if (!me || !me.host) return;
        if (local) { [[me.host stack] swapController:PXHostControllerForScreen(PXScreenForItem(local))]; return; }
        [it.server metadata:it.ratingKey done:^(NSDictionary *m, NSError *e) {
            PXOnlineItemScreen *me2 = weak;
            if (!me2 || !me2.host) return;
            PXItem *full = m ? [PXItem itemWithJSON:m] : it;
            [[me2.host stack] swapController:PXHostControllerForScreen(PXDetailScreenNew(full))];
        }];
    }];
}
@end

PXScreen *PXScreenForItem(PXItem *item) {
    if (item.server.provider) { PXOnlineItemScreen *s = [PXOnlineItemScreen new]; s.item = item; return s; }
    if (item.type == PXItemCollection)
        return PXItemListScreenNew(item.title, [NSString stringWithFormat:@"/library/collections/%@/children", item.ratingKey], item.server);
    if (item.type == PXItemPlaylist)
        return PXItemListScreenNew(item.title, [NSString stringWithFormat:@"/playlists/%@/items", item.ratingKey], item.server);
    if (item.type == PXItemClip) return PXPlayerScreenNew(item, 0);   // trailers and other extras play directly
    if (item.type == PXItemArtist)
        return PXItemListScreenNew(item.title, [NSString stringWithFormat:@"/library/metadata/%@/children", item.ratingKey], item.server);
    if (item.type == PXItemAlbum) return PXAlbumScreenNew(item);
    if (item.type == PXItemPhotoAlbum)
        return PXItemListScreenNew(item.title, [NSString stringWithFormat:@"/library/metadata/%@/children", item.ratingKey], item.server);
    if (item.type == PXItemPhoto) return PXPhotoScreenNew(@[ item ], 0);
    if (item.type == PXItemTrack) {
        [[PXMusicPlayer shared] playTracks:@[ item ] startAt:0 shuffle:NO];
        return PXNowPlayingScreenNew();
    }
    if (item.type == PXItemShow || item.type == PXItemSeason) {
        PXShowScreen *s = [PXShowScreen new];
        s.showKey = item.type == PXItemShow ? item.ratingKey : item.parentRatingKey;
        s.server = item.server;
        s.seasonKey = item.type == PXItemSeason ? item.ratingKey : nil;
        [s setup];
        return s;
    }
    return PXDetailScreenNew(item);
}

// Placeholder shown while the item type is unknown, replaced in place.
@interface PXLoadingScreen : PXScreen
@property (nonatomic, copy) NSString *ratingKey;
@property (nonatomic, strong) PXServer *server;
@end

@implementation PXLoadingScreen
- (void)didAppear {
    [super didAppear];
    CALayer *spin = PXSpinner(64);
    spin.position = CGPointMake(960, 540);
    [self.layer addSublayer:spin];
    self.layer.backgroundColor = PXColorBackground();
    __weak PXLoadingScreen *weak = self;
    [(self.server ?: [PXPlex shared].primaryServer) metadata:self.ratingKey done:^(NSDictionary *m, NSError *err) {
        PXLoadingScreen *me = weak;
        if (!me || !me.host) return;
        if (!m) { [me pop]; return; }
        PXScreen *real = PXScreenForItem([PXItem itemWithJSON:m]);
        [[me.host stack] swapController:PXHostControllerForScreen(real)];
    }];
}
@end

PXScreen *PXScreenForRatingKey(NSString *ratingKey) {
    return PXScreenForRatingKeyOnServer(ratingKey, nil);
}

PXScreen *PXScreenForRatingKeyOnServer(NSString *ratingKey, PXServer *server) {
    PXLoadingScreen *s = [PXLoadingScreen new];
    s.ratingKey = ratingKey;
    s.server = server;
    return s;
}
