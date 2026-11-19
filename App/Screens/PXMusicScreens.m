// Music: album page (cover, track list) and "now playing" screen.

#import "PXRouter.h"
#import "PXUI.h"
#import "PXListLayer.h"
#import "PXShelfLayer.h"
#import "PXOverlay.h"
#import "PXAmbientPlex.h"
#import "PXImageCache.h"
#import "PXPlex.h"
#import "PXServer.h"
#import "PXItem.h"
#import "PXMusicPlayer.h"
#import "PXLog.h"

static NSString *PXTrackClock(double s) {
    if (!isfinite(s) || s < 0) s = 0;
    long t = (long)s;
    return t >= 3600 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", t / 3600, (t / 60) % 60, t % 60]
                     : [NSString stringWithFormat:@"%ld:%02ld", t / 60, t % 60];
}

// Corners baked into the image (no masksToBounds: no offscreen pass);
// cornerRadius only rounds the placeholder color, which is free.
static CALayer *PXCover(PXItem *it, CGFloat size, CGFloat radius) {
    CALayer *l = [CALayer layer];
    l.bounds = CGRectMake(0, 0, size, size);
    l.cornerRadius = radius;
    l.backgroundColor = PXColorWhite(0.08);
    NSString *thumb = it.thumb ?: it.raw[@"parentThumb"];
    NSURL *u = thumb ? [it.server imageURL:thumb width:(int)size height:(int)size] : nil;
    if (u) [[PXImageCache shared] loadURL:u size:CGSizeMake(size, size) radius:radius done:^(CGImageRef img) {
        if (!img) return;
        PXFadeContents(l, 0.2);
        PXNoAnim(^{ l.contents = (__bridge id)img; l.backgroundColor = NULL; });
    }];
    return l;
}

#pragma mark - Now playing

@interface PXNowPlayingScreen : PXScreen
@end

static __weak PXScreen *gNowPlaying;
BOOL PXNowPlayingIsShown(void) { return gNowPlaying != nil; }

@implementation PXNowPlayingScreen {
    PXAmbientLayer *_ambient;
    CALayer *_cover;
    CATextLayer *_title, *_artist, *_album, *_elapsed, *_remaining, *_upNext, *_modes;
    CALayer *_bar, *_fill;
    NSString *_shownKey;
    CATextLayer *_lyricPrev, *_lyricNow, *_lyricNext;
    NSArray *_lyrics;            // {time (seconds, -1 if not synced), text}
    PXOverlay *_overlay;
}

