// Home: ambient background following the focused title,
// a hero block (title, metadata, summary) and shelves from the server hubs.
// "Continue watching" uses 16:9 cards, other hubs use posters.

#import "PXRouter.h"
#import "PXMusicPlayer.h"
#import "PXSettings.h"
#import "PXServer.h"
#import "PXUI.h"
#import "PXShelfLayer.h"
#import "PXAmbientPlex.h"
#import "PXPlex.h"
#import "PXItem.h"
#import "PXLog.h"
#import "PXBackRow.h"

static const CGFloat kTabsY = 44, kHeroY = 150, kShelvesHeroY = 560, kShelvesTopY = 150;

@interface PXHomeScreen : PXScreen
// nil: the main home (servers chosen by the user). Else the home of one
// server (opened from the "Serveurs" tab): its hubs and libraries only.
@property (nonatomic, strong) PXServer *server;
@property (nonatomic) BOOL opensSettings;
@property (nonatomic) BOOL skipsProfilePicker;
@end

@implementation PXHomeScreen {
    PXAmbientLayer *_ambient;
    CALayer *_tabsBar;
    NSMutableArray *_tabs;          // {title, action, layer, text}
    NSInteger _tabIndex;
    BOOL _tabsFocused;
    NSInteger _shownTab;            // tab whose content is displayed
    NSMutableDictionary *_children; // tab index -> embedded PXScreen (kept for state)
    BOOL _childFocused;
    CAGradientLayer *_tabsScrim;    // keeps the tab bar readable over tab content
    CATextLayer *_clock;
    // Hero
    CALayer *_hero;
    CALayer *_heroTitle, *_heroMeta, *_heroSummary;   // drawn off the main thread
    CALayer *_heroBadges;
    PXItem *_heroItem, *_pendingHero;
    NSMutableDictionary *_fullItems;   // uniqueKey -> PXItem with summary
    // Shelves
    CALayer *_shelvesLayer;
    NSMutableArray *_shelves;
    NSInteger _shelfIndex;
    CATextLayer *_status;
    BOOL _loaded, _loading, _askedLink, _askedServers, _fetchedServers, _reloadPending, _askedProfile;
    dispatch_source_t _clockTimer;
    NSString *_tabsSignature;
    NSArray *_tabSections;           // last library list, to rebuild the tabs
    BOOL _hasPlaylists;              // video playlists on the tabs server
    BOOL _hasWatchlist;              // plex.tv watchlist not empty (main home)
}

- (instancetype)init {
    if ((self = [super init])) {
        _fullItems = [NSMutableDictionary dictionary];
        __weak PXHomeScreen *weakSelf = self;
        [[NSNotificationCenter defaultCenter] addObserverForName:PXSelectedServersDidChange object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) { if (!weakSelf.server) [weakSelf reloadAll]; }];
        // Another profile: its own servers and selection, everything reloads.
        [[NSNotificationCenter defaultCenter] addObserverForName:PXHomeUserDidChange object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) {
            PXHomeScreen *me = weakSelf;
            if (!me || me.server) return;
            me->_askedServers = NO;
            me->_tabsSignature = nil;
            [me reloadAll];
        }];
        _ambient = [[PXAmbientLayer alloc] initWithFrame:self.layer.bounds style:PXAmbientHome];
        [self.layer addSublayer:_ambient];

        [self buildHero];

        _shelvesLayer = [CALayer layer];
        _shelvesLayer.anchorPoint = CGPointZero;
        _shelvesLayer.position = CGPointMake(0, kShelvesHeroY);
        [self.layer addSublayer:_shelvesLayer];

        _tabsScrim = [CAGradientLayer layer];
        _tabsScrim.frame = CGRectMake(0, 0, 1920, 170);
        _tabsScrim.colors = @[ (__bridge id)PXColorBlack(0.92), (__bridge id)PXColorBlack(0.75), (__bridge id)PXColorBlack(0) ];
        _tabsScrim.locations = @[ @0, @0.6, @1 ];
        _tabsScrim.opacity = 0;
        [self.layer addSublayer:_tabsScrim];

        _tabsBar = [CALayer layer];
        _tabsBar.frame = CGRectMake(0, kTabsY, 1920, 60);
        [self.layer addSublayer:_tabsBar];

        _clock = PXText(PXFontMedium(32), PXColorText());
        _clock.alignmentMode = kCAAlignmentRight;
        _clock.frame = CGRectMake(1500, kTabsY + 10, 320, 44);
        [self.layer addSublayer:_clock];

        _status = PXText(PXFont(34), PXColorTextDim());
        _status.alignmentMode = kCAAlignmentCenter;
        _status.wrapped = YES;
        _status.frame = CGRectMake(260, 600, 1400, 160);
        [self.layer addSublayer:_status];

        _shelves = [NSMutableArray array];
        _tabs = [NSMutableArray array];
        [self buildTabs:@[]];
        [self startClock];
    }
    return self;
}

