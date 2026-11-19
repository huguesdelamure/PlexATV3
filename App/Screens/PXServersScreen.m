// Choice of the servers shown on the home (first launch, then Réglages).
// Every server of the account stays reachable through search and the
// "Serveurs" tab; this only decides what the home and its rows gather.

#import "PXRouter.h"
#import "PXUI.h"
#import "PXListLayer.h"
#import "PXAmbientLayer.h"
#import "PXPlex.h"
#import "PXServer.h"
#import "PXLog.h"

@interface PXServersScreen : PXScreen
@property (nonatomic, copy) void (^completion)(void);
@end

@implementation PXServersScreen {
    PXListLayer *_list;
    NSMutableSet *_chosen;     // identifiers
    NSArray *_servers;
}

- (void)setup {
    [self.layer addSublayer:[[PXAmbientLayer alloc] initWithFrame:self.layer.bounds style:PXAmbientBlurOnly]];
    [self.layer addSublayer:PXAsyncLabel(PXL(@"Serveurs à afficher"), PXFontHeavy(64), PXColorText(), CGRectMake(160, 90, 1500, 80), 1, NO)];
    [self.layer addSublayer:PXAsyncLabel(PXL(@"L'accueil et ses rangées rassemblent les serveurs cochés. Les autres restent accessibles par la recherche et l'onglet Serveurs."),
                                         PXFont(28), PXColorTextDim(), CGRectMake(160, 180, 1500, 80), 2, NO)];
    _list = [[PXListLayer alloc] initWithFrame:CGRectMake(160, 290, 1600, 720) rowHeight:76];
    [self.layer addSublayer:_list];
    _chosen = [NSMutableSet setWithArray:[[PXPlex shared].selectedServers valueForKey:@"identifier"]];
    _servers = [PXPlex shared].servers;
    [self buildRows];
    // Fresh list (names, presence) from plex.tv.
    __weak PXServersScreen *weak = self;
    [[PXPlex shared] fetchServers:^(NSArray *servers, NSError *err) {
        PXServersScreen *me = weak;
        if (!me || !servers.count) return;
        me->_servers = [PXPlex shared].servers;
        [me buildRows];   // the list keeps its focused row
    }];
}

// Own servers first (then online ones first if asked), by name.
static NSArray *sortedServers(NSArray *servers, BOOL onlineFirst) {
    return [servers sortedArrayUsingComparator:^NSComparisonResult(PXServer *a, PXServer *b) {
        if (a.owned != b.owned) return a.owned ? NSOrderedAscending : NSOrderedDescending;
        if (onlineFirst && a.online != b.online) return a.online ? NSOrderedAscending : NSOrderedDescending;
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
}

// "ton serveur" / "partagé par X", twin label, offline mark.
static NSString *serverLabel(PXServer *s, NSArray *servers) {
    NSString *who = s.owned ? PXL(@"ton serveur") : PXLF(@"partagé par %@", s.sourceTitle ?: PXL(@"un ami"));
    NSString *twin = PXServerTwinLabel(s.resource, [servers valueForKey:@"resource"]);
    if (twin) who = [NSString stringWithFormat:@"%@ · %@", twin, who];
    return s.online ? who : [who stringByAppendingString:PXL(@" · hors ligne")];
}

- (void)buildRows {
    NSMutableArray *rows = [NSMutableArray array];
    __weak PXServersScreen *weak = self;
    for (PXServer *s in sortedServers(_servers, NO)) {
        NSString *sid = s.identifier;
        PXListRow *r = [PXListRow title:s.name value:serverLabel(s, _servers) action:^{ [weak toggle:sid]; }];
        r.checked = [_chosen containsObject:sid];
        [rows addObject:r];
    }
    NSString *label = _chosen.count ? (_chosen.count > 1 ? PXLF(@"Valider (%lu serveurs)", (unsigned long)_chosen.count) : PXLF(@"Valider (%lu serveur)", (unsigned long)_chosen.count))
                                    : PXL(@"Coche au moins un serveur");
    PXListRow *ok = [PXListRow title:label value:@"" action:^{ [weak validate]; }];
    ok.enabled = _chosen.count > 0;
    [rows addObject:ok];
    _list.rows = rows;
}

- (void)toggle:(NSString *)sid {
    if ([_chosen containsObject:sid]) [_chosen removeObject:sid]; else [_chosen addObject:sid];
    [self buildRows];
}

- (void)validate {
    if (!_chosen.count) return;
    NSMutableArray *list = [NSMutableArray array];
    for (PXServer *s in [PXPlex shared].servers) if ([_chosen containsObject:s.identifier]) [list addObject:s];
    [PXPlex shared].selectedServers = list;
    PXLog(@"servers: %lu selected for the home", (unsigned long)list.count);
    void (^done)(void) = self.completion;
    [self pop];
    if (done) done();
}

- (void)focusChanged { _list.active = self.hasFocus; }

- (BOOL)handleKey:(PXKey)key {
    switch (key) {
        case PXKeyUp: [_list handleUp]; return YES;
        case PXKeyDown: [_list handleDown]; return YES;
        case PXKeySelect: [_list activate]; return YES;
        default: return NO;
    }
}

@end

PXScreen *PXServersScreenNew(void (^completion)(void)) {
    PXServersScreen *s = [PXServersScreen new];
    s.completion = completion;
    [s setup];
    return s;
}

#pragma mark - "Serveurs" tab

@interface PXServerListScreen : PXScreen
@end

@implementation PXServerListScreen {
    PXListLayer *_list;
}

- (void)setup {
    [self.layer addSublayer:[[PXAmbientLayer alloc] initWithFrame:self.layer.bounds style:PXAmbientBlurOnly]];
    CGFloat top = self.embedded ? 0 : 140;
    if (!self.embedded) [self.layer addSublayer:PXAsyncLabel(PXL(@"Serveurs"), PXFontHeavy(64), PXColorText(), CGRectMake(160, 70, 1500, 80), 1, NO)];
    _list = [[PXListLayer alloc] initWithFrame:CGRectMake(160, 200 + top, 1600, 800 - top) rowHeight:76];
    [self.layer addSublayer:_list];
    [self buildRows];
    __weak PXServerListScreen *weak = self;
    [[PXPlex shared] fetchServers:^(NSArray *servers, NSError *err) {
        PXServerListScreen *me = weak;
        if (!me || !servers.count) return;
        [me buildRows];
    }];
}

- (void)buildRows {
    NSMutableArray *rows = [NSMutableArray array];
    __weak PXServerListScreen *weak = self;
    NSArray *servers = [PXPlex shared].servers;
    for (PXServer *s in sortedServers(servers, YES)) {
        PXListRow *r = [PXListRow title:s.name value:serverLabel(s, servers) action:^{
            [weak push:PXHomeScreenForServer(s)];
        }];
        [rows addObject:r];
    }
    if (!rows.count) [rows addObject:[PXListRow title:PXL(@"Aucun serveur") value:@"" action:nil]];
    _list.rows = rows;
}

- (void)focusChanged { _list.active = self.hasFocus; }

- (BOOL)handleKey:(PXKey)key {
    switch (key) {
        case PXKeyUp: return [_list handleUp] || !self.embedded;   // top edge: back to the tabs
        case PXKeyDown: [_list handleDown]; return YES;
        case PXKeySelect: [_list activate]; return YES;
        default: return NO;
    }
}

@end

PXScreen *PXServerListScreenNew(BOOL embedded) {
    PXServerListScreen *s = [PXServerListScreen new];
    s.embedded = embedded;
    [s setup];
    return s;
}