- (void)setup {
    gNowPlaying = self;
    self.layer.backgroundColor = PXColorBackground();
    _ambient = [[PXAmbientLayer alloc] initWithFrame:self.layer.bounds style:PXAmbientBlurOnly];
    [self.layer addSublayer:_ambient];
    CGFloat x = 840;
    _title = PXText(PXFontHeavy(60), PXColorText());
    _title.frame = CGRectMake(x, 330, 960, 76);
    _artist = PXText(PXFontSemi(36), PXColorTextDim());
    _artist.frame = CGRectMake(x, 420, 960, 46);
    _album = PXText(PXFont(30), PXColorTextFaint());
    _album.frame = CGRectMake(x, 474, 960, 40);
    for (CATextLayer *t in @[ _title, _artist, _album ]) { t.truncationMode = kCATruncationEnd; [self.layer addSublayer:t]; }
    _bar = [CALayer layer];
    _bar.frame = CGRectMake(x, 600, 960, 8);
    _bar.cornerRadius = 4;
    _bar.backgroundColor = PXColorWhite(0.2);
    _fill = [CALayer layer];
    _fill.anchorPoint = CGPointZero;
    _fill.frame = CGRectMake(0, 0, 0, 8);
    _fill.cornerRadius = 4;
    _fill.backgroundColor = PXColorText();
    [_bar addSublayer:_fill];
    [self.layer addSublayer:_bar];
    _elapsed = PXText(PXFontMedium(26), PXColorTextDim());
    _elapsed.frame = CGRectMake(x, 624, 300, 34);
    _remaining = PXText(PXFontMedium(26), PXColorTextDim());
    _remaining.alignmentMode = kCAAlignmentRight;
    _remaining.frame = CGRectMake(x + 660, 624, 300, 34);
    _modes = PXText(PXFontMedium(26), PXColorAccent());
    _modes.frame = CGRectMake(x, 700, 960, 34);
    _upNext = PXText(PXFont(26), PXColorTextFaint());
    _upNext.frame = CGRectMake(x, 750, 960, 34);
    _upNext.truncationMode = kCATruncationEnd;
    for (CATextLayer *t in @[ _elapsed, _remaining, _modes, _upNext ]) [self.layer addSublayer:t];
    // Lyrics (Plex Pass servers): the current line between the previous and the next.
    _lyricPrev = PXText(PXFont(28), PXColorTextFaint());
    _lyricNow = PXText(PXFontSemi(34), PXColorText());
    _lyricNext = PXText(PXFont(28), PXColorTextFaint());
    CGFloat ly = 830;
    for (CATextLayer *t in @[ _lyricPrev, _lyricNow, _lyricNext ]) {
        t.frame = CGRectMake(x, ly, 960, 44);
        t.truncationMode = kCATruncationEnd;
        [self.layer addSublayer:t];
        ly += 50;
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:PXMusicDidChange object:nil];
    [self refresh];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)refresh {
    PXMusicPlayer *mp = [PXMusicPlayer shared];
    PXItem *t = mp.current;
    if (!t) { if ([self isOnTop]) [self pop]; return; }
    if (![t.uniqueKey isEqual:_shownKey]) {
        _shownKey = t.uniqueKey;
        [_cover removeFromSuperlayer];
        _cover = PXCover(t, 600, 12);
        _cover.position = CGPointMake(110 + 300, 540);
        [self.layer addSublayer:_cover];
        [_ambient showItem:t];
        [self loadLyrics:t];
        PXNoAnim(^{
            PXSetText(self->_title, t.title ?: @"");
            PXSetText(self->_artist, t.grandparentTitle ?: t.raw[@"originalTitle"] ?: @"");
            PXSetText(self->_album, t.raw[@"parentTitle"] ?: @"");
        });
    }
    double d = mp.duration, p = mp.elapsed;
    NSString *modes = [@[ mp.playing ? @"" : PXL(@"En pause"),
                          mp.shuffle ? PXL(@"Aléatoire") : @"",
                          mp.repeat == PXRepeatAll ? PXL(@"Répéter tout") : (mp.repeat == PXRepeatOne ? PXL(@"Répéter le titre") : @"") ]
                        componentsJoinedByString:@"   "];
    PXItem *next = mp.index + 1 < (NSInteger)mp.queue.count ? mp.queue[mp.index + 1] : nil;
    PXNoAnim(^{
        self->_fill.bounds = CGRectMake(0, 0, d > 0 ? 960 * MIN(1, p / d) : 0, 8);
        PXSetText(self->_elapsed, PXTrackClock(p));
        PXSetText(self->_remaining, [@"-" stringByAppendingString:PXTrackClock(MAX(0, d - p))]);
        PXSetText(self->_modes, [modes stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]);
        PXSetText(self->_upNext, next ? PXLF(@"À suivre : %@", next.title ?: @"") : @"");
    });
    [self showLyricsAt:p];
}

// Lyrics stream of the track (streamType 4), LRC ("[mm:ss.xx] line") or text.
- (void)loadLyrics:(PXItem *)t {
    _lyrics = nil;
    [self styleLyrics];
    [self showLyricsAt:0];
    NSString *key = t.uniqueKey;
    __weak PXNowPlayingScreen *weak = self;
    [t.server metadata:t.ratingKey done:^(NSDictionary *m, NSError *err) {
        PXItem *full = m ? [PXItem itemWithJSON:m] : nil;
        NSDictionary *stream = nil;
        for (NSDictionary *st in full.part[@"Stream"]) if ([st isKindOfClass:[NSDictionary class]] && [st[@"streamType"] intValue] == 4 && st[@"key"]) stream = st;
        if (!stream) return;
        [t.server getText:stream[@"key"] done:^(NSString *text) {
            PXNowPlayingScreen *me = weak;
            if (!me || !text.length || ![key isEqual:me->_shownKey]) return;
            me->_lyrics = [PXNowPlayingScreen parseLyrics:text];
            PXLog(@"music: %lu lyric lines for %@", (unsigned long)me->_lyrics.count, t.title);
            [me styleLyrics];
            [me showLyricsAt:[PXMusicPlayer shared].elapsed];
        }];
    }];
}