- (void)startClock {
    __weak PXHomeScreen *weak = self;
    _clockTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_clockTimer, DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(_clockTimer, ^{ PXHomeScreen *me = weak; if (me) PXSetText(me->_clock, PXWallClock([NSDate date])); });
    dispatch_resume(_clockTimer);
}

#pragma mark - Hero

- (void)buildHero {
    _hero = [CALayer layer];
    _hero.frame = CGRectMake(96, kHeroY, 1150, 400);
    [self.layer addSublayer:_hero];
    _heroTitle = [CALayer layer];
    _heroTitle.frame = CGRectMake(0, 40, 1150, 92);
    _heroMeta = [CALayer layer];
    _heroMeta.frame = CGRectMake(0, 142, 1150, 38);
    _heroBadges = [CALayer layer];
    _heroBadges.frame = CGRectMake(0, 190, 1150, 40);
    _heroSummary = [CALayer layer];
    _heroSummary.frame = CGRectMake(0, 244, 1000, 124);
    for (CALayer *l in @[ _heroTitle, _heroMeta, _heroSummary ]) {
        l.contentsGravity = kCAGravityTopLeft;
        l.actions = @{ @"contents": [NSNull null], @"bounds": [NSNull null], @"position": [NSNull null] };
    }
    for (CALayer *l in @[ _heroTitle, _heroMeta, _heroBadges, _heroSummary ]) [_hero addSublayer:l];
}

// Outlined pill ("4K", "HDR", "TrueHD 7.1").
static CALayer *badgePill(NSString *text, CGFloat x) {
    UIFont *f = PXFontSemi(20);
    CGFloat w = PXTextWidth(text, f) + 22;
    CALayer *b = [CALayer layer];
    b.frame = CGRectMake(x, 2, w, 34);
    b.cornerRadius = 7;
    b.borderWidth = 2;
    b.borderColor = PXColorWhite(0.55);
    CATextLayer *t = PXText(f, PXColorWhite(0.9));
    t.alignmentMode = kCAAlignmentCenter;
    t.string = text;
    t.frame = CGRectMake(0, (34 - f.lineHeight) / 2 - 1, w, f.lineHeight + 2);
    [b addSublayer:t];
    return b;
}

// The hero (big text, badges, backdrop) is rebuilt only once the focus
// rests: rebuilding it on every move cost ~300 ms of main thread per step.
- (void)showHero:(PXItem *)it {
    if (!it || [it.uniqueKey isEqual:_heroItem.uniqueKey]) return;
    if (!_heroItem) { [self applyHero:it]; return; }   // first display: immediate
    _pendingHero = it;
    __weak PXHomeScreen *weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        PXHomeScreen *me = weak;
        if (me && me->_pendingHero == it) { me->_pendingHero = nil; [me applyHero:it]; }
    });
}

- (void)applyHero:(PXItem *)it {
    if (!it || [it.uniqueKey isEqual:_heroItem.uniqueKey]) return;
#ifdef DEBUG
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    dispatch_async(dispatch_get_main_queue(), ^{
        [CATransaction flush];
        PXLog(@"perf: hero %.0f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000);
    });
#endif
    _heroItem = it;
    PXItem *full = _fullItems[it.uniqueKey];
    PXItem *show = full ?: it;
#ifdef DEBUG
    CFAbsoluteTime ta = CFAbsoluteTimeGetCurrent();
#endif
    [_ambient showItem:show];
#ifdef DEBUG
    [CATransaction flush];
    CFAbsoluteTime tb = CFAbsoluteTimeGetCurrent();
#endif

    PXNoAnim(^{
        NSString *heroTitle = show.type == PXItemEpisode ? (show.grandparentTitle ?: show.title) : show.title;
        PXDrawTextAsync(self->_heroTitle, heroTitle, PXFontHeavy(74), PXColorText(), 1150, 1, 46);
        NSMutableArray *meta = [NSMutableArray array];
        if (show.type == PXItemEpisode) [meta addObject:[NSString stringWithFormat:@"%@ · %@", show.episodeCode, show.title]];
        if (show.year) [meta addObject:[@(show.year) stringValue]];
        if (show.duration > 0 && show.type != PXItemShow) [meta addObject:PXDurationText(show.duration)];
        if (show.type == PXItemShow && show.childCount) [meta addObject:show.shelfSubtitle];
        if (show.contentRating.length) [meta addObject:show.contentRating];
        if (show.genres.count) [meta addObject:[[show.genres subarrayWithRange:NSMakeRange(0, MIN(2, show.genres.count))] componentsJoinedByString:@", "]];
        PXDrawTextAsync(self->_heroMeta, [meta componentsJoinedByString:@"   ·   "], PXFontMedium(28), PXColorTextDim(), 1150, 1, 0);
        for (CALayer *l in [self->_heroBadges.sublayers copy]) [l removeFromSuperlayer];
        CGFloat x = 0;
        for (NSString *b in show.techBadges) {
            CALayer *pill = PXPillLayer(b, CGPointMake(x, 0));
            [self->_heroBadges addSublayer:pill];
            x += pill.bounds.size.width + 10;
        }
        if (show.remainingText)
            [self->_heroBadges addSublayer:PXCachedLabel(show.remainingText, PXFontSemi(22), [UIColor colorWithCGColor:PXColorAccent()], CGPointMake(x + 6, 6))];
        PXDrawTextAsync(self->_heroSummary, show.summary, PXFont(28), PXColorWhite(0.85), 1000, 3, 0);
    });
#ifdef DEBUG
    [CATransaction flush];
    PXLog(@"perf: hero ambient %.0f ms, texts+badges %.0f ms", (tb - ta) * 1000, (CFAbsoluteTimeGetCurrent() - tb) * 1000);
#endif
    // Hubs sometimes omit summary/genres: fetch the full item once.
    if (!full && (!it.summary.length || !it.media)) {
        NSString *rk = it.ratingKey, *uk = it.uniqueKey;
        __weak PXHomeScreen *weak = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            PXHomeScreen *me = weak;
            if (!me || ![me->_heroItem.uniqueKey isEqual:uk]) return;
            [it.server metadata:rk done:^(NSDictionary *m, NSError *err) {
                PXHomeScreen *me2 = weak;
                if (!me2 || !m) return;
                me2->_fullItems[uk] = [PXItem itemWithJSON:m];
                if ([me2->_heroItem.uniqueKey isEqual:uk]) { me2->_heroItem = nil; [me2 applyHero:it]; }
            }];
        });
    }
}

