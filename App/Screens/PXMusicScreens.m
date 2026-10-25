// Music: album page (cover, track list) and "now playing" screen.

#import "PXRouter.h"
#import "PXUI.h"
#import "PXListLayer.h"
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

static CALayer *PXCover(PXItem *it, CGFloat size) {
    CALayer *l = [CALayer layer];
    l.bounds = CGRectMake(0, 0, size, size);
    l.cornerRadius = 12;
    l.masksToBounds = YES;
    l.backgroundColor = PXColorWhite(0.08);
    l.contentsGravity = kCAGravityResizeAspectFill;
    NSString *thumb = it.thumb ?: it.raw[@"parentThumb"];
    NSURL *u = thumb ? [it.server imageURL:thumb width:(int)size height:(int)size] : nil;
    if (u) [[PXImageCache shared] loadURL:u size:CGSizeMake(size, size) done:^(CGImageRef img) {
        if (img) { l.contents = (__bridge id)img; PXFadeContents(l, 0.2); }
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
        _cover = PXCover(t, 600);
        _cover.position = CGPointMake(110 + 300, 540);
        [self.layer addSublayer:_cover];
        [_ambient showItem:t];
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
}

- (void)setup {
    self.layer.backgroundColor = PXColorBackground();
    PXAmbientLayer *ambient = [[PXAmbientLayer alloc] initWithFrame:self.layer.bounds style:PXAmbientBlurOnly];
    [self.layer addSublayer:ambient];
    [ambient showItem:self.album];
    CALayer *cover = PXCover(self.album, 520);
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

- (void)musicChanged {
    // Only the ✓ of the track being played: rebuild when the track changes.
    NSString *k = [PXMusicPlayer shared].current.uniqueKey;
    if ([k isEqual:_markedKey] || (!k && !_markedKey)) return;
    _markedKey = k;
    [self buildRows];
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