// LRC lines may carry several start tags ("[00:12.00][01:40.00] chorus"):
// one entry per tag, sorted by time. Without any tag: plain text (time -1).
+ (NSArray *)parseLyrics:(NSString *)text {
    NSMutableArray *timed = [NSMutableArray array], *plain = [NSMutableArray array];
    NSRegularExpression *tag = [NSRegularExpression regularExpressionWithPattern:@"^\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]" options:0 error:NULL];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSMutableArray *times = [NSMutableArray array];
        NSTextCheckingResult *r;
        while ((r = [tag firstMatchInString:line options:0 range:NSMakeRange(0, line.length)])) {
            [times addObject:@([[line substringWithRange:[r rangeAtIndex:1]] doubleValue] * 60 + [[line substringWithRange:[r rangeAtIndex:2]] doubleValue])];
            line = [[line substringFromIndex:r.range.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
        if (times.count) { for (NSNumber *sec in times) [timed addObject:@{ @"time": sec, @"text": line }]; }
        else if (line.length && ![line hasPrefix:@"["]) [plain addObject:@{ @"time": @(-1), @"text": line }];   // "[ar:…]" tags skipped
    }
    if (!timed.count) return plain;
    [timed sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"time"] compare:b[@"time"]]; }];
    return timed;
}

- (BOOL)lyricsSynced {
    return _lyrics.count && [_lyrics.firstObject[@"time"] doubleValue] >= 0;
}

// Synced: the current line stands out. Plain text: a fixed block of the
// first lines, all alike (no position to follow).
- (void)styleLyrics {
    BOOL synced = !_lyrics.count || [self lyricsSynced];
    PXNoAnim(^{ self->_lyricNow.foregroundColor = synced ? PXColorText() : PXColorTextFaint(); });
}

- (void)showLyricsAt:(double)t {
    NSString *prev = @"", *now = @"", *next = @"";
    if (_lyrics.count) {
        NSInteger i = 0;
        if ([self lyricsSynced]) {
            for (NSInteger k = 0; k < (NSInteger)_lyrics.count; k++) if ([_lyrics[k][@"time"] doubleValue] <= t) i = k;
            if (i > 0) prev = _lyrics[i - 1][@"text"];
            now = _lyrics[i][@"text"];
            if (i + 1 < (NSInteger)_lyrics.count) next = _lyrics[i + 1][@"text"];
        } else {
            prev = _lyrics[0][@"text"];
            if (_lyrics.count > 1) now = _lyrics[1][@"text"];
            if (_lyrics.count > 2) next = _lyrics[2][@"text"];
        }
    }
    PXNoAnim(^{ PXSetText(self->_lyricPrev, prev); PXSetText(self->_lyricNow, now); PXSetText(self->_lyricNext, next); });
}

- (void)showOptions {
    PXMusicPlayer *mp = [PXMusicPlayer shared];
    __weak PXNowPlayingScreen *weak = self;
    PXListRow *shuffle = [PXListRow title:PXL(@"Aléatoire") value:mp.shuffle ? PXL(@"Oui") : PXL(@"Non") action:^{
        mp.shuffle = !mp.shuffle; [weak closeOverlay];
    }];
    NSString *rep = mp.repeat == PXRepeatAll ? PXL(@"Tout") : (mp.repeat == PXRepeatOne ? PXL(@"Ce titre") : PXL(@"Non"));
    PXListRow *repeat = [PXListRow title:PXL(@"Répéter") value:rep action:^{
        mp.repeat = (mp.repeat + 1) % 3; [weak closeOverlay];
    }];
    PXListRow *stop = [PXListRow title:PXL(@"Arrêter la lecture") value:@"" action:^{ [weak closeOverlay]; [mp stop]; }];
    _overlay = [PXOverlay overlayInLayer:self.layer title:PXL(@"Options") rows:@[ shuffle, repeat, stop ]];
    _overlay.onClose = ^{ PXNowPlayingScreen *me = weak; if (me) me->_overlay = nil; };
}