#pragma mark - Tabs

- (void)buildTabsIfNeeded:(NSArray *)sections {
    _tabSections = sections;
    NSString *sig = [[[sections valueForKey:@"title"] componentsJoinedByString:@"|"] stringByAppendingFormat:@"|%d|%d|%d", [self showsServersTab], _hasPlaylists, _hasWatchlist];
    if ([sig isEqual:_tabsSignature]) return;
    _tabsSignature = sig;
    [self buildTabs:sections];
}

- (BOOL)showsServersTab { return !self.server && [PXPlex shared].servers.count > 1; }

- (void)buildTabs:(NSArray *)sections {
    for (NSDictionary *n in _tabs) [n[@"layer"] removeFromSuperlayer];
    __weak PXHomeScreen *weak = self;
    // Each tab builds its content once (kept while the home lives); Accueil
    // is the home itself (no factory).
    (void)weak;
    NSMutableArray *defs = [NSMutableArray arrayWithObject:@{ @"title": self.server ? self.server.name : PXL(@"Accueil") }];
    for (NSDictionary *s in sections)
        [defs addObject:@{ @"title": s[@"title"] ?: @"?", @"make": ^PXScreen *{ return PXLibraryScreenNew(s, YES); } }];
    if (_hasWatchlist && !self.server) {
        [defs addObject:@{ @"title": PXL(@"Ma liste"), @"make": ^PXScreen *{
            return PXItemListScreenNewEmbedded(PXL(@"Ma liste"), @"/library/sections/watchlist/all?includeCollections=1&includeExternalMedia=1",
                                               [PXPlex shared].onlineProvider);
        } }];
    }
    if (_hasPlaylists) {
        PXServer *sv = self.server ?: [PXPlex shared].primaryServer;
        [defs addObject:@{ @"title": PXL(@"Listes de lecture"), @"make": ^PXScreen *{
            return PXItemListScreenNewEmbedded(PXL(@"Listes de lecture"), @"/playlists?playlistType=video", sv);
        } }];
    }
    if ([self showsServersTab]) [defs addObject:@{ @"title": PXL(@"Serveurs"), @"make": ^PXScreen *{ return PXServerListScreenNew(YES); } }];
    if (!self.server) {
        [defs addObject:@{ @"title": PXL(@"Découvrir"), @"make": ^PXScreen *{ return PXDiscoverScreenNew(); } }];
        [defs addObject:@{ @"title": PXL(@"Rechercher"), @"make": ^PXScreen *{ return PXSearchScreenNew(YES); } }];
        [defs addObject:@{ @"title": PXL(@"Réglages"), @"make": ^PXScreen *{ return PXSettingsScreenNew(YES); } }];
    }
    for (PXScreen *c in _children.allValues) { [c willDisappear]; [c didPop]; [c.layer removeFromSuperlayer]; }
    _children = [NSMutableDictionary dictionary];
    _shownTab = 0;
    _tabIndex = 0;
    if (_childFocused) { _childFocused = NO; _tabsFocused = YES; }
    // Back on Accueil: undo what showTab: did for the previous tab.
    PXNoAnim(^{
        self->_shelvesLayer.opacity = 1;
        self->_ambient.opacity = 1;
        self->_tabsScrim.opacity = 0;
        self->_hero.opacity = self->_shelfIndex == 0 ? 1 : 0;
    });
    NSMutableArray *built = [NSMutableArray array];
    CGFloat x = 84;
    // Many libraries / tabs: tighter pills, then a smaller font, so the bar
    // stays clear of the clock (right ~300 px).
    UIFont *f = PXFontSemi(28);
    CGFloat pad = 48, room = 1920 - 84 - 300, total = 0;
    for (NSDictionary *d in defs) total += PXTextWidth(d[@"title"], f) + pad + 6;
    if (total > room) { pad = 28; total = 0; for (NSDictionary *d in defs) total += PXTextWidth(d[@"title"], f) + pad + 6; }
    if (total > room) { f = PXFontSemi(24); pad = 24; }
    for (NSDictionary *d in defs) {
        CGFloat w = PXTextWidth(d[@"title"], f) + pad;
        CALayer *pill = [CALayer layer];
        pill.frame = CGRectMake(x, 0, w, 56);
        pill.cornerRadius = 28;
        CATextLayer *t = PXText(f, PXColorTextDim());
        t.alignmentMode = kCAAlignmentCenter;
        t.string = d[@"title"];
        t.frame = CGRectMake(0, (56 - f.lineHeight) / 2 - 1, w, f.lineHeight + 2);
        [pill addSublayer:t];
        PXNoAnim(^{ [self->_tabsBar addSublayer:pill]; });
        NSMutableDictionary *m = [d mutableCopy];
        m[@"layer"] = pill;
        m[@"text"] = t;
        [built addObject:m];
        x += w + 6;
    }
    _tabs = built;
    _tabIndex = MIN(_tabIndex, (NSInteger)_tabs.count - 1);
    [self updateTabs];
    if (self.opensSettings && !self.server) {
        // Rebuilt after a language change: back on Réglages (last tab).
        self.opensSettings = NO;
        _tabIndex = _tabs.count - 1;
        [self showTab:_tabIndex];
        [self focusChild:YES];
    }
}

