// Movie / episode detail page (scrolls vertically):
//   header  full-bleed backdrop, title, metadata, ratings, tech pills,
//           tagline, summary, action buttons (resume, restart, audio,
//           subtitles, watched)
//   below   cast (circular photos), similar titles (posters)

#import "PXRouter.h"
#import "PXServer.h"
#import "PXUI.h"
#import "PXOverlay.h"
#import "PXTracks.h"
#import "PXAmbientPlex.h"
#import "PXButtonRow.h"
#import "PXDecor.h"
#import "PXShelfLayer.h"
#import "PXPlex.h"
#import "PXBackRow.h"
#import "PXListLayer.h"
#import "PXItem.h"
#import "PXLog.h"
#import "PXTrackPrefs.h"

static const CGFloat kLeft = 110, kTextW = 1080, kButtonsY = 830, kLowerY = 980;

typedef NS_ENUM(NSInteger, PXZone) { PXZoneButtons, PXZoneCast, PXZoneExtras, PXZoneSimilar };

@interface PXDetailScreen : PXScreen
@property (nonatomic, strong) PXItem *item;
@end

@implementation PXDetailScreen {
    PXAmbientLayer *_ambient;
    CALayer *_page;
    CALayer *_header;
    PXButtonRow *_buttons;
    PXCastRow *_cast;
    PXShelfLayer *_similar;
    PXShelfLayer *_extras;          // trailers, behind the scenes…
    PXZone _zone;
    PXOverlay *_overlay;
    BOOL _similarLoaded;
    NSArray *_locations;            // same title on other servers (PXItem)
    NSString *_locationsFor;        // guid already searched
}

- (void)setup {
    _ambient = [[PXAmbientLayer alloc] initWithFrame:self.layer.bounds style:PXAmbientDetail];
    [self.layer addSublayer:_ambient];
    _page = [CALayer layer];
    _page.anchorPoint = CGPointZero;
    _page.bounds = CGRectMake(0, 0, 1920, 2200);
    [self.layer addSublayer:_page];
    _header = [CALayer layer];
    _header.frame = CGRectMake(0, 0, 1920, 1080);
    [_page addSublayer:_header];
    _buttons = [[PXButtonRow alloc] initWithFrame:CGRectMake(kLeft, kButtonsY, 1700, 80)];
    [_page addSublayer:_buttons];
    _cast = [[PXCastRow alloc] initWithWidth:1920];
    _cast.position = CGPointMake(0, kLowerY);
    [_page addSublayer:_cast];
    _extras = [[PXShelfLayer alloc] initWithTitle:PXL(@"Bonus") width:1920 imageSize:CGSizeMake(380, 214) artwork:PXArtworkThumb];
    _extras.leftMargin = kLeft;
    _extras.hidden = YES;
    [_page addSublayer:_extras];
    _similar = [[PXShelfLayer alloc] initWithTitle:PXL(@"Titres similaires") width:1920 imageSize:CGSizeMake(200, 300) artwork:PXArtworkPoster];
    _similar.leftMargin = kLeft;
    _similar.position = CGPointMake(0, kLowerY + _cast.height + 20);
    _similar.hidden = YES;
    [_page addSublayer:_similar];
    [_ambient showItem:self.item];
    [self render];
}

#pragma mark - Render