- (void)closeOverlay { [_overlay close]; }

- (BOOL)handleKey:(PXKey)key {
    if (_overlay) return [_overlay handleKey:key];
    PXMusicPlayer *mp = [PXMusicPlayer shared];
    switch (key) {
        case PXKeySelect: case PXKeyPlayPause: [mp togglePause]; return YES;
        case PXKeyRight: case PXKeyFastForward: [mp next]; return YES;
        case PXKeyLeft: case PXKeyRewind: [mp previous]; return YES;
        case PXKeyUp: mp.volume = roundf((mp.volume + 0.1) * 10) / 10; return YES;
        case PXKeyDown: mp.volume = roundf((mp.volume - 0.1) * 10) / 10; return YES;
        case PXKeySelectHold: case PXKeyPlayPauseHold: [self showOptions]; return YES;
        default: return NO;   // Menu: back, the music goes on
    }
}

@end

PXScreen *PXNowPlayingScreenNew(void) {
    PXNowPlayingScreen *s = [PXNowPlayingScreen new];
    [s setup];
    return s;
}

#pragma mark - Album

@interface PXAlbumScreen : PXScreen
@property (nonatomic, strong) PXItem *album;
@end

@implementation PXAlbumScreen {
    PXListLayer *_list;
    NSArray *_tracks;
    NSString *_markedKey;      // track shown with ✓
    BOOL _needsRows;           // track changed while covered: rebuilt on return
}

- (void)setup {
    self.layer.backgroundColor = PXColorBackground();
    PXAmbientLayer *ambient = [[PXAmbientLayer alloc] initWithFrame:self.layer.bounds style:PXAmbientBlurOnly];
    [self.layer addSublayer:ambient];
    [ambient showItem:self.album];
    CALayer *cover = PXCover(self.album, 520, 12);
    cover.position = CGPointMake(110 + 260, 120 + 260);
    [self.layer addSublayer:cover];
    PXItem *a = self.album;
    [self.layer addSublayer:PXAsyncLabel(a.title ?: @"", PXFontHeavy(52), PXColorText(), CGRectMake(110, 680, 520, 130), 2, NO)];
    NSString *artist = a.raw[@"parentTitle"] ?: @"";
    NSString *year = a.year ? [@(a.year) stringValue] : @"";
    [self.layer addSublayer:PXAsyncLabel([@[ artist, year ] componentsJoinedByString:a.year && artist.length ? @" · " : @""],
                                         PXFontSemi(30), PXColorTextDim(), CGRectMake(110, 820, 520, 40), 1, NO)];
    _list = [[PXListLayer alloc] initWithFrame:CGRectMake(720, 120, 1090, 880) rowHeight:72];
    [self.layer addSublayer:_list];
    _list.rows = @[ [PXListRow title:PXL(@"Chargement…") value:@"" action:nil] ];
    __weak PXAlbumScreen *weak = self;
    [a.server get:[NSString stringWithFormat:@"/library/metadata/%@/children", a.ratingKey] done:^(NSDictionary *mc, NSError *err) {
        PXAlbumScreen *me = weak;
        if (!me) return;
        me->_tracks = [PXItem itemsWithJSON:mc[@"Metadata"]];
        [me buildRows];
    }];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(musicChanged) name:PXMusicDidChange object:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)buildRows {
    __weak PXAlbumScreen *weak = self;
    NSMutableArray *rows = [NSMutableArray array];
    if (_tracks.count) {
        [rows addObject:[PXListRow title:PXL(@"Tout lire") value:@"" action:^{ [weak playFrom:0 shuffle:NO]; }]];
        [rows addObject:[PXListRow title:PXL(@"Aléatoire") value:@"" action:^{ [weak playFrom:0 shuffle:YES]; }]];
    }
    PXItem *playing = [PXMusicPlayer shared].current;
    _markedKey = playing.uniqueKey;
    _needsRows = NO;
    for (NSInteger i = 0; i < (NSInteger)_tracks.count; i++) {
        PXItem *t = _tracks[i];
        NSString *title = t.index ? [NSString stringWithFormat:@"%ld.  %@", (long)t.index, t.title ?: @""] : (t.title ?: @"");
        PXListRow *r = [PXListRow title:title value:PXTrackClock(t.duration) action:^{ [weak playFrom:i shuffle:NO]; }];
        r.checked = [t.uniqueKey isEqual:playing.uniqueKey];
        [rows addObject:r];
    }
    if (!rows.count) [rows addObject:[PXListRow title:PXL(@"Aucun titre") value:@"" action:nil]];
    NSInteger focus = _list.focusIndex;
    _list.rows = rows;
    _list.focusIndex = MIN(focus, (NSInteger)rows.count - 1);
}