- (void)updateTabs {
    PXAnim(0.2, ^{
        for (NSInteger i = 0; i < (NSInteger)self->_tabs.count; i++) {
            CALayer *pill = self->_tabs[i][@"layer"];
            CATextLayer *t = self->_tabs[i][@"text"];
            BOOL focused = self->_tabsFocused && i == self->_tabIndex;
            BOOL current = i == self->_shownTab;
            pill.backgroundColor = focused ? PXColorText() : (current && !self->_tabsFocused ? PXColorPanel() : [UIColor clearColor].CGColor);
            t.foregroundColor = focused ? PXColorBlack(0.92) : (current ? PXColorText() : PXColorTextDim());
            CGFloat k = focused ? 1.08 : 1.0;
            pill.transform = CATransform3DMakeScale(k, k, 1);
        }
    });
}

#pragma mark - Tab content

// Shows the content of a tab (called when the focus rests on it).
- (void)showTab:(NSInteger)index {
    if (index == _shownTab || index >= (NSInteger)_tabs.count) return;
    PXScreen *old = _children[@(_shownTab)];
    if (old) {
        old.hasFocus = NO;
        [old willDisappear];
        PXNoAnim(^{ [old.layer removeFromSuperlayer]; });
    }
    _shownTab = index;
    BOOL home = index == 0;
    PXAnim(0.25, ^{
        self->_hero.opacity = home && self->_shelfIndex == 0 ? 1 : 0;
        self->_shelvesLayer.opacity = home ? 1 : 0;
        self->_ambient.opacity = home ? 1 : 0;
        self->_tabsScrim.opacity = home ? 0 : 1;
    });
    if (!home) {
        PXScreen *child = _children[@(index)];
        if (!child) {
            PXScreen *(^make)(void) = _tabs[index][@"make"];
            child = make ? make() : nil;
            if (child) _children[@(index)] = child;
        }
        if (child) {
            child.host = self.host;           // pushes from the tab go on our stack
            child.hasFocus = NO;
            CALayer *l = child.layer;
            PXNoAnim(^{
                // Our root layer is already flipped (top-left origin): a second
                // flip would turn the embedded screen upside down.
                l.geometryFlipped = NO;
                l.anchorPoint = CGPointZero;
                l.position = CGPointZero;
                [self.layer insertSublayer:l below:self->_tabsScrim];
                l.opacity = 0;
            });
            PXAnim(0.25, ^{ l.opacity = 1; });
            [child didAppear];
        }
    }
    [self updateTabs];
}

- (void)scheduleTab:(NSInteger)index {
    __weak PXHomeScreen *weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 280 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        PXHomeScreen *me = weak;
        // Only if the focus is still resting on that tab.
        if (me && me->_tabsFocused && me->_tabIndex == index) [me showTab:index];
    });
}

- (void)focusChild:(BOOL)focus {
    PXScreen *child = _children[@(_shownTab)];
    _childFocused = focus && child;
    _tabsFocused = !_childFocused;
    child.hasFocus = _childFocused;
    [self updateTabs];
}

#pragma mark - Data

- (void)willDisappear {
    [super willDisappear];
    [_children[@(_shownTab)] willDisappear];
}

