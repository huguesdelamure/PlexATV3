// Home: ambient background following the focused title,
// a hero block (title, metadata, summary) and shelves from the server hubs.
// "Continue watching" uses 16:9 cards, other hubs use posters.

#import "PXRouter.h"
#import "PXMusicPlayer.h"
#import "PXSettings.h"
#import "PXOverlay.h"
#import "PXListLayer.h"
#import "PXServer.h"
#import "PXUI.h"
#import "PXShelfLayer.h"
#import "PXAmbientPlex.h"
#import "PXPlex.h"
#import "PXItem.h"
#import "PXLog.h"
#import "PXBackRow.h"
#import "PXPillBar.h"

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
    PXPillBar *_tabsBar;
    NSArray *_tabs;                 // {id, title, make}
    NSInteger _tabIndex;
    BOOL _tabsFocused;
    NSInteger _shownTab;            // tab whose content is displayed
    NSMutableDictionary *_children; // tab id -> embedded PXScreen (kept for state)
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
    PXOverlay *_overlay;             // long-press menu
    NSDictionary *_historyHub;       // "Regardés récemment" (watch history of the primary server)
    BOOL _hasPlaylists;              // video playlists on the tabs server
    BOOL _hasWatchlist;              // plex.tv watchlist not empty (main home)
    id _serversObserver, _userObserver;
}