// Row of a track in the list (after "Tout lire" and "Aléatoire"), NSNotFound if none.
- (NSUInteger)rowOfTrack:(NSString *)key {
    NSUInteger i = key ? [_tracks indexOfObjectPassingTest:^BOOL(PXItem *t, NSUInteger n, BOOL *stop) { return [t.uniqueKey isEqual:key]; }] : NSNotFound;
    return i == NSNotFound ? NSNotFound : i + 2;
}

- (void)musicChanged {
    // Only the ✓ of the track being played changes.
    NSString *k = [PXMusicPlayer shared].current.uniqueKey;
    if ([k isEqual:_markedKey] || (!k && !_markedKey)) return;
    if (!_tracks.count) { _markedKey = k; return; }   // rows not built yet: they will read it
    if (![self isOnTop]) { _needsRows = YES; return; }
    NSUInteger was = [self rowOfTrack:_markedKey], now = [self rowOfTrack:k];
    _markedKey = k;
    if (was != NSNotFound) [_list setChecked:NO atIndex:was];
    if (now != NSNotFound) [_list setChecked:YES atIndex:now];
}

- (void)didAppear {
    [super didAppear];
    if (_needsRows) [self buildRows];
}

- (void)playFrom:(NSInteger)i shuffle:(BOOL)shuffle {
    if (!_tracks.count) return;   // still loading
    [[PXMusicPlayer shared] playTracks:_tracks startAt:i shuffle:shuffle];
    [self push:PXNowPlayingScreenNew()];
}

- (void)focusChanged { _list.active = self.hasFocus; }

- (BOOL)handleKey:(PXKey)key {
    switch (key) {
        case PXKeyUp: [_list handleUp]; return YES;
        case PXKeyDown: [_list handleDown]; return YES;
        case PXKeySelect: [_list activate]; return YES;
        case PXKeyPlayPause:
            if ([PXMusicPlayer shared].active) [self push:PXNowPlayingScreenNew()];
            else [self playFrom:0 shuffle:NO];
            return YES;
        default: return NO;
    }
}

@end

PXScreen *PXAlbumScreenNew(PXItem *album) {
    PXAlbumScreen *s = [PXAlbumScreen new];
    s.album = album;
    [s setup];
    return s;
}

#pragma mark - Artist

// Artist page: photo, name and biography, albums, most played tracks.
@interface PXArtistScreen : PXScreen
@property (nonatomic, strong) PXItem *artist;
@end

@implementation PXArtistScreen {
    PXAmbientLayer *_ambient;
    CALayer *_rows;
    NSMutableArray *_shelves;
    NSInteger _index;
}