// beigelist pushes its category list before our root controller: drop it,
// so Menu from the app goes straight back to the main menu.
- (void)removeLoaderList {
    id stack = [self.host stack];
    NSArray *cs = [stack controllers];
    NSUInteger me = [cs indexOfObject:self.host];
    if (me == NSNotFound || me == 0) return;
    id below = cs[me - 1];
    if ([NSStringFromClass([below class]) hasPrefix:@"BLAppLegacy"]) {
        PXLog(@"home: removing %@ from the stack", NSStringFromClass([below class]));
        [stack removeController:below];
    }
}

- (void)didAppear {
    [super didAppear];
    [self removeLoaderList];
    if (_shownTab != 0) { [_children[@(_shownTab)] didAppear]; return; }
    PXSetText(_clock, PXWallClock([NSDate date]));
    PXPlex *plex = [PXPlex shared];
    if (!plex.isLinked) {
        PXSetText(_status, PXL(@"Associez cette Apple TV à votre compte Plex."));
        if (!_askedLink) {
            _askedLink = YES;
            __weak PXHomeScreen *weak = self;
            [self push:PXLinkScreenNew(^{ [weak reload]; })];
        }
        return;
    }
    if ([self askProfileIfNeeded]) return;
    if ([self askServersIfNeeded]) return;
    [self reload];
    // Fresh server list from plex.tv once per session (new shares, presence):
    // may bring the server choice or the "Serveurs" tab.
    if (!self.server && !_fetchedServers) {
        _fetchedServers = YES;
        __weak PXHomeScreen *weak = self;
        [plex fetchServers:^(NSArray *servers, NSError *err) {
            PXHomeScreen *me = weak;
            if (!me || !servers.count) return;
            if (![me askServersIfNeeded]) [me reload];
        }];
    }
}

// Plex Home: profile picker once per app opening when Réglages ask for it;
// the list of profiles is refreshed in the background for the next time.
- (BOOL)askProfileIfNeeded {
    if (self.server || _askedProfile || self.skipsProfilePicker || !self.host) return NO;
    _askedProfile = YES;
    PXPlex *plex = [PXPlex shared];
    [plex fetchHomeUsers:nil];
    BOOL ask = [PXSettingGet(@"profileAtLaunch") isEqual:@"ask"];
    if (!ask || plex.homeUsers.count < 2) return NO;
    [self push:PXProfilesScreenNew(YES, nil)];   // its pop brings didAppear back here
    return YES;
}

// First launch with several servers: let the user choose what the home gathers.
- (BOOL)askServersIfNeeded {
    PXPlex *plex = [PXPlex shared];
    if (self.server || plex.hasServerSelection || plex.servers.count < 2 || _askedServers || !self.host) return NO;
    _askedServers = YES;
    __weak PXHomeScreen *weak = self;
    [self push:PXServersScreenNew(^{ [weak reloadAll]; })];
    return YES;
}

// Server selection changed: rebuild rows from scratch.
- (void)reloadAll {
    _loaded = NO;
    for (PXShelfLayer *sh in _shelves) [sh removeFromSuperlayer];
    [_shelves removeAllObjects];
    [self reload];
}

- (void)reload {
    if (_loading) { _reloadPending = YES; return; }
    _loading = YES;
    if (!_loaded) PXSetText(_status, @"");
    [self loadRetrying:YES];
}

- (void)loadRetrying:(BOOL)retry {
    PXPlex *plex = [PXPlex shared];
    PXServer *tabsServer = self.server ?: plex.primaryServer;
    __weak PXHomeScreen *weak = self;
    if (!tabsServer) {
        // Linked but no server known yet (plex.tv not answered): ask plex.tv.
        if (!retry) { _loading = NO; PXSetText(_status, PXL(@"Aucun serveur Plex sur ce compte.")); return; }
        PXSetText(_status, PXL(@"Recherche des serveurs…"));
        [plex reconnect:^(id conn, NSError *e) { [weak loadRetrying:NO]; }];
        return;
    }
    // Tabs: libraries of this server (main home: the primary server).
    [tabsServer get:@"/library/sections" done:^(NSDictionary *mc, NSError *err) {
        PXHomeScreen *me = weak;
        if (!me) return;
        if (err && retry) {
            PXSetText(me->_status, PXLF(@"Connexion à %@…", tabsServer.name));
            void (^again)(id, NSError *) = ^(id conn, NSError *e) { [weak loadRetrying:NO]; };
            if (me.server) [tabsServer reconnect:again]; else [plex reconnect:again];
            return;
        }
        if (err) {
            me->_loading = NO;
            PXSetText(me->_status, PXLF(@"%@ injoignable : %@", tabsServer.name, err.localizedDescription));
            return;
        }
        [me buildTabsIfNeeded:[me videoSections:mc]];
        // Watchlist (online): one more tab when it is not empty.
        if (!me.server) [[PXPlex shared] fetchWatchlist:^(NSArray *items, NSError *e) {
            PXHomeScreen *me2 = weak;
            BOOL has = items.count > 0;
            if (!me2 || e || has == me2->_hasWatchlist) return;
            me2->_hasWatchlist = has;
            [me2 buildTabsIfNeeded:me2->_tabSections];
        }];
        // Video playlists: one more tab when the server has some.
        [tabsServer get:@"/playlists?playlistType=video&X-Plex-Container-Size=1" done:^(NSDictionary *pl, NSError *e) {
            PXHomeScreen *me2 = weak;
            BOOL has = [pl[@"totalSize"] integerValue] > 0 || [pl[@"Metadata"] count] > 0;
            if (!me2 || e || has == me2->_hasPlaylists) return;
            me2->_hasPlaylists = has;
            [me2 buildTabsIfNeeded:me2->_tabSections];
        }];
        [me loadHubs];
    }];
}