- (instancetype)init {
    if ((self = [super init])) {
        _fullItems = [NSMutableDictionary dictionary];
        __weak PXHomeScreen *weakSelf = self;
        _serversObserver = [[NSNotificationCenter defaultCenter] addObserverForName:PXSelectedServersDidChange object:nil queue:[NSOperationQueue mainQueue]
                                                                         usingBlock:^(NSNotification *n) { if (!weakSelf.server) [weakSelf reloadAll]; }];
        // Another profile: its own servers and selection, everything reloads
        // (tab contents too: same tabs, other profile's data).
        _userObserver = [[NSNotificationCenter defaultCenter] addObserverForName:PXHomeUserDidChange object:nil queue:[NSOperationQueue mainQueue]
                                                                      usingBlock:^(NSNotification *n) {
            PXHomeScreen *me = weakSelf;
            if (!me || me.server) return;
            me->_askedServers = NO;
            me->_tabsSignature = nil;
            [me dropChildren];
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

        _tabsBar = [[PXPillBar alloc] initWithHeight:56];
        _tabsBar.frame = CGRectMake(84, kTabsY, 1920 - 84, 60);
        _tabsBar.gap = 6;
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
        _tabs = @[];
        [self buildTabs:@[]];
        [self startClock];
    }
    return self;
}

- (void)startClock {
    __weak PXHomeScreen *weak = self;
    _clockTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_clockTimer, DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC, NSEC_PER_SEC);
    __block NSInteger ticks = 0;
    dispatch_source_set_event_handler(_clockTimer, ^{
        PXHomeScreen *me = weak;
        if (!me) return;
        PXSetText(me->_clock, PXWallClock([NSDate date]));
        // Every 2 min while the home is on screen: what was watched on other
        // clients (continue watching, on deck) shows up without leaving it.
        if (++ticks % 12 == 0 && me->_shownTab == 0 && [me isOnTop] && me->_loaded) [me reload];
    });
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

// The hero (big text, badges, backdrop) is rebuilt only once the focus
// rests: rebuilding it on every move cost ~300 ms of main thread per step.
- (void)showHero:(PXItem *)it {
    if (!it) return;
    // Back on the item already shown: a pending hero must not land after it.
    if ([it.uniqueKey isEqual:_heroItem.uniqueKey]) { _pendingHero = nil; return; }
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

// Back on Accueil without animation: undo what showTab: did for another tab.
- (void)restoreHomeLayers {
    PXNoAnim(^{
        self->_shelvesLayer.opacity = 1;
        self->_ambient.opacity = 1;
        self->_tabsScrim.opacity = 0;
        self->_hero.opacity = self->_shelfIndex == 0 ? 1 : 0;
    });
}

// Profile change: the tab contents belong to the previous profile.
- (void)dropChildren {
    for (PXScreen *c in _children.allValues) { [c willDisappear]; [c didPop]; PXNoAnim(^{ [c.layer removeFromSuperlayer]; }); }
    _children = [NSMutableDictionary dictionary];
    if (_shownTab != 0) {
        _shownTab = 0;
        [self restoreHomeLayers];
    }
    _tabIndex = 0;
    if (_childFocused) { _childFocused = NO; _tabsFocused = YES; }
    [self updateTabs];
}

- (PXScreen *)childAt:(NSInteger)index {
    return index < (NSInteger)_tabs.count ? _children[_tabs[index][@"id"]] : nil;
}

- (BOOL)showsServersTab { return !self.server && [PXPlex shared].servers.count > 1; }

- (void)buildTabs:(NSArray *)sections {
    NSString *shownId = _shownTab < (NSInteger)_tabs.count ? _tabs[_shownTab][@"id"] : nil;
    NSString *focusId = _tabIndex < (NSInteger)_tabs.count ? _tabs[_tabIndex][@"id"] : nil;
    // Each tab builds its content once (kept while the home lives, across
    // tab rebuilds, by tab id); Accueil is the home itself (no factory).
    NSMutableArray *defs = [NSMutableArray arrayWithObject:@{ @"id": @"home", @"title": self.server ? self.server.name : PXL(@"Accueil") }];
    for (NSDictionary *s in sections) {
        NSString *sid = [NSString stringWithFormat:@"section:%@/%@", s[@"_server"] ?: @"", s[@"key"] ?: s[@"title"] ?: @"?"];
        [defs addObject:@{ @"id": sid, @"title": s[@"title"] ?: @"?", @"make": ^PXScreen *{ return PXLibraryScreenNew(s, YES); } }];
    }
    if (_hasWatchlist && !self.server) {
        [defs addObject:@{ @"id": @"watchlist", @"title": PXL(@"Ma liste"), @"make": ^PXScreen *{
            return PXItemListScreenNewEmbedded(PXL(@"Ma liste"), @"/library/sections/watchlist/all?includeCollections=1&includeExternalMedia=1",
                                               [PXPlex shared].onlineProvider);
        } }];
    }
    if (_hasPlaylists) {
        PXServer *sv = self.server ?: [PXPlex shared].primaryServer;
        [defs addObject:@{ @"id": [@"playlists:" stringByAppendingString:sv.identifier ?: @""], @"title": PXL(@"Listes de lecture"), @"make": ^PXScreen *{
            return PXItemListScreenNewEmbedded(PXL(@"Listes de lecture"), @"/playlists?playlistType=video", sv);
        } }];
    }
    if ([self showsServersTab]) [defs addObject:@{ @"id": @"servers", @"title": PXL(@"Serveurs"), @"make": ^PXScreen *{ return PXServerListScreenNew(YES); } }];
    if (!self.server) {
        [defs addObject:@{ @"id": @"discover", @"title": PXL(@"Découvrir"), @"make": ^PXScreen *{ return PXDiscoverScreenNew(); } }];
        [defs addObject:@{ @"id": @"search", @"title": PXL(@"Rechercher"), @"make": ^PXScreen *{ return PXSearchScreenNew(YES); } }];
        [defs addObject:@{ @"id": @"settings", @"title": PXL(@"Réglages"), @"make": ^PXScreen *{ return PXSettingsScreenNew(YES); } }];
    }
    // Late answers (watchlist, playlists, server list) add or remove tabs:
    // keep the contents still listed and the tab the user is on.
    NSArray *ids = [defs valueForKey:@"id"];
    for (NSString *cid in _children.allKeys) {
        if ([ids containsObject:cid]) continue;
        PXScreen *c = _children[cid];
        [c willDisappear];
        [c didPop];
        PXNoAnim(^{ [c.layer removeFromSuperlayer]; });
        [_children removeObjectForKey:cid];
    }
    if (!_children) _children = [NSMutableDictionary dictionary];
    NSUInteger shown = shownId ? [ids indexOfObject:shownId] : NSNotFound;
    NSUInteger focus = focusId ? [ids indexOfObject:focusId] : NSNotFound;
    if (shown == NSNotFound) {
        // The tab shown is gone: back on Accueil.
        shown = 0;
        focus = 0;
        if (_childFocused) { _childFocused = NO; _tabsFocused = YES; }
        [self restoreHomeLayers];
    }
    _shownTab = shown;
    _tabIndex = focus == NSNotFound ? shown : focus;
    // Many libraries / tabs: tighter pills, then a smaller font, so the bar
    // stays clear of the clock (right ~300 px).
    NSArray *titles = [defs valueForKey:@"title"];
    UIFont *f = PXFontSemi(28);
    CGFloat pad = 48, room = 1920 - 84 - 300, total = 0;
    for (NSString *t in titles) total += PXTextWidth(t, f) + pad + 6;
    if (total > room) { pad = 28; total = 0; for (NSString *t in titles) total += PXTextWidth(t, f) + pad + 6; }
    if (total > room) { f = PXFontSemi(24); pad = 24; }
    _tabsBar.font = f;
    _tabsBar.padding = pad;
    _tabsBar.titles = titles;
    _tabs = defs;
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
    // The tab shown gets a panel only while the focus is below the bar.
    _tabsBar.selectedColor = _tabsFocused ? nil : [UIColor colorWithCGColor:PXColorPanel()];
    [_tabsBar setSelected:_shownTab focused:_tabsFocused ? _tabIndex : -1];
}

#pragma mark - Tab content

// Shows the content of a tab (called when the focus rests on it).
- (void)showTab:(NSInteger)index {
    if (index == _shownTab || index >= (NSInteger)_tabs.count) return;
    PXScreen *old = [self childAt:_shownTab];
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
        PXScreen *child = [self childAt:index];
        if (!child) {
            PXScreen *(^make)(void) = _tabs[index][@"make"];
            child = make ? make() : nil;
            if (child) _children[_tabs[index][@"id"]] = child;
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
    PXScreen *child = [self childAt:_shownTab];
    _childFocused = focus && child;
    _tabsFocused = !_childFocused;
    child.hasFocus = _childFocused;
    [self updateTabs];
}

#pragma mark - Data

- (void)willDisappear {
    [super willDisappear];
    [[self childAt:_shownTab] willDisappear];
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
    if (_shownTab != 0) { [[self childAt:_shownTab] didAppear]; return; }
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
    _historyHub = nil;
    for (PXShelfLayer *sh in _shelves) [sh removeFromSuperlayer];
    [_shelves removeAllObjects];
    _shelfIndex = 0;
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
        if (!retry) { _loading = NO; if (!_loaded) PXSetText(_status, PXL(@"Aucun serveur Plex sur ce compte.")); return; }
        if (!_loaded) PXSetText(_status, PXL(@"Recherche des serveurs…"));
        [plex reconnect:^(id conn, NSError *e) { [weak loadRetrying:NO]; }];
        return;
    }
    // Tabs: libraries of this server (main home: the primary server).
    [tabsServer get:@"/library/sections" done:^(NSDictionary *mc, NSError *err) {
        PXHomeScreen *me = weak;
        if (!me) return;
        // Already loaded: the shelves stay, no status over them.
        if (err && retry) {
            if (!me->_loaded) PXSetText(me->_status, PXLF(@"Connexion à %@…", tabsServer.name));
            void (^again)(id, NSError *) = ^(id conn, NSError *e) { [weak loadRetrying:NO]; };
            if (me.server) [tabsServer reconnect:again]; else [plex reconnect:again];
            return;
        }
        if (err) {
            me->_loading = NO;
            PXLog(@"home: %@ unreachable: %@", tabsServer.name, err.localizedDescription);
            if (!me->_loaded) PXSetText(me->_status, PXLF(@"%@ injoignable : %@", tabsServer.name, err.localizedDescription));
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
        // No server answered (timeout, network down): a refresh keeps what is shown.
        if (!ordered.count && me->_loaded) { PXLog(@"home: refresh failed, keeping the shelves"); return; }
        NSArray *hubs = [me mergeHubs:ordered];
        if (me->_historyHub) hubs = [hubs arrayByAddingObject:me->_historyHub];
        [me showHubs:hubs];
    };
    if (!pending) { finish(); return; }
    // The history row is part of this load (shown with the hubs, not one reload later).
    if (!self.server) {
        pending++;
        [self loadHistory:^{ if (--pending == 0) finish(); }];
    }
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

// What a refresh can change on a hub item: watch state and progress
// (leaf counts: the unwatched badge of shows and seasons), and edits made on
// the server (updatedAt, title, artwork). The server address too: cells cache
// artwork URLs on the item.
static NSString *itemSignature(PXItem *it) {
    NSDictionary *r = it.raw;
    return [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@|%@|%@|%@", it.uniqueKey, r[@"viewOffset"], r[@"viewCount"], r[@"lastViewedAt"],
            r[@"viewedLeafCount"], r[@"leafCount"], r[@"updatedAt"], r[@"title"], r[@"thumb"], it.server.uri];
}

- (void)showHubs:(NSArray *)hubs {
    // Items already shown and unchanged keep their PXItem (cells and hero
    // compare pointers / keys): a refresh redraws only what changed.
    NSMutableDictionary *oldItems = [NSMutableDictionary dictionary];   // uniqueKey -> PXItem
    for (PXShelfLayer *s in _shelves) for (PXItem *it in s.items) oldItems[it.uniqueKey] = it;
    NSMutableDictionary *newSigs = [NSMutableDictionary dictionary];    // uniqueKey -> signature
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
        NSMutableArray *sigs = [NSMutableArray array];
        for (PXItem *fresh in [PXItem itemsWithJSON:h[@"Metadata"]]) {
            if (fresh.type == PXItemOther) continue;
            // "À l'affiche" repeats what "Continuer à regarder" already shows.
            if (deck && [inProgress containsObject:fresh.uniqueKey]) continue;
            if (cont) [inProgress addObject:fresh.uniqueKey];
            NSString *sig = itemSignature(fresh);
            PXItem *prev = oldItems[fresh.uniqueKey];
            [videos addObject:prev && [itemSignature(prev) isEqual:sig] ? prev : fresh];
            newSigs[fresh.uniqueKey] = sig;
            [sigs addObject:sig];
        }
        if (!videos.count) continue;
        BOOL cards = !music && (cont || deck || PXItemsPreferLandscape(videos));
        [rows addObject:@{ @"title": h[@"title"] ?: @"", @"id": hid, @"items": videos, @"cards": @(cards), @"square": @(music),
                           @"signature": [sigs componentsJoinedByString:@"\n"] }];
    }
    PXLog(@"home: %lu shelves", (unsigned long)rows.count);
    // Full items (summary, watch state) refetched only for what changed.
    for (NSString *k in _fullItems.allKeys) {
        PXItem *prev = oldItems[k];
        if (!prev || ![itemSignature(prev) isEqual:newSigs[k]]) [_fullItems removeObjectForKey:k];
    }
    PXSetText(_status, rows.count ? @"" : PXL(@"Rien à afficher pour le moment."));
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
        if (![s.title isEqual:r[@"title"]]) s.title = r[@"title"];
        // Same items in the same state: the cells stay as they are.
        if (![[s valueForKey:@"pxSignature"] isEqual:r[@"signature"]]) {
            s.items = r[@"items"];
            [s setValue:r[@"signature"] forKey:@"pxSignature"];
        }
        PXNoAnim(^{
            s.position = CGPointMake(0, y);
            if (s.superlayer != self->_shelvesLayer) [self->_shelvesLayer addSublayer:s];
        });
        y += s.height - 10;
        [shelves addObject:s];
    }
    for (PXShelfLayer *s in old.allValues) [s removeFromSuperlayer];
    _shelves = shelves;

    // Focus: same shelf (else the same position), same item (found by key if it moved).
    NSInteger idx = _shelfIndex;
    for (NSInteger i = 0; i < (NSInteger)_shelves.count; i++) if ([[_shelves[i] name] isEqual:focusedShelf]) idx = i;
    _shelfIndex = MIN(idx, MAX(0, (NSInteger)_shelves.count - 1));
    if (focusedItem && _shelfIndex < (NSInteger)_shelves.count) {
        PXShelfLayer *s = _shelves[_shelfIndex];
        NSUInteger i = [s.items indexOfObjectPassingTest:^BOOL(PXItem *it, NSUInteger n, BOOL *stop) { return [it.uniqueKey isEqual:focusedItem.uniqueKey]; }];
        if (i != NSNotFound && (NSInteger)i != s.focusIndex) [s setFocusIndex:i animated:NO];
    }
    if (!_shelves.count) _tabsFocused = YES;
    // Hero rebuilt (~300 ms) only when the focused title changed or its state did.
    PXItem *focused = _shelfIndex < (NSInteger)_shelves.count ? [_shelves[_shelfIndex] focusedItem] : nil;
    if (!focused || ![focused.uniqueKey isEqual:_heroItem.uniqueKey] || ![itemSignature(focused) isEqual:itemSignature(_heroItem)]) _heroItem = nil;
    _pendingHero = nil;
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
    if (_overlay) return [_overlay handleKey:key];
    if (_childFocused) {
        PXScreen *child = [self childAt:_shownTab];
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
        case PXKeySelectHold: {
            // Long press in "Continuer à regarder": remove the title from it.
            PXItem *it = shelf.focusedItem;
            if (it && [shelf.name containsString:@"continue"]) [self offerRemoveFromContinue:it];
            return YES;
        }
        case PXKeyPlayPause: {
            PXItem *it = shelf.focusedItem;
            if (it && (it.type == PXItemMovie || it.type == PXItemEpisode)) [self push:PXPlayerScreenNew(it, -1)];
            return YES;
        }
        case PXKeyMenu:
            if (!_tabsFocused) { _tabsFocused = YES; _tabIndex = 0; _shelfIndex = 0; [self updateFocus:YES]; return YES; }
            return NO;
        default: return NO;
    }
}

// Watch history of the primary server, own views only (account 1 = the server
// owner; other Plex Home profiles have no stable local id here, so no row).
// `done` is called once on every path; a failed request keeps the last row.
- (void)loadHistory:(void (^)(void))done {
    PXPlex *plex = [PXPlex shared];
    PXServer *sv = plex.primaryServer;
    NSDictionary *user = plex.currentHomeUser;
    if (!sv.owned || (user && ![user[@"admin"] boolValue])) { _historyHub = nil; done(); return; }
    __weak PXHomeScreen *weak = self;
    [sv get:@"/status/sessions/history/all?sort=viewedAt:desc&accountID=1&X-Plex-Container-Size=40" done:^(NSDictionary *mc, NSError *err) {
        PXHomeScreen *me = weak;
        if (!me || ![mc[@"Metadata"] isKindOfClass:[NSArray class]]) { done(); return; }
        // One entry per title (an episode watched twice, a film rewatched).
        NSMutableArray *items = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        for (NSDictionary *m in mc[@"Metadata"]) {
            if (![m isKindOfClass:[NSDictionary class]] || !m[@"ratingKey"] || [seen containsObject:m[@"ratingKey"]]) continue;
            if (![@[ @"movie", @"episode" ] containsObject:m[@"type"] ?: @""]) continue;
            [seen addObject:m[@"ratingKey"]];
            [items addObject:m];
            if (items.count >= 20) break;
        }
        me->_historyHub = items.count ? @{ @"hubIdentifier": @"home.history", @"title": PXL(@"Regardés récemment"), @"type": @"mixed", @"Metadata": items } : nil;
        done();
    }];
}

- (void)offerRemoveFromContinue:(PXItem *)it {
    __weak PXHomeScreen *weak = self;
    PXListRow *row = [PXListRow title:PXL(@"Retirer de Continuer à regarder") value:@"" action:^{
        PXHomeScreen *me = weak;
        [me->_overlay close];
        [it.server put:[NSString stringWithFormat:@"/actions/removeFromContinueWatching?ratingKey=%@", it.ratingKey] done:^(id j, NSError *e) {
            PXLog(@"home: removed '%@' from continue watching %@", it.title, e ? e.localizedDescription : @"ok");
            [weak reload];
        }];
    }];
    _overlay = [PXOverlay overlayInLayer:self.layer title:it.title ?: @"" rows:@[ row ]];
    _overlay.onClose = ^{ PXHomeScreen *me = weak; if (me) me->_overlay = nil; };
}

- (void)didPop {
    // The main home leaves the stack when the app is left: so does the music.
    if (!self.server) [[PXMusicPlayer shared] stop];
    for (PXScreen *c in _children.allValues) [c didPop];
    if (_clockTimer) dispatch_source_cancel(_clockTimer);
    _clockTimer = nil;
    [self removeObservers];
    [super didPop];
}

- (void)removeObservers {
    if (_serversObserver) [[NSNotificationCenter defaultCenter] removeObserver:_serversObserver];
    if (_userObserver) [[NSNotificationCenter defaultCenter] removeObserver:_userObserver];
    _serversObserver = _userObserver = nil;
}

- (void)dealloc { [self removeObservers]; }

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