- (void)render {
    PXItem *it = self.item;
    for (CALayer *l in [_header.sublayers copy]) [l removeFromSuperlayer];
    BOOL episode = it.type == PXItemEpisode;
    CGFloat y = 150;
    if (episode) {
        // Texts drawn off the main thread: CATextLayers rendered at commit
        // cost up to 1 s of main thread here (stall sampler).
        [_header addSublayer:PXAsyncLabel([NSString stringWithFormat:@"%@  ·  %@", it.grandparentTitle ?: @"", it.episodeCode],
                                          PXFontSemi(30), PXColorAccent(), CGRectMake(kLeft, y, kTextW, 40), 1, NO)];
        y += 48;
    }
    // Title: up to two lines, size adapted to length.
    UIFont *tf = PXFitFont(it.title, PXHeavy, 84, 48, kTextW, 2);
    CGFloat th = MIN(PXTextHeight(it.title, tf, kTextW - 12), ceil(tf.lineHeight) * 2) + 6;
    [_header addSublayer:PXAsyncLabel(it.title, tf, PXColorText(), CGRectMake(kLeft, y, kTextW - 12, th), 2, NO)];
    y += th + 14;

    NSMutableArray *meta = [NSMutableArray array];
    if (it.year) [meta addObject:[@(it.year) stringValue]];
    if (it.duration > 0) [meta addObject:PXDurationText(it.duration)];
    if (it.contentRating.length) [meta addObject:it.contentRating];
    if (it.genres.count) [meta addObject:[[it.genres subarrayWithRange:NSMakeRange(0, MIN(3, it.genres.count))] componentsJoinedByString:@", "]];
    [_header addSublayer:PXAsyncLabel([meta componentsJoinedByString:@"   ·   "], PXFontMedium(28), PXColorTextDim(), CGRectMake(kLeft, y, kTextW, 38), 1, NO)];
    y += 54;

    CALayer *ratings = PXRatingsRow(it.ratings, CGPointMake(kLeft, y));
    CALayer *pills = PXPillsRow(it.techBadges, CGPointMake(kLeft + (ratings.bounds.size.width ? ratings.bounds.size.width + 16 : 0), y));
    [_header addSublayer:ratings];
    [_header addSublayer:pills];
    y += 62;

    if (it.tagline.length) {
        [_header addSublayer:PXAsyncLabel(it.tagline, PXFontSemi(28), PXColorWhite(0.9), CGRectMake(kLeft, y, kTextW, 38), 1, NO)];
        y += 46;
    }
    UIFont *sf = PXFont(28);
    CGFloat maxSummary = kButtonsY - 70 - y;
    CGFloat sh = MIN(PXTextHeight(it.summary, sf, kTextW), floor(maxSummary / sf.lineHeight) * sf.lineHeight);
    NSInteger lines = MAX(0, (NSInteger)floor(maxSummary / sf.lineHeight));
    if (lines && sh > 0) [_header addSublayer:PXAsyncLabel(it.summary, sf, PXColorWhite(0.82), CGRectMake(kLeft, y, kTextW, sh), lines, NO)];

    if (it.directors.count) {
        [_header addSublayer:PXAsyncLabel([PXL(@"Réalisation : ") stringByAppendingString:[it.directors componentsJoinedByString:@", "]],
                                          PXFont(24), PXColorTextFaint(), CGRectMake(kLeft, kButtonsY - 50, kTextW, 32), 1, NO)];
    }
    [self buildButtons];
    _cast.server = it.server;
    _cast.people = it.cast;
    _cast.hidden = !it.cast.count;
    _extras.items = it.server.provider ? @[] : it.extras;   // online extras: fMP4 HLS, not playable on iOS 8
    _extras.hidden = !it.extras.count;
    PXNoAnim(^{
        CGFloat y = kLowerY + (it.cast.count ? self->_cast.height + 20 : 0);
        self->_extras.position = CGPointMake(0, y);
        if (it.extras.count) y += self->_extras.height + 20;
        self->_similar.position = CGPointMake(0, y);
    });
    if (!_similarLoaded && it.type == PXItemMovie && it.media && !it.server.provider) [self loadSimilar];
}