- (NSArray *)videoSections:(NSDictionary *)mc {
    NSMutableArray *sections = [NSMutableArray array];
    for (NSDictionary *d in mc[@"Directory"])
        if ([@[ @"movie", @"show", @"artist", @"photo" ] containsObject:d[@"type"] ?: @""]) [sections addObject:d];
    return sections;
}

// Hubs of every server shown on this home, fetched in parallel; slow or
// offline servers are dropped after a few seconds.
- (void)loadHubs {
    PXPlex *plex = [PXPlex shared];
    NSArray *servers = self.server ? @[ self.server ] : plex.selectedServers;
    NSMutableDictionary *results = [NSMutableDictionary dictionary];   // identifier -> hubs
    __block NSInteger pending = servers.count;
    __block BOOL done = NO;
    __weak PXHomeScreen *weak = self;
    void (^finish)(void) = ^{
        if (done) return;
        done = YES;
        PXHomeScreen *me = weak;
        if (!me) return;
        me->_loading = NO;
        if (me->_reloadPending) {
            me->_reloadPending = NO;
            dispatch_async(dispatch_get_main_queue(), ^{ [weak reload]; });
        }
        NSMutableArray *ordered = [NSMutableArray array];
        for (PXServer *sv in servers) if (results[sv.identifier]) [ordered addObject:@{ @"server": sv, @"hubs": results[sv.identifier] }];
        [me showHubs:[me mergeHubs:ordered] error:nil];
    };
    if (!pending) { finish(); return; }
    for (PXServer *sv in servers) {
        [sv get:@"/library/sections" done:^(NSDictionary *mc, NSError *err) {
            PXHomeScreen *me = weak;
            NSArray *sections = me ? [me videoSections:mc] : @[];
            if (err || !sections.count) { if (err) PXLog(@"home: %@: %@", sv.name, err.localizedDescription); if (--pending == 0) finish(); return; }
            // Same endpoint as the official apps: one "recently added" hub per
            // library (the global /hubs merges every movie-type library).
            NSString *ids = [[sections valueForKey:@"key"] componentsJoinedByString:@","];
            NSString *path = [NSString stringWithFormat:@"/hubs/promoted?contentDirectoryID=%@&pinnedContentDirectoryID=%@&includeMeta=1&count=20", ids, ids];
            [sv get:path done:^(NSDictionary *hubs, NSError *e2) {
                if ([hubs[@"Hub"] isKindOfClass:[NSArray class]]) results[sv.identifier] = hubs[@"Hub"];
                if (--pending == 0) finish();
            }];
        }];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), finish);
}

// One "Continuer à regarder" and one "À l'affiche" for all servers (most
// recent first); the other hubs per server, named after it when several.
- (NSArray *)mergeHubs:(NSArray *)perServer {
    BOOL several = perServer.count > 1;
    NSMutableArray *cont = [NSMutableArray array], *deck = [NSMutableArray array], *others = [NSMutableArray array];
    NSString *contTitle = nil, *deckTitle = nil;
    for (NSDictionary *entry in perServer) {
        PXServer *sv = entry[@"server"];
        for (NSDictionary *h in entry[@"hubs"]) {
            if (![h isKindOfClass:[NSDictionary class]]) continue;
            NSString *hid = h[@"hubIdentifier"] ?: h[@"title"] ?: @"";
            NSArray *items = [h[@"Metadata"] isKindOfClass:[NSArray class]] ? h[@"Metadata"] : @[];
            if ([hid containsString:@"continue"]) { [cont addObjectsFromArray:items]; contTitle = contTitle ?: h[@"title"]; continue; }
            if ([hid containsString:@"ondeck"]) { [deck addObjectsFromArray:items]; deckTitle = deckTitle ?: h[@"title"]; continue; }
            NSMutableDictionary *m = [h mutableCopy];
            m[@"hubIdentifier"] = [NSString stringWithFormat:@"%@@%@", hid, sv.identifier];
            if (several) m[@"title"] = [NSString stringWithFormat:@"%@ · %@", h[@"title"] ?: @"", sv.name];
            [others addObject:m];
        }
    }
    NSComparator recent = ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double ta = [a[@"lastViewedAt"] doubleValue] ?: [a[@"addedAt"] doubleValue], tb = [b[@"lastViewedAt"] doubleValue] ?: [b[@"addedAt"] doubleValue];
        return ta > tb ? NSOrderedAscending : (ta < tb ? NSOrderedDescending : NSOrderedSame);
    };
    NSMutableArray *out = [NSMutableArray array];
    if (cont.count) [out addObject:@{ @"hubIdentifier": @"home.continue", @"title": contTitle ?: PXL(@"Continuer à regarder"), @"type": @"mixed",
                                      @"Metadata": [cont sortedArrayUsingComparator:recent] }];
    if (deck.count) [out addObject:@{ @"hubIdentifier": @"home.ondeck", @"title": deckTitle ?: PXL(@"À l'affiche"), @"type": @"mixed",
                                      @"Metadata": [deck sortedArrayUsingComparator:recent] }];
    [out addObjectsFromArray:others];
    return out;
}