- (void)setup {
    self.layer.backgroundColor = PXColorBackground();
    _ambient = [[PXAmbientLayer alloc] initWithFrame:self.layer.bounds style:PXAmbientBlurOnly];
    [self.layer addSublayer:_ambient];
    [_ambient showItem:self.artist];
    CALayer *photo = PXCover(self.artist, 260, 130);
    photo.position = CGPointMake(110 + 130, 70 + 130);
    [self.layer addSublayer:photo];
    [self.layer addSublayer:PXAsyncLabel(self.artist.title ?: @"", PXFontHeavy(64), PXColorText(), CGRectMake(420, 80, 1400, 80), 1, NO)];
    _rows = [CALayer layer];
    _rows.anchorPoint = CGPointZero;
    _rows.position = CGPointMake(0, 380);
    [self.layer addSublayer:_rows];
    _shelves = [NSMutableArray array];
    PXServer *sv = self.artist.server;
    __weak PXArtistScreen *weak = self;
    // Biography (full metadata), then the albums and the most played tracks.
    [sv metadata:self.artist.ratingKey done:^(NSDictionary *m, NSError *err) {
        PXArtistScreen *me = weak;
        NSString *bio = [m[@"summary"] isKindOfClass:[NSString class]] ? m[@"summary"] : nil;
        if (me && bio.length) [me.layer addSublayer:PXAsyncLabel(bio, PXFont(26), PXColorWhite(0.8), CGRectMake(420, 175, 1380, 140), 4, NO)];
        NSString *sid = [m[@"librarySectionID"] description] ?: me.artist.librarySectionID;
        if (!me || !sid.length) return;
        NSString *path = [NSString stringWithFormat:@"/library/sections/%@/all?type=10&artist.id=%@&sort=viewCount:desc&X-Plex-Container-Size=20", sid, me.artist.ratingKey];
        [sv get:path done:^(NSDictionary *mc, NSError *e2) {
            [weak addRow:PXL(@"Titres populaires") items:[PXItem itemsWithJSON:mc[@"Metadata"]] at:1];
        }];
    }];
    [sv get:[NSString stringWithFormat:@"/library/metadata/%@/children", self.artist.ratingKey] done:^(NSDictionary *mc, NSError *err) {
        [weak addRow:PXL(@"Albums") items:[PXItem itemsWithJSON:mc[@"Metadata"]] at:0];
    }];
}

- (void)addRow:(NSString *)title items:(NSArray *)items at:(NSInteger)order {
    if (!items.count) return;
    PXShelfLayer *s = [[PXShelfLayer alloc] initWithTitle:title width:1920 imageSize:CGSizeMake(220, 220) artwork:PXArtworkPoster];
    s.items = items;
    [s setValue:@(order) forKey:@"pxOrder"];
    [_shelves addObject:s];
    [_shelves sortUsingComparator:^NSComparisonResult(CALayer *a, CALayer *b) { return [[a valueForKey:@"pxOrder"] compare:[b valueForKey:@"pxOrder"]]; }];
    CGFloat y = 0;
    for (PXShelfLayer *sh in _shelves) {
        PXNoAnim(^{ sh.position = CGPointMake(0, y); if (!sh.superlayer) [self->_rows addSublayer:sh]; });
        y += sh.height + 20;
    }
    [self updateFocus];
}

- (void)updateFocus {
    for (NSInteger i = 0; i < (NSInteger)_shelves.count; i++) [_shelves[i] setActive:self.hasFocus && i == _index];
    if (_index >= (NSInteger)_shelves.count) return;
    CGFloat y = 380 - [_shelves[_index] position].y;
    PXAnim(0.3, ^{ self->_rows.position = CGPointMake(0, y); });
}

- (void)focusChanged { [self updateFocus]; }

- (BOOL)handleKey:(PXKey)key {
    if (!_shelves.count) return NO;
    PXShelfLayer *s = _shelves[_index];
    switch (key) {
        case PXKeyLeft: case PXKeyRight: [s moveBy:key == PXKeyLeft ? -1 : 1]; return YES;
        case PXKeyDown: if (_index + 1 < (NSInteger)_shelves.count) { _index++; [self updateFocus]; } return YES;
        case PXKeyUp: if (_index > 0) { _index--; [self updateFocus]; } return YES;
        case PXKeySelect: case PXKeyPlayPause: {
            PXItem *it = s.focusedItem;
            if (!it) return YES;
            if (it.type == PXItemTrack) {   // the list from this track on
                NSInteger i = [s.items indexOfObject:it];
                [[PXMusicPlayer shared] playTracks:s.items startAt:MAX(0, i) shuffle:NO];
                [self push:PXNowPlayingScreenNew()];
            } else [self push:PXScreenForItem(it)];
            return YES;
        }
        default: return NO;
    }
}

@end

PXScreen *PXArtistScreenNew(PXItem *artist) {
    PXArtistScreen *s = [PXArtistScreen new];
    s.artist = artist;
    [s setup];
    return s;
}