- (void)buildButtons {
    PXItem *it = self.item;
    __weak PXDetailScreen *weak = self;
    NSMutableArray *b = [NSMutableArray array];
    BOOL listed = [[PXPlex shared] isWatchlisted:it.guid];
    PXButton *watch = [it.guid hasPrefix:@"plex://"] ? [PXButton icon:listed ? PXIconCheck : PXIconStar title:listed ? PXL(@"Dans ma liste") : PXL(@"Ajouter à ma liste")
                                                                action:^{ [weak toggleWatchlist]; }] : nil;
    if (it.server.provider) {
        // Online title, on none of the servers: only the watchlist.
        if (watch) [b addObject:watch];
        _buttons.buttons = b;
        _buttons.focusIndex = 0;
        _buttons.active = _zone == PXZoneButtons && !_overlay;
        return;
    }
    if (it.viewOffset > 30) {
        [b addObject:[PXButton icon:PXIconPlay title:PXLF(@"Reprendre à %@", PXClock(it.viewOffset)) action:^{ [weak play:YES]; }]];
        [b addObject:[PXButton icon:PXIconRestart title:PXL(@"Du début") action:^{ [weak play:NO]; }]];
    } else {
        [b addObject:[PXButton icon:PXIconPlay title:PXL(@"Lecture") action:^{ [weak play:NO]; }]];
    }
    if (it.audioStreams.count > 1) [b addObject:[PXButton icon:PXIconAudio title:PXShortTrack(it.selectedAudio) action:^{ [weak pickAudio]; }]];
    if (it.subtitleStreams.count) [b addObject:[PXButton icon:PXIconSubtitles title:it.selectedSubtitle ? PXShortTrack(it.selectedSubtitle) : PXL(@"Sans sous-titres") action:^{ [weak pickSubtitle]; }]];
    if (it.mediaList.count > 1)
        [b addObject:[PXButton icon:PXIconInfo title:[[PXItem labelForMedia:it.media] componentsSeparatedByString:@" · "].firstObject action:^{ [weak pickVersion]; }]];
    if (_locations.count)
        [b addObject:[PXButton icon:PXIconSearch title:PXLF(@"Sources (%lu)", (unsigned long)_locations.count + 1) action:^{ [weak pickLocation]; }]];
    [b addObject:[PXButton icon:PXIconCheck title:it.watched ? PXL(@"Vu") : PXL(@"Marquer vu") action:^{ [weak toggleWatched]; }]];
    if (watch) [b addObject:watch];
    NSInteger keep = _buttons.focusIndex;
    _buttons.buttons = b;
    _buttons.focusIndex = keep;
    _buttons.active = _zone == PXZoneButtons && !_overlay;
}

- (void)loadSimilar {
    _similarLoaded = YES;
    __weak PXDetailScreen *weak = self;
    [self.item.server get:[NSString stringWithFormat:@"/library/metadata/%@/similar?count=20", self.item.ratingKey] done:^(NSDictionary *mc, NSError *err) {
        PXDetailScreen *me = weak;
        if (!me) return;
        me->_similar.items = [PXItem itemsWithJSON:mc[@"Metadata"]];
        me->_similar.hidden = !me->_similar.items.count;
    }];
}

#pragma mark - Focus

- (NSArray *)zones {
    NSMutableArray *z = [NSMutableArray arrayWithObject:@(PXZoneButtons)];
    if (!_cast.hidden && _cast.people.count) [z addObject:@(PXZoneCast)];
    if (!_extras.hidden && _extras.items.count) [z addObject:@(PXZoneExtras)];
    if (!_similar.hidden && _similar.items.count) [z addObject:@(PXZoneSimilar)];
    return z;
}

- (void)setZone:(PXZone)zone {
    _zone = zone;
    _buttons.active = zone == PXZoneButtons && !_overlay;
    _cast.active = zone == PXZoneCast;
    _extras.active = zone == PXZoneExtras;
    _similar.active = zone == PXZoneSimilar;
    CGFloat offset = 0;
    if (zone == PXZoneCast) offset = kLowerY - 300;
    if (zone == PXZoneExtras) offset = _extras.position.y - 300;
    if (zone == PXZoneSimilar) offset = _similar.position.y - 300;
    PXAnim(0.4, ^{
        self->_page.position = CGPointMake(0, -offset);
        self->_header.opacity = zone == PXZoneButtons ? 1 : 0.25;
    });
    [_ambient setArtOpacity:zone == PXZoneButtons ? 0.9 : 0.35];
}

#pragma mark - Data / actions

- (void)toggleWatchlist {
    BOOL on = ![[PXPlex shared] isWatchlisted:self.item.guid];
    __weak PXDetailScreen *weak = self;
    [[PXPlex shared] setWatchlisted:on guid:self.item.guid done:^(id json, NSError *err) { [weak buildButtons]; }];
}