- (void)showHubs:(NSArray *)hubs error:(NSError *)err {
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableSet *inProgress = [NSMutableSet set];   // shown in "Continuer à regarder"
    for (NSDictionary *h in hubs) {
        if (![h isKindOfClass:[NSDictionary class]]) continue;
        if (![@[ @"movie", @"show", @"episode", @"season", @"mixed", @"album", @"artist", @"track" ] containsObject:h[@"type"] ?: @""]) continue;
        BOOL music = [@[ @"album", @"artist", @"track" ] containsObject:h[@"type"]];
        NSString *hid = h[@"hubIdentifier"] ?: h[@"title"] ?: @"";
        BOOL cont = [hid containsString:@"continue"];
        BOOL deck = [hid containsString:@"ondeck"];
        NSMutableArray *videos = [NSMutableArray array];
        for (PXItem *it in [PXItem itemsWithJSON:h[@"Metadata"]]) {
            if (it.type == PXItemOther) continue;
            // "À l'affiche" repeats what "Continuer à regarder" already shows.
            if (deck && [inProgress containsObject:it.uniqueKey]) continue;
            if (cont) [inProgress addObject:it.uniqueKey];
            [videos addObject:it];
        }
        if (!videos.count) continue;
        BOOL cards = !music && (cont || deck || PXItemsPreferLandscape(videos));
        [rows addObject:@{ @"title": h[@"title"] ?: @"", @"id": hid, @"items": videos, @"cards": @(cards), @"square": @(music) }];
    }
    PXLog(@"home: %lu shelves", (unsigned long)rows.count);
    [_fullItems removeAllObjects];   // fresh hubs: refetch full items (summary, watch state)
    PXSetText(_status, rows.count ? @"" : (err ? err.localizedDescription : PXL(@"Rien à afficher pour le moment.")));
    _loaded = rows.count > 0;

    NSString *focusedShelf = _shelfIndex < (NSInteger)_shelves.count ? [_shelves[_shelfIndex] name] : nil;
    PXItem *focusedItem = _shelfIndex < (NSInteger)_shelves.count ? [_shelves[_shelfIndex] focusedItem] : nil;
    NSMutableDictionary *old = [NSMutableDictionary dictionary];
    for (PXShelfLayer *s in _shelves) old[s.name] = s;
    NSMutableArray *shelves = [NSMutableArray array];
    CGFloat y = 0;
    for (NSDictionary *r in rows) {
        PXShelfLayer *s = old[r[@"id"]];
        if (!s) {
            BOOL cards = [r[@"cards"] boolValue], square = [r[@"square"] boolValue];
            s = [[PXShelfLayer alloc] initWithTitle:r[@"title"] width:1920
                                          imageSize:cards ? CGSizeMake(400, 225) : (square ? CGSizeMake(240, 240) : CGSizeMake(200, 300))
                                            artwork:cards ? PXArtworkThumb : PXArtworkPoster];
            s.leftMargin = 96;
            s.name = r[@"id"];
        }
        [old removeObjectForKey:r[@"id"]];
        s.title = r[@"title"];
        s.items = r[@"items"];
        PXNoAnim(^{ s.position = CGPointMake(0, y); [self->_shelvesLayer addSublayer:s]; });
        y += s.height - 10;
        [shelves addObject:s];
    }
    for (PXShelfLayer *s in old.allValues) [s removeFromSuperlayer];
    _shelves = shelves;

    NSInteger idx = 0;
    for (NSInteger i = 0; i < (NSInteger)_shelves.count; i++) if ([[_shelves[i] name] isEqual:focusedShelf]) idx = i;
    _shelfIndex = MIN(idx, MAX(0, (NSInteger)_shelves.count - 1));
    if (focusedItem && _shelfIndex < (NSInteger)_shelves.count) {
        PXShelfLayer *s = _shelves[_shelfIndex];
        NSUInteger i = [s.items indexOfObjectPassingTest:^BOOL(PXItem *it, NSUInteger n, BOOL *stop) { return [it.uniqueKey isEqual:focusedItem.uniqueKey]; }];
        if (i != NSNotFound) [s setFocusIndex:i animated:NO];
    }
    if (!_shelves.count) _tabsFocused = YES;
    _heroItem = nil;
    [self updateFocus:NO];
}

#pragma mark - Focus

- (void)updateFocus:(BOOL)animated {
    for (NSInteger i = 0; i < (NSInteger)_shelves.count; i++)
        [_shelves[i] setActive:!_tabsFocused && !_childFocused && i == _shelfIndex];
    [self updateTabs];
    if (_shelfIndex >= (NSInteger)_shelves.count) return;
    // First row: hero visible above it. Lower rows: content slides up over the hero.
    BOOL heroMode = _shelfIndex == 0;
    CGFloat y = (heroMode ? kShelvesHeroY : kShelvesTopY) - [_shelves[_shelfIndex] position].y;
    void (^move)(void) = ^{
        self->_shelvesLayer.position = CGPointMake(0, y);
        self->_hero.opacity = heroMode && self->_shownTab == 0 ? 1 : 0;
        // Rows scrolled above the focused one fade out under the tabs.
        for (NSInteger i = 0; i < (NSInteger)self->_shelves.count; i++)
            [self->_shelves[i] setOpacity:i < self->_shelfIndex ? 0 : 1];
    };
    if (animated) PXAnim(0.35, move); else PXNoAnim(move);
    [_ambient setArtOpacity:heroMode ? 0.55 : 0.3];
    [self showHero:[_shelves[_shelfIndex] focusedItem]];
}

- (BOOL)handleKey:(PXKey)key {
    if (_childFocused) {
        PXScreen *child = _children[@(_shownTab)];
        if ([child handleKey:key]) return YES;
        // The child is at its top edge (Up) or has nothing to close (Menu).
        if (key == PXKeyUp || key == PXKeyMenu) { [self focusChild:NO]; return YES; }
        return NO;
    }
    if (_tabsFocused) {
        switch (key) {
            case PXKeyLeft: case PXKeyRight: {
                NSInteger t = _tabIndex + (key == PXKeyLeft ? -1 : 1);
                if (t >= 0 && t < (NSInteger)_tabs.count) { _tabIndex = t; [self updateTabs]; [self scheduleTab:t]; }
                return YES;
            }
            case PXKeyDown: case PXKeySelect:
                [self showTab:_tabIndex];    // no wait when going down quickly
                if (_shownTab == 0) { if (_shelves.count) { _tabsFocused = NO; [self updateFocus:YES]; } }
                else [self focusChild:YES];
                return YES;
            case PXKeyMenu:
                // Like tvOS: Menu on another tab comes back to Accueil first.
                if (_shownTab != 0) { _tabIndex = 0; [self showTab:0]; return YES; }
                return NO;
            default: return NO;
        }
    }
    PXShelfLayer *shelf = _shelfIndex < (NSInteger)_shelves.count ? _shelves[_shelfIndex] : nil;
    switch (key) {
        case PXKeyLeft: case PXKeyRight:
            if ([shelf moveBy:key == PXKeyLeft ? -1 : 1]) [self showHero:shelf.focusedItem];
            return YES;
        case PXKeyUp:
            if (_shelfIndex > 0) _shelfIndex--; else _tabsFocused = YES;
            [self updateFocus:YES];
            return YES;
        case PXKeyDown:
            if (_shelfIndex < (NSInteger)_shelves.count - 1) { _shelfIndex++; [self updateFocus:YES]; }
            return YES;
        case PXKeySelect: {
            PXItem *it = shelf.focusedItem;
            if (it) [self push:PXScreenForItem(it)];
            return YES;
        }
        case PXKeyPlayPause: {
            PXItem *it = shelf.focusedItem;
            if (it && (it.type == PXItemMovie || it.type == PXItemEpisode)) [self push:PXPlayerScreenNew(it, it.viewOffset)];
            return YES;
        }
        case PXKeyMenu:
            if (!_tabsFocused) { _tabsFocused = YES; _tabIndex = 0; _shelfIndex = 0; [self updateFocus:YES]; return YES; }
            return NO;
        default: return NO;
    }
}

- (void)didPop {
    // The main home leaves the stack when the app is left: so does the music.
    if (!self.server) [[PXMusicPlayer shared] stop];
    for (PXScreen *c in _children.allValues) [c didPop];
    if (_clockTimer) dispatch_source_cancel(_clockTimer);
    _clockTimer = nil;
    [super didPop];
}

@end

PXScreen *PXHomeScreenNew(void) { return [PXHomeScreen new]; }

PXScreen *PXHomeScreenOnSettings(void) {
    PXHomeScreen *h = [PXHomeScreen new];
    h.opensSettings = YES;
    h.skipsProfilePicker = YES;   // same session: no profile picker again
    return h;
}

PXScreen *PXHomeScreenForServer(PXServer *server) {
    PXHomeScreen *s = [PXHomeScreen new];
    s.server = server;
    return s;
}