// Filmography of the focused cast member in this library.
- (void)openPerson {
    NSInteger i = _cast.focusIndex;
    NSArray *people = _cast.people;
    if (i < 0 || i >= (NSInteger)people.count) return;
    NSDictionary *p = people[i];
    NSString *sid = self.item.librarySectionID, *tag = p[@"id"];
    if (!sid.length || !tag.length) return;
    NSString *path = [NSString stringWithFormat:@"/library/sections/%@/all?actor=%@&sort=originallyAvailableAt:desc", sid, tag];
    [self push:PXItemListScreenNew(p[@"name"], path, self.item.server)];
}

- (void)reloadItem {
    __weak PXDetailScreen *weak = self;
    [self.item.server metadata:self.item.ratingKey done:^(NSDictionary *m, NSError *err) {
        PXDetailScreen *me = weak;
        if (!me || !m) return;
        me.item = [PXItem itemWithJSON:m];
        [me->_ambient showItem:me.item];
        [me render];
        [me loadLocations];
    }];
}

// "Other locations": the same title (same plex:// guid) on the other online
// servers, found with a title search on each (5 s at most).
- (void)loadLocations {
    PXItem *it = self.item;
    NSString *guid = it.guid;
    if (![guid hasPrefix:@"plex://"] || [guid isEqual:_locationsFor] || !(it.type == PXItemMovie || it.type == PXItemEpisode) || it.server.provider) return;
    _locationsFor = guid;
    NSMutableArray *servers = [NSMutableArray array];
    for (PXServer *s in [PXPlex shared].servers) if (s.online && s != it.server) [servers addObject:s];
    if (!servers.count) return;
    NSString *query = it.type == PXItemEpisode ? (it.grandparentTitle ?: it.title) : it.title;
    NSString *path = [NSString stringWithFormat:@"/hubs/search?query=%@&limit=10", PXEncode(query)];
    NSMutableArray *found = [NSMutableArray array];
    __block NSInteger pending = servers.count;
    __block BOOL done = NO;
    __weak PXDetailScreen *weak = self;
    void (^finish)(void) = ^{
        if (done) return;
        done = YES;
        PXDetailScreen *me = weak;
        if (!me || ![me.item.guid isEqual:guid]) return;
        me->_locations = found;
        PXLog(@"detail: '%@' on %lu other server(s)", query, (unsigned long)found.count);
        if (found.count) [me buildButtons];
    };
    for (PXServer *s in servers) {
        [s get:path done:^(NSDictionary *mc, NSError *err) {
            for (NSDictionary *h in mc[@"Hub"])
                for (PXItem *cand in [PXItem itemsWithJSON:h[@"Metadata"]])
                    if ([cand.guid isEqual:guid]) { [found addObject:cand]; break; }
            if (--pending == 0) finish();
        }];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), finish);
}

- (void)pickVersion {
    __weak PXDetailScreen *weak = self;
    NSMutableArray *rows = [NSMutableArray array];
    NSArray *list = self.item.mediaList;
    for (NSUInteger i = 0; i < list.count; i++) {
        PXListRow *r = [PXListRow title:[PXItem labelForMedia:list[i]] value:@"" action:^{
            [weak closeOverlay];
            [weak.item chooseMediaAtIndex:(NSInteger)i];
            [weak render];
        }];
        r.checked = (NSInteger)i == self.item.mediaIndex;
        [rows addObject:r];
    }
    [self showOverlay:PXL(@"Version") rows:rows];
}

- (void)pickLocation {
    __weak PXDetailScreen *weak = self;
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableArray *all = [NSMutableArray arrayWithObject:self.item];
    [all addObjectsFromArray:_locations];
    for (PXItem *loc in all) {
        NSString *where = loc.server.owned ? loc.server.name : [NSString stringWithFormat:@"%@ (%@)", loc.server.name, loc.server.sourceTitle ?: PXL(@"partagé")];
        PXListRow *r = [PXListRow title:where value:[PXItem labelForMedia:loc.media] action:^{
            PXDetailScreen *me = weak;
            [me closeOverlay];
            if (!me || loc == me.item) return;
            // Open the title on that server (its own versions, tracks, progress).
            [[me.host stack] swapController:PXHostControllerForScreen(PXScreenForItem(loc))];
        }];
        r.checked = loc == self.item;
        [rows addObject:r];
    }
    [self showOverlay:PXL(@"Sources") rows:rows];
}

- (void)didAppear {
    [super didAppear];
    [self reloadItem];   // full metadata (streams, cast, ratings) + fresh progress
}

- (void)play:(BOOL)resume {
    [self push:PXPlayerScreenNew(self.item, resume ? self.item.viewOffset : 0)];
}

- (void)closeOverlay { [_overlay close]; }

- (void)showOverlay:(NSString *)title rows:(NSArray *)rows {
    _overlay = [PXOverlay overlayInLayer:self.layer title:title rows:rows];
    __weak PXDetailScreen *weak = self;
    _overlay.onClose = ^{ PXDetailScreen *me = weak; if (!me) return; me->_overlay = nil; me->_buttons.active = me->_zone == PXZoneButtons; };
    _buttons.active = NO;
}

- (void)pickAudio {
    __weak PXDetailScreen *weak = self;
    [self showOverlay:PXL(@"Audio") rows:PXAudioRows(self.item, ^(NSInteger sid) {
        [weak closeOverlay];
        PXMarkTracksManual(weak.item.ratingKey);
        [weak.item.server selectStreamsForPart:weak.item.part audio:sid subtitle:-1 done:^(id j, NSError *e) { [weak reloadItem]; }];
    })];
}

- (void)pickSubtitle {
    __weak PXDetailScreen *weak = self;
    [self showOverlay:PXL(@"Sous-titres") rows:PXSubtitleRows(self.item, ^(NSInteger sid) {
        [weak closeOverlay];
        PXMarkTracksManual(weak.item.ratingKey);
        [weak.item.server selectStreamsForPart:weak.item.part audio:-1 subtitle:sid done:^(id j, NSError *e) { [weak reloadItem]; }];
    })];
}

- (void)toggleWatched {
    [[PXPlex shared] setWatched:!self.item.watched item:self.item.raw];
    __weak PXDetailScreen *weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [weak reloadItem]; });
}

- (BOOL)handleKey:(PXKey)key {
    if (_overlay) return [_overlay handleKey:key];
    NSArray *zones = [self zones];
    NSInteger zi = [zones indexOfObject:@(_zone)];
    switch (key) {
        case PXKeyLeft: case PXKeyRight: {
            NSInteger d = key == PXKeyLeft ? -1 : 1;
            if (_zone == PXZoneButtons) [_buttons moveBy:d];
            else if (_zone == PXZoneCast) [_cast moveBy:d];
            else if (_zone == PXZoneExtras) [_extras moveBy:d];
            else [_similar moveBy:d];
            return YES;
        }
        case PXKeyDown:
            if (zi != NSNotFound && zi + 1 < (NSInteger)zones.count) [self setZone:[zones[zi + 1] integerValue]];
            return YES;
        case PXKeyUp:
            if (zi != NSNotFound && zi > 0) [self setZone:[zones[zi - 1] integerValue]];
            return YES;
        case PXKeySelect:
            if (_zone == PXZoneButtons) [_buttons activate];
            else if (_zone == PXZoneSimilar && _similar.focusedItem) [self push:PXScreenForItem(_similar.focusedItem)];
            else if (_zone == PXZoneExtras && _extras.focusedItem) [self push:PXPlayerScreenNew(_extras.focusedItem, 0)];
            else if (_zone == PXZoneCast) [self openPerson];
            return YES;
        case PXKeyPlayPause:
            if (self.item.server.provider) return YES;   // nothing to play online
            [self play:self.item.viewOffset > 30];
            return YES;
        case PXKeyMenu:
            if (_zone != PXZoneButtons) { [self setZone:PXZoneButtons]; return YES; }
            return NO;
        default: return NO;
    }
}

@end

PXScreen *PXDetailScreenNew(PXItem *item) {
    PXDetailScreen *s = [PXDetailScreen new];
    s.item = item;
    [s setup];
    return s;
}
