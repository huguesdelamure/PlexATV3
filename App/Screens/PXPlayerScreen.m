// Video player: AVPlayer (hardware H.264) + on-screen display.
//
// Keys while playing:
//   select / play-pause  pause (shows the OSD) / resume
//   left / right         skip -10 s / +30 s (OSD hidden), scrub (OSD shown or paused)
//   up                   audio & subtitles      down  chapters
//   menu                 close panel > cancel scrub > hide OSD > stop
// Reports the timeline to the server, stops the transcode on exit, chains
// to the next episode with a countdown.

#import <AVFoundation/AVFoundation.h>
#import "PXServer.h"
#import "PXRouter.h"
#import "PXMusicPlayer.h"
#import "PXUI.h"
#import "PXOverlay.h"
#import "PXTracks.h"
#import "PXImageCache.h"
#import "PXPlex.h"
#import "PXItem.h"
#import "PXLog.h"
#import "PXBif.h"
#import "PXSettings.h"
#import "PXTrackPrefs.h"

static const CGFloat kBarX = 110, kBarW = 1700, kBarY = 968;
static const CGSize kPreview = { 384, 216 };

@interface PXPlayerScreen : PXScreen
@property (nonatomic, strong) PXItem *item;
@property (nonatomic, assign) double startOffset;
@property (nonatomic, copy) NSArray *queue;     // PXItem to play after this one (shuffle), else next episode
- (BOOL)pxPlaying;
@end

@implementation PXPlayerScreen {
    AVPlayer *_player;
    AVPlayerLayer *_videoLayer;
    NSString *_session;
    BOOL _directPlay;
    dispatch_source_t _timer;
    id _endObserver, _stallObserver;

    // OSD
    CALayer *_osd;
    CATextLayer *_title, *_subtitle, *_elapsed, *_remaining, *_mode, *_center, *_scrubTime, *_clock, *_endsAt;
    CALayer *_barBack, *_barBuffered, *_barPlayed, *_knob;
    CALayer *_bubble, *_previewImage;     // scrub bubble: thumbnail + time
    CALayer *_spinner;
    CALayer *_backdrop;             // title artwork while the stream starts
    CALayer *_pauseBadge;           // centred pause glyph while paused by the user
    CALayer *_skipButton;                 // "Passer l'intro / le générique"
    CATextLayer *_skipText;
    NSDictionary *_activeMarker;
    PXBif *_bif;
    // Software volume (the Apple TV 3 has no volume control of its own).
    CALayer *_volumeHUD, *_volumeFill;
    CATextLayer *_volumeText;
    NSDate *_volumeShownAt;
    NSDate *_osdShownAt;
    BOOL _osdVisible;

    // Scrubbing
    BOOL _scrubbing;
    double _scrubPos, _scrubStep;
    NSDate *_lastScrubKey;

    // State
    PXOverlay *_overlay;
    BOOL _failed, _ended, _gone, _readyOnce;
    BOOL _userPausedFlag;           // paused by the user (not buffering)
    BOOL _prefsApplied;             // automatic track choice done for this title
    double _pendingSeek;            // seek requested before the stream was ready (-1 = none)
    NSDate *_lastDiag;
    NSUInteger _errorsLogged;
    double _lastKnownPos;
    NSString *_lastState;
    NSDate *_lastReport;

    // Next episode
    PXItem *_next;
    CALayer *_nextPanel;
    CATextLayer *_nextText;
    int _countdown;
}

#pragma mark - Setup

static __weak PXPlayerScreen *gCurrentPlayer;   // for remote control (Companion)

- (void)setup {
    [[PXMusicPlayer shared] stop];   // one player at a time
    gCurrentPlayer = self;
    self.layer.backgroundColor = [UIColor blackColor].CGColor;
    _backdrop = [CALayer layer];
    _backdrop.frame = self.layer.bounds;
    _backdrop.contentsGravity = kCAGravityResizeAspectFill;
    _backdrop.opacity = 0;
    [self.layer addSublayer:_backdrop];
    _videoLayer = [AVPlayerLayer layer];
    _videoLayer.frame = self.layer.bounds;
    _videoLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    [self.layer addSublayer:_videoLayer];

    _center = PXText(PXFontMedium(34), PXColorText());
    _center.alignmentMode = kCAAlignmentCenter;
    _center.wrapped = YES;
    _center.frame = CGRectMake(260, 600, 1400, 120);
    [self.layer addSublayer:_center];
    _spinner = PXSpinner(70);
    _spinner.position = CGPointMake(960, 540);
    [self.layer addSublayer:_spinner];

    _pauseBadge = [CALayer layer];
    _pauseBadge.bounds = CGRectMake(0, 0, 132, 132);
    _pauseBadge.position = CGPointMake(960, 540);
    _pauseBadge.cornerRadius = 66;
    _pauseBadge.backgroundColor = PXColorBlack(0.5);
    CAShapeLayer *pauseIcon = PXIconLayer(PXIconPause, 56, PXColorText());
    pauseIcon.position = CGPointMake(38, 38);
    [_pauseBadge addSublayer:pauseIcon];
    _pauseBadge.opacity = 0;
    [self.layer addSublayer:_pauseBadge];

    _osd = [CALayer layer];
    _osd.frame = self.layer.bounds;
    [self.layer addSublayer:_osd];
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = CGRectMake(0, 1080 - 420, 1920, 420);
    g.colors = @[ (__bridge id)PXColorBlack(0), (__bridge id)PXColorBlack(0.55), (__bridge id)PXColorBlack(0.9) ];
    g.locations = @[ @0, @0.45, @1 ];
    [_osd addSublayer:g];
    CAGradientLayer *gt = [CAGradientLayer layer];
    gt.frame = CGRectMake(0, 0, 1920, 220);
    gt.colors = @[ (__bridge id)PXColorBlack(0.65), (__bridge id)PXColorBlack(0) ];
    [_osd addSublayer:gt];

    _clock = PXText(PXFontMedium(32), PXColorText());
    _clock.alignmentMode = kCAAlignmentRight;
    _clock.frame = CGRectMake(1500, 52, 320, 44);
    _title = PXText(PXFontHeavy(48), PXColorText());
    _title.frame = CGRectMake(kBarX, 812, 1300, 60);
    _subtitle = PXText(PXFontMedium(28), PXColorTextDim());
    _subtitle.frame = CGRectMake(kBarX, 874, 1300, 38);
    _mode = PXText(PXFont(22), PXColorTextFaint());
    _mode.alignmentMode = kCAAlignmentRight;
    _mode.frame = CGRectMake(kBarX + kBarW - 800, 882, 800, 30);

    _barBack = [CALayer layer];
    _barBack.frame = CGRectMake(kBarX, kBarY, kBarW, 8);
    _barBack.backgroundColor = PXColorWhite(0.18);
    _barBack.cornerRadius = 4;
    _barBuffered = [CALayer layer];
    _barBuffered.backgroundColor = PXColorWhite(0.32);
    _barPlayed = [CALayer layer];
    _barPlayed.backgroundColor = PXColorText();
    for (CALayer *l in @[ _barBuffered, _barPlayed ]) {
        l.anchorPoint = CGPointZero; l.bounds = CGRectMake(0, 0, 0, 8); l.position = CGPointZero; l.cornerRadius = 4;
        [_barBack addSublayer:l];
    }
    _knob = [CALayer layer];
    _knob.bounds = CGRectMake(0, 0, 26, 26);
    _knob.cornerRadius = 13;
    _knob.backgroundColor = PXColorText();
    _knob.shadowColor = [UIColor blackColor].CGColor;
    _knob.shadowOpacity = 0.6;
    _knob.shadowRadius = 6;
    _knob.shadowOffset = CGSizeMake(0, 2);
    _knob.shadowPath = [UIBezierPath bezierPathWithOvalInRect:_knob.bounds].CGPath;

    // Scrub bubble: preview thumbnail (BIF) with the target time under it.
    _bubble = [CALayer layer];
    _bubble.bounds = CGRectMake(0, 0, kPreview.width + 12, kPreview.height + 62);
    _bubble.backgroundColor = PXColorBlack(0.75);
    _bubble.cornerRadius = 14;
    _bubble.borderColor = PXColorWhite(0.25);
    _bubble.borderWidth = 2;
    _previewImage = [CALayer layer];
    _previewImage.frame = CGRectMake(6, 6, kPreview.width, kPreview.height);
    _previewImage.cornerRadius = 9;
    _previewImage.backgroundColor = PXColorWhite(0.08);
    _previewImage.contentsGravity = kCAGravityResizeAspectFill;
    _previewImage.masksToBounds = YES;
    [_bubble addSublayer:_previewImage];
    _scrubTime = PXText(PXFontBold(32), PXColorText());
    _scrubTime.alignmentMode = kCAAlignmentCenter;
    _scrubTime.frame = CGRectMake(0, kPreview.height + 14, kPreview.width + 12, 42);
    [_bubble addSublayer:_scrubTime];

    _elapsed = PXText(PXFontSemi(26), PXColorText());
    _elapsed.frame = CGRectMake(kBarX, kBarY + 26, 400, 34);
    _remaining = PXText(PXFontSemi(26), PXColorTextDim());
    _remaining.alignmentMode = kCAAlignmentRight;
    _remaining.frame = CGRectMake(kBarX + kBarW - 400, kBarY + 26, 400, 34);
    _endsAt = PXText(PXFont(26), PXColorTextFaint());
    _endsAt.alignmentMode = kCAAlignmentCenter;
    _endsAt.frame = CGRectMake(kBarX + kBarW / 2 - 300, kBarY + 26, 600, 34);
    for (CALayer *l in @[ _clock, _title, _subtitle, _mode, _barBack, _knob, _bubble, _elapsed, _remaining, _endsAt ]) [_osd addSublayer:l];
    _knob.hidden = _bubble.hidden = YES;

    // Skip intro / credits: visible even when the OSD is hidden.
    _skipButton = [CALayer layer];
    _skipButton.frame = CGRectMake(1920 - 110 - 420, 1080 - 220, 420, 76);
    _skipButton.cornerRadius = 38;
    _skipButton.backgroundColor = PXColorText();
    _skipButton.shadowColor = [UIColor blackColor].CGColor;
    _skipButton.shadowOpacity = 0.5;
    _skipButton.shadowRadius = 16;
    _skipButton.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_skipButton.bounds cornerRadius:38].CGPath;
    CAShapeLayer *skipIcon = PXIconLayer(PXIconNext, 30, PXColorBlack(0.9));
    skipIcon.position = CGPointMake(34, 23);
    [_skipButton addSublayer:skipIcon];
    _skipText = PXText(PXFontSemi(28), PXColorBlack(0.9));
    _skipText.frame = CGRectMake(80, (76 - PXFontSemi(28).lineHeight) / 2 - 1, 320, 38);
    [_skipButton addSublayer:_skipText];
    _skipButton.opacity = 0;
    _skipButton.zPosition = 40;
    [self.layer addSublayer:_skipButton];

    // Volume HUD (top right): speaker icon, bar, percentage.
    _volumeHUD = [CALayer layer];
    _volumeHUD.frame = CGRectMake(1920 - 110 - 420, 56, 420, 76);
    _volumeHUD.cornerRadius = 38;
    _volumeHUD.backgroundColor = [UIColor colorWithRed:0.07 green:0.075 blue:0.09 alpha:0.88].CGColor;
    _volumeHUD.zPosition = 60;
    _volumeHUD.opacity = 0;
    CAShapeLayer *spk = PXIconLayer(PXIconAudio, 34, PXColorText());
    spk.position = CGPointMake(28, 21);
    [_volumeHUD addSublayer:spk];
    CALayer *track = [CALayer layer];
    track.frame = CGRectMake(84, 33, 196, 10);
    track.cornerRadius = 5;
    track.backgroundColor = PXColorWhite(0.22);
    _volumeFill = [CALayer layer];
    _volumeFill.anchorPoint = CGPointZero;
    _volumeFill.position = CGPointZero;
    _volumeFill.cornerRadius = 5;
    _volumeFill.backgroundColor = PXColorText();
    [track addSublayer:_volumeFill];
    [_volumeHUD addSublayer:track];
    _volumeText = PXText(PXFontSemi(26), PXColorText());
    _volumeText.alignmentMode = kCAAlignmentRight;
    _volumeText.frame = CGRectMake(290, (76 - PXFontSemi(26).lineHeight) / 2 - 1, 106, 34);
    [_volumeHUD addSublayer:_volumeText];
    [self.layer addSublayer:_volumeHUD];

    [self renderTitles];
    [self showOSD:YES];
    PXSetText(_center, @"");

    __weak PXPlayerScreen *weak = self;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_timer, ^{ [weak tick]; });
    dispatch_resume(_timer);

    // Hub/list items lack Media/Part/Stream: fetch full metadata first.
    [self loadItemThenStartAt:self.startOffset];
}

- (void)renderTitles {
    PXItem *it = self.item;
    [self loadBackdrop];
    if (it.type == PXItemEpisode) {
        PXSetText(_title, it.grandparentTitle ?: it.title);
        PXSetText(_subtitle, [NSString stringWithFormat:@"%@ · %@", it.episodeCode, it.title]);
    } else {
        PXSetText(_title, it.title);
        PXSetText(_subtitle, it.year ? [@(it.year) stringValue] : @"");
    }
}

// Dimmed artwork behind the spinner instead of a black screen; removed as
// soon as the video is ready (it would show in the letterbox bars).
- (void)loadBackdrop {
    if (_readyOnce || _backdrop.contents) return;
    NSString *art = self.item.art;
    NSURL *url = art ? [self.item.server artURL:art width:1280 height:720 blur:0] : nil;
    if (!url) return;
    __weak PXPlayerScreen *weak = self;
    [[PXImageCache shared] loadURL:url size:CGSizeMake(1280, 720) radius:0 done:^(CGImageRef img) {
        PXPlayerScreen *me = weak;
        if (!me || !img || me->_readyOnce) return;
        PXNoAnim(^{ me->_backdrop.contents = (__bridge id)img; });
        PXAnim(0.5, ^{ me->_backdrop.opacity = 0.4; });
    }];
}

- (void)loadItemThenStartAt:(double)offset {
    __weak PXPlayerScreen *weak = self;
    [self.item.server metadata:self.item.ratingKey done:^(NSDictionary *m, NSError *err) {
        PXPlayerScreen *me = weak;
        if (!me || me->_gone) return;
        if (!m) { [me fail:err.localizedDescription ?: PXL(@"Métadonnées indisponibles")]; return; }
        me.item = [PXItem itemWithJSON:m];
        [me renderTitles];
        double start = offset < 0 ? (me.item.viewOffset > 30 ? me.item.viewOffset : 0) : offset;
        // First load: apply the preferred audio / subtitle languages.
        if (!me->_prefsApplied) {
            me->_prefsApplied = YES;
            PXApplyTrackPreferences(me.item, ^(BOOL changed) {
                if (changed) [weak loadItemThenStartAt:start];
                else [weak startAt:start];
            });
            return;
        }
        [me startAt:start];
    }];
}

#pragma mark - Playback session

- (void)startAt:(double)offset {
    [self stopSession];
    _lastKnownPos = offset;
    __weak PXPlayerScreen *weak = self;
    [[PXPlex shared] preparePlayback:self.item.raw offset:offset done:^(NSDictionary *pb, NSError *err) {
        PXPlayerScreen *me = weak;
        if (!me || me->_gone) return;
        if (!pb) { [me fail:err.localizedDescription ?: PXL(@"Le serveur refuse la lecture")]; return; }
        [me startWithPlayback:pb offset:offset];
    }];
}

- (void)startWithPlayback:(NSDictionary *)pb offset:(double)offset {
    _session = pb[@"session"];
    _directPlay = [pb[@"directPlay"] boolValue];
    _failed = _ended = NO;
    _readyOnce = NO;
    _pendingSeek = -1;
    _errorsLogged = 0;
    _lastKnownPos = offset;
    PXLog(@"player: '%@' %@ at %.0f s (version %ld)", self.item.title, _directPlay ? @"DIRECT PLAY" : @"TRANSCODE", offset, (long)self.item.mediaIndex);
    PXSetText(_mode, [NSString stringWithFormat:@"%@ · %@", self.item.mediaSummary, pb[@"mode"] ?: @""]);

    AVPlayerItem *pi = [AVPlayerItem playerItemWithURL:pb[@"url"]];
    if (!_player) {
        _player = [AVPlayer playerWithPlayerItem:pi];
        _player.volume = [self storedVolume];
        _videoLayer.player = _player;
    } else {
        [_player replaceCurrentItemWithPlayerItem:pi];
    }
    // A transcode started at offset N is timestamped from N (measured), a
    // direct play starts at 0: seek once ready.
    if (_directPlay && offset > 1) [pi seekToTime:CMTimeMakeWithSeconds(offset, 600)];
    if (_endObserver) [[NSNotificationCenter defaultCenter] removeObserver:_endObserver];
    __weak PXPlayerScreen *weak = self;
    _endObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:pi
                                                                      queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        [weak didReachEnd];
    }];
    if (_stallObserver) [[NSNotificationCenter defaultCenter] removeObserver:_stallObserver];
    _stallObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemPlaybackStalledNotification object:pi
                                                                        queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        PXLog(@"player: STALLED");
    }];
    [_player play];
}

- (void)stopSession {
    if (_session) [self.item.server stopTranscode:_session];
    _session = nil;
}

- (double)position {
    double p = CMTimeGetSeconds(_player.currentTime);
    if (isnan(p) || (!_readyOnce && p < 0.5)) return _lastKnownPos;
    return p;
}

- (double)duration {
    if (self.item.duration > 0) return self.item.duration;
    double d = CMTimeGetSeconds(_player.currentItem.duration);
    return isnan(d) ? 0 : d;
}

- (void)report:(NSString *)state {
    if (!self.item.ratingKey || !_readyOnce) return;
    [[PXPlex shared] reportTimeline:self.item.raw state:state timeMs:(long long)([self position] * 1000)];
    _lastReport = [NSDate date];
}

- (void)fail:(NSString *)message {
    _failed = YES;
    PXLog(@"player: FAILED %@", message);
    PXSetText(_center, PXLF(@"Lecture impossible\n%@", message));
    PXNoAnim(^{ self->_spinner.hidden = YES; });
    [self showOSD:YES];
}

#pragma mark - Diagnostics

- (void)logDiagnostics {
    AVPlayerItem *pi = _player.currentItem;
    NSMutableArray *ranges = [NSMutableArray array];
    for (NSValue *v in pi.loadedTimeRanges) {
        CMTimeRange r = v.CMTimeRangeValue;
        [ranges addObject:[NSString stringWithFormat:@"%.0f-%.0f", CMTimeGetSeconds(r.start), CMTimeGetSeconds(CMTimeRangeGetEnd(r))]];
    }
    AVPlayerItemAccessLogEvent *ev = pi.accessLog.events.lastObject;
    // Rendered video frame rate and dropped frames: tells a smooth output
    // from a struggling decoder, independently of any capture device.
    float fps = 0;
    for (AVPlayerItemTrack *t in pi.tracks)
        if ([t.assetTrack.mediaType isEqualToString:AVMediaTypeVideo]) fps = t.currentVideoFrameRate;
    NSInteger dropped = 0;
    for (AVPlayerItemAccessLogEvent *e in pi.accessLog.events) if (e.numberOfDroppedVideoFrames > 0) dropped += e.numberOfDroppedVideoFrames;
    PXLog(@"player: diag t=%.1f rate=%.1f fps=%.2f dropped=%ld stalls=%ld keepUp=%d ranges=[%@] bitrate=%.0f observed=%.0f status=%ld",
          CMTimeGetSeconds(_player.currentTime), _player.rate, fps, (long)dropped, (long)ev.numberOfStalls, pi.playbackLikelyToKeepUp,
          [ranges componentsJoinedByString:@","], ev.indicatedBitrate, ev.observedBitrate, (long)pi.status);
    NSUInteger n = pi.errorLog.events.count;
    if (n > _errorsLogged) {
        for (NSUInteger i = _errorsLogged; i < n; i++) {
            AVPlayerItemErrorLogEvent *e = pi.errorLog.events[i];
            PXLog(@"player: hls error %ld %@ %@ uri=%@", (long)e.errorStatusCode, e.errorDomain, e.errorComment,
                  [e.URI componentsSeparatedByString:@"?"].firstObject);
        }
        _errorsLogged = n;
    }
}

#pragma mark - Tick

- (void)tick {
    AVPlayerItem *pi = _player.currentItem;
    if (!_failed && (pi.status == AVPlayerItemStatusFailed || _player.status == AVPlayerStatusFailed)) {
        [self fail:(pi.error ?: _player.error).localizedDescription ?: PXL(@"erreur inconnue")];
        return;
    }
    if (pi.status == AVPlayerItemStatusReadyToPlay && !_readyOnce) {
        _readyOnce = YES;
        PXAnim(0.4, ^{ self->_backdrop.opacity = 0; });
        // Scrub thumbnails: fetched once playback runs (does not delay startup).
        if ([self.item.part[@"indexes"] isEqual:@"sd"]) _bif = [PXBif bifForPartID:[self.item.part[@"id"] description] server:self.item.server];
        for (AVPlayerItemTrack *t in pi.tracks)
            PXLog(@"player: track %@ %.0fx%.0f", t.assetTrack.mediaType, t.assetTrack.naturalSize.width, t.assetTrack.naturalSize.height);
        [self showOSD:YES];
    }
    BOOL playing = _player.rate > 0;
    if (_readyOnce) _lastKnownPos = [self position];

    // iOS 8 AVPlayer does not resume by itself after a stall: do it when the
    // buffer is healthy again, unless the user paused.
    if (_readyOnce && !playing && !_userPausedFlag && !_ended && pi.playbackLikelyToKeepUp) {
        PXLog(@"player: resuming after stall at %@", PXClock([self position]));
        [_player play];
    }
    if (_readyOnce && _pendingSeek >= 0) { double t = _pendingSeek; _pendingSeek = -1; [self seekTo:t]; }
    if ([_lastDiag timeIntervalSinceNow] < -5 || !_lastDiag) { _lastDiag = [NSDate date]; [self logDiagnostics]; }

    // Center message: buffering / errors.
    if (!_failed) {
        BOOL buffering = !_readyOnce || (pi && !pi.playbackLikelyToKeepUp && !playing && !_userPausedFlag);
        if (buffering != !_spinner.hidden) PXNoAnim(^{ self->_spinner.hidden = !buffering; });
        if ([_center.string isEqual:PXL(@"Chargement…")]) PXSetText(_center, @"");
    }

    // Timeline: every 10 s, immediately on play/pause change.
    NSString *state = playing ? @"playing" : (_readyOnce ? @"paused" : @"buffering");
    if (_readyOnce && (![state isEqualToString:_lastState] || [_lastReport timeIntervalSinceNow] < -10)) {
        _lastState = state;
        [self report:state];
    }

    // Auto-hide the OSD while playing.
    if (_osdVisible && playing && !_scrubbing && !_overlay && [_osdShownAt timeIntervalSinceNow] < -5) [self showOSD:NO];
    if (_osdVisible) [self updateBar];
    if (_readyOnce) [self updateMarkers];

    // Transcoded streams may stall instead of ending: treat the last second as the end.
    double d = [self duration];
    if (_readyOnce && d > 0 && !_ended && [self position] > d - 1.0 && !playing) [self didReachEnd];
}

- (void)updateBar {
    double d = [self duration], pos = [self position], p = _scrubbing ? _scrubPos : pos;
    double buffered = 0;
    for (NSValue *v in _player.currentItem.loadedTimeRanges) {
        CMTimeRange r = v.CMTimeRangeValue;
        double end = CMTimeGetSeconds(CMTimeRangeGetEnd(r));
        if (CMTimeGetSeconds(r.start) <= pos + 1 && end > buffered) buffered = end;
    }
    CGImageRef preview = _scrubbing ? [_bif imageAt:p] : NULL;
    PXNoAnim(^{
        CGFloat h = self->_scrubbing ? 12 : 8;
        self->_barBack.frame = CGRectMake(kBarX, kBarY + (8 - h) / 2, kBarW, h);
        self->_barBack.cornerRadius = h / 2;
        CGFloat fp = d > 0 ? MIN(1, MAX(0, (self->_scrubbing ? p : pos) / d)) : 0;
        CGFloat fb = d > 0 ? MIN(1, buffered / d) : 0;
        self->_barPlayed.bounds = CGRectMake(0, 0, kBarW * fp, h);
        self->_barBuffered.bounds = CGRectMake(0, 0, kBarW * MAX(fb, fp), h);
        self->_barPlayed.cornerRadius = self->_barBuffered.cornerRadius = h / 2;
        PXSetText(self->_elapsed, PXClock(p));
        PXSetText(self->_remaining, d > 0 ? [@"-" stringByAppendingString:PXClock(MAX(0, d - p))] : @"");
        PXSetText(self->_endsAt, d > 0 ? [PXL(@"Fin à ") stringByAppendingString:PXWallClock([NSDate dateWithTimeIntervalSinceNow:MAX(0, d - p)])] : @"");
        PXSetText(self->_clock, PXWallClock([NSDate date]));
        CGFloat x = kBarX + kBarW * fp;
        self->_knob.hidden = !self->_scrubbing && self->_player.rate > 0;
        float pauseAlpha = self->_userPausedFlag && !self->_scrubbing && self->_readyOnce ? 1 : 0;
        if (self->_pauseBadge.opacity != pauseAlpha) PXAnim(0.2, ^{ self->_pauseBadge.opacity = pauseAlpha; });
        self->_knob.position = CGPointMake(x, kBarY + 4);
        self->_bubble.hidden = !self->_scrubbing;
        // The bubble takes the title area while scrubbing (tvOS behaviour).
        CGFloat titleAlpha = self->_scrubbing ? 0 : 1;
        if (self->_title.opacity != titleAlpha) {
            [CATransaction setDisableActions:NO];
            self->_title.opacity = self->_subtitle.opacity = self->_mode.opacity = titleAlpha;
            [CATransaction setDisableActions:YES];
        }
        if (self->_scrubbing) {
            CGFloat bw = self->_bubble.bounds.size.width, bh = self->_bubble.bounds.size.height;
            self->_bubble.position = CGPointMake(MIN(MAX(x, kBarX + bw / 2), kBarX + kBarW - bw / 2), kBarY - 34 - bh / 2);
            PXSetText(self->_scrubTime, PXClock(p));
            self->_previewImage.contents = (__bridge id)preview;
            // Without thumbnails the bubble shrinks to the time only.
            BOOL hasPreview = preview != NULL;
            self->_previewImage.hidden = !hasPreview;
            self->_bubble.bounds = CGRectMake(0, 0, kPreview.width + 12, hasPreview ? kPreview.height + 62 : 58);
            self->_scrubTime.frame = CGRectMake(0, hasPreview ? kPreview.height + 14 : 8, kPreview.width + 12, 42);
        }
    });
}

// Intro / credits markers: show a skip button while inside one.
- (void)updateMarkers {
    double pos = [self position];
    NSDictionary *active = nil;
    for (NSDictionary *m in self.item.markers) {
        NSString *t = m[@"type"];
        if (![t isEqual:@"intro"] && ![t isEqual:@"credits"]) continue;
        double a = [m[@"start"] doubleValue], b = [m[@"end"] doubleValue];
        if (pos >= a && pos < b - 1) { active = m; break; }
    }
    if (active == _activeMarker || [active isEqual:_activeMarker]) return;
    _activeMarker = active;
    if (active) {
        BOOL credits = [active[@"type"] isEqual:@"credits"];
        PXSetText(_skipText, credits ? (self.item.type == PXItemEpisode ? PXL(@"Épisode suivant") : PXL(@"Passer le générique")) : PXL(@"Passer l'intro"));
    }
    PXAnim(0.3, ^{ self->_skipButton.opacity = active ? 1 : 0; });
    if (active) PXSpringScale(_skipButton, 1.0);
}

- (void)skipMarker {
    NSDictionary *m = _activeMarker;
    if (!m) return;
    _activeMarker = nil;
    PXAnim(0.2, ^{ self->_skipButton.opacity = 0; });
    if ([m[@"type"] isEqual:@"credits"] && self.item.type == PXItemEpisode) { [self didReachEnd]; return; }
    [self seekTo:[m[@"end"] doubleValue]];
}

- (void)showOSD:(BOOL)show {
    _osdShownAt = [NSDate date];
    if (show == _osdVisible) { if (show) [self updateBar]; return; }
    _osdVisible = show;
    if (show) [self updateBar];
    PXAnim(0.3, ^{ self->_osd.opacity = show ? 1 : 0; });
}

#pragma mark - Controls

- (void)togglePause {
    if (_scrubbing) { [self commitScrub]; return; }
    if (_player.rate > 0) { [_player pause]; _userPausedFlag = YES; }
    else { [_player play]; _userPausedFlag = NO; }
    [self showOSD:YES];
}

- (void)seekTo:(double)t {
    if (!_readyOnce) { _pendingSeek = t; _lastKnownPos = t; return; }
    double d = [self duration];
    t = MAX(0, d > 0 ? MIN(t, d - 2) : t);
    _lastKnownPos = t;
    [_player seekToTime:CMTimeMakeWithSeconds(t, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    [self report:_player.rate > 0 ? @"playing" : @"paused"];
}

- (void)scrub:(int)direction {
    NSDate *now = [NSDate date];
    // Held key (auto-repeat) or fast presses accelerate the step.
    BOOL fast = _lastScrubKey && [now timeIntervalSinceDate:_lastScrubKey] < 0.4;
    _lastScrubKey = now;
    if (!_scrubbing) { _scrubbing = YES; _scrubPos = [self position]; _scrubStep = 10; }
    else _scrubStep = fast ? MIN(_scrubStep * 1.5, 300) : 10;
    double d = [self duration];
    _scrubPos = MAX(0, MIN(_scrubPos + direction * _scrubStep, d > 0 ? d - 2 : _scrubPos + 10));
    [self showOSD:YES];
}

- (void)commitScrub {
    _scrubbing = NO;
    [self seekTo:_scrubPos];
    [_player play];
    _userPausedFlag = NO;
    [self showOSD:YES];
}

- (void)skip:(double)seconds {
    [self seekTo:[self position] + seconds];
    [self showOSD:YES];
}

- (void)showTracks {
    PXItem *it = self.item;
    NSMutableArray *rows = [NSMutableArray array];
    __weak PXPlayerScreen *weak = self;
    PXListRow *ha = [PXListRow title:PXL(@"AUDIO") value:@"" action:nil];
    ha.enabled = NO;
    [rows addObject:ha];
    [rows addObjectsFromArray:PXAudioRows(it, ^(NSInteger sid) { [weak changeAudio:sid subtitle:-1]; })];
    PXListRow *hs = [PXListRow title:PXL(@"SOUS-TITRES") value:@"" action:nil];
    hs.enabled = NO;
    [rows addObject:hs];
    [rows addObjectsFromArray:PXSubtitleRows(it, ^(NSInteger sid) { [weak changeAudio:-1 subtitle:sid]; })];
    [self openOverlay:PXL(@"Audio et sous-titres") rows:rows];
}

- (void)showChapters {
    NSArray *chapters = self.item.chapters;
    if (!chapters.count) { [self showOSD:YES]; return; }
    NSMutableArray *rows = [NSMutableArray array];
    double pos = [self position];
    __weak PXPlayerScreen *weak = self;
    for (NSUInteger i = 0; i < chapters.count; i++) {
        double start = [chapters[i][@"start"] doubleValue];
        NSString *t = [chapters[i][@"title"] length] ? chapters[i][@"title"] : PXLF(@"Chapitre %lu", (unsigned long)i + 1);
        PXListRow *r = [PXListRow title:t value:PXClock(start) action:^{
            PXPlayerScreen *me = weak;
            [me->_overlay close];
            [me seekTo:start];
        }];
        double nextStart = i + 1 < chapters.count ? [chapters[i + 1][@"start"] doubleValue] : DBL_MAX;
        r.checked = pos >= start && pos < nextStart;
        [rows addObject:r];
    }
    [self openOverlay:PXL(@"Chapitres") rows:rows];
}

- (void)openOverlay:(NSString *)title rows:(NSArray *)rows {
    _overlay = [PXOverlay overlayInLayer:self.layer title:title rows:rows];
    __weak PXPlayerScreen *weak = self;
    _overlay.onClose = ^{ PXPlayerScreen *me = weak; if (me) me->_overlay = nil; };
    [self showOSD:YES];
}

// Persist the choice on the server, then restart the stream at the same
// position so the server applies it (remux / transcode / burned subtitles).
- (void)changeAudio:(NSInteger)audioID subtitle:(NSInteger)subtitleID {
    [_overlay close];
    PXMarkTracksManual(self.item.ratingKey);
    double pos = [self position];
    PXSetText(_center, PXL(@"Changement de piste…"));
    [_player pause];
    __weak PXPlayerScreen *weak = self;
    [self.item.server selectStreamsForPart:self.item.part audio:audioID subtitle:subtitleID done:^(id j, NSError *e) {
        if (e) PXLog(@"player: stream selection failed: %@", e.localizedDescription);
        [weak loadItemThenStartAt:pos];
    }];
}

#pragma mark - Volume

- (float)storedVolume {
    NSNumber *v = PXSettingGet(@"volume");
    return v ? MAX(0, MIN(1, v.floatValue)) : 1.0f;
}

- (void)changeVolume:(float)delta {
    float v = roundf(MAX(0, MIN(1, [self storedVolume] + delta)) * 10) / 10;
    _player.volume = v;
    PXSettingSet(@"volume", @(v));
    PXNoAnim(^{
        self->_volumeFill.bounds = CGRectMake(0, 0, 196 * v, 10);
        PXSetText(self->_volumeText, v > 0 ? PXLF(@"%d %%", (int)lroundf(v * 100)) : PXL(@"Muet"));
    });
    PXAnim(0.15, ^{ self->_volumeHUD.opacity = 1; });
    _volumeShownAt = [NSDate date];
    NSDate *shown = _volumeShownAt;
    __weak PXPlayerScreen *weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PXPlayerScreen *me = weak;
        if (me && me->_volumeShownAt == shown) PXAnim(0.4, ^{ me->_volumeHUD.opacity = 0; });
    });
}

#pragma mark - Options menu (long press)

- (void)showOptions {
    PXItem *it = self.item;
    __weak PXPlayerScreen *weak = self;
    NSMutableArray *rows = [NSMutableArray array];
    if (it.audioStreams.count)
        [rows addObject:[PXListRow title:PXL(@"Audio") value:PXShortTrack(it.selectedAudio) action:^{ [weak reopen:^{ [weak showAudio]; }]; }]];
    [rows addObject:[PXListRow title:PXL(@"Sous-titres") value:PXShortTrack(it.selectedSubtitle) action:^{ [weak reopen:^{ [weak showSubtitles]; }]; }]];
    if (it.chapters.count)
        [rows addObject:[PXListRow title:PXL(@"Chapitres") value:[NSString stringWithFormat:@"%lu", (unsigned long)it.chapters.count] action:^{ [weak reopen:^{ [weak showChapters]; }]; }]];
    [rows addObject:[PXListRow title:PXL(@"Volume") value:PXLF(@"%d %%", (int)lroundf([self storedVolume] * 100)) action:nil]];
    PXListRow *info = [PXListRow title:_directPlay ? PXL(@"Lecture directe") : PXL(@"Converti par le serveur") value:@"" action:nil];
    info.enabled = NO;
    [rows addObject:info];
    [self openOverlay:PXL(@"Options") rows:rows];
}

// Replace the options panel by a sub-panel.
- (void)reopen:(void (^)(void))show {
    [_overlay close];
    show();
}

- (void)showAudio {
    __weak PXPlayerScreen *weak = self;
    [self openOverlay:PXL(@"Audio") rows:PXAudioRows(self.item, ^(NSInteger sid) { [weak changeAudio:sid subtitle:-1]; })];
}

- (void)showSubtitles {
    __weak PXPlayerScreen *weak = self;
    [self openOverlay:PXL(@"Sous-titres") rows:PXSubtitleRows(self.item, ^(NSInteger sid) { [weak changeAudio:-1 subtitle:sid]; })];
}

#pragma mark - End / next episode

- (void)didReachEnd {
    if (_ended || _gone) return;
    _ended = YES;
    PXLog(@"player: end of '%@'", self.item.title);
    [self report:@"stopped"];
    [[PXPlex shared] setWatched:YES item:self.item.raw];
    if (self.queue) {
        NSUInteger i = [self.queue indexOfObjectPassingTest:^BOOL(PXItem *e, NSUInteger n, BOOL *stop) { return [e.ratingKey isEqual:self.item.ratingKey]; }];
        if (i == NSNotFound || i + 1 >= self.queue.count) { [self pop]; return; }
        [self offerNext:self.queue[i + 1]];
        return;
    }
    if (self.item.type != PXItemEpisode || !self.item.grandparentRatingKey) { [self pop]; return; }
    __weak PXPlayerScreen *weak = self;
    NSString *path = [NSString stringWithFormat:@"/library/metadata/%@/allLeaves", self.item.grandparentRatingKey];
    [self.item.server get:path done:^(NSDictionary *mc, NSError *err) {
        PXPlayerScreen *me = weak;
        if (!me || me->_gone) return;
        NSArray *eps = [PXItem itemsWithJSON:mc[@"Metadata"]];
        NSUInteger i = [eps indexOfObjectPassingTest:^BOOL(PXItem *e, NSUInteger n, BOOL *stop) { return [e.ratingKey isEqual:me.item.ratingKey]; }];
        if (i == NSNotFound || i + 1 >= eps.count) { [me pop]; return; }
        [me offerNext:eps[i + 1]];
    }];
}

- (void)offerNext:(PXItem *)next {
    _next = next;
    _countdown = 10;
    [self showOSD:NO];
    CGFloat W = 780, H = 250;
    _nextPanel = [CALayer layer];
    _nextPanel.frame = CGRectMake(1920 - 110 - W, 1080 - 110 - H, W, H);
    _nextPanel.backgroundColor = [UIColor colorWithRed:0.07 green:0.075 blue:0.09 alpha:0.92].CGColor;
    _nextPanel.cornerRadius = 22;
    _nextPanel.borderColor = PXColorWhite(0.12);
    _nextPanel.borderWidth = 2;
    _nextPanel.shadowColor = [UIColor blackColor].CGColor;
    _nextPanel.shadowOpacity = 0.6;
    _nextPanel.shadowRadius = 30;
    _nextPanel.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_nextPanel.bounds cornerRadius:22].CGPath;
    _nextPanel.zPosition = 50;
    CALayer *thumb = [CALayer layer];
    thumb.frame = CGRectMake(24, 24, 360, 202);
    thumb.cornerRadius = 12;
    thumb.backgroundColor = PXColorWhite(0.08);
    [_nextPanel addSublayer:thumb];
    [[PXImageCache shared] loadURL:[next.server imageURL:next.thumb width:360 height:202] size:CGSizeMake(360, 202) radius:12
                              done:^(CGImageRef img) { if (img) { PXFadeContents(thumb, 0.3); thumb.contents = (__bridge id)img; thumb.backgroundColor = NULL; } }];
    CATextLayer *eyebrow = PXText(PXFontSemi(22), PXColorAccent());
    eyebrow.string = PXL(@"ÉPISODE SUIVANT");
    eyebrow.frame = CGRectMake(410, 30, 340, 30);
    CATextLayer *title = PXText(PXFontBold(30), PXColorText());
    title.wrapped = YES;
    title.string = [NSString stringWithFormat:@"%@ · %@", next.episodeCode, next.title];
    title.frame = CGRectMake(410, 66, 340, 80);
    _nextText = PXText(PXFontMedium(24), PXColorTextDim());
    _nextText.frame = CGRectMake(486, 178, 270, 32);
    // Countdown ring around a play icon.
    CAShapeLayer *track = [CAShapeLayer layer];
    track.frame = CGRectMake(410, 162, 62, 62);
    track.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(track.bounds, 3, 3)].CGPath;
    track.fillColor = NULL;
    track.strokeColor = PXColorWhite(0.2);
    track.lineWidth = 5;
    CAShapeLayer *ring = [CAShapeLayer layer];
    ring.frame = track.frame;
    ring.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(31, 31) radius:28 startAngle:-M_PI_2 endAngle:M_PI * 1.5 clockwise:YES].CGPath;
    ring.fillColor = NULL;
    ring.strokeColor = PXColorText();
    ring.lineWidth = 5;
    ring.lineCap = kCALineCapRound;
    CABasicAnimation *fill = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
    fill.fromValue = @0;
    fill.toValue = @1;
    fill.duration = _countdown;
    [ring addAnimation:fill forKey:@"countdown"];
    CAShapeLayer *play = PXIconLayer(PXIconPlay, 26, PXColorText());
    play.position = CGPointMake(410 + 19, 162 + 18);
    for (CALayer *l in @[ eyebrow, title, _nextText, track, ring, play ]) [_nextPanel addSublayer:l];
    [self.layer addSublayer:_nextPanel];
    // Slide up.
    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"position.y"];
    slide.fromValue = @(_nextPanel.position.y + 80);
    slide.duration = 0.35;
    slide.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.2 :0.8 :0.2 :1.0];
    [_nextPanel addAnimation:slide forKey:@"in"];
    [self updateNext];
    __weak PXPlayerScreen *weak = self;
    [self scheduleCountdown:weak];
}

- (void)scheduleCountdown:(__weak PXPlayerScreen *)weak {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        PXPlayerScreen *me = weak;
        if (!me || me->_gone || !me->_next) return;
        if (--me->_countdown <= 0) [me playNext];
        else { [me updateNext]; [me scheduleCountdown:weak]; }
    });
}

- (void)updateNext {
    PXSetText(_nextText, PXLF(@"Lecture dans %d s", _countdown));
}

- (void)playNext {
    PXItem *next = _next;
    _next = nil;
    [_nextPanel removeFromSuperlayer];
    _nextPanel = nil;
    self.item = next;
    _prefsApplied = NO;
    [self renderTitles];
    PXSetText(_center, @"");
    [self loadItemThenStartAt:0];
}

#pragma mark - Keys

- (BOOL)handleKey:(PXKey)key {
    if (_overlay) return [_overlay handleKey:key];
    if (_next) {
        if (key == PXKeySelect || key == PXKeyPlayPause) [self playNext];
        else if (key == PXKeyMenu) { _next = nil; [self pop]; }
        return YES;
    }
    switch (key) {
        case PXKeyMenu:
            if (_scrubbing) { _scrubbing = NO; [self showOSD:YES]; return YES; }
            if (_osdVisible && _player.rate > 0 && !_failed) { [self showOSD:NO]; return YES; }
            return NO;   // stop: host pops, didPop cleans up
        case PXKeySelect:
            if (_activeMarker && !_osdVisible && !_scrubbing) { [self skipMarker]; return YES; }
            [self togglePause];
            return YES;
        case PXKeyPlayPause:
            [self togglePause];
            return YES;
        case PXKeyLeft:
        case PXKeyRight: {
            int dir = key == PXKeyLeft ? -1 : 1;
            if (_scrubbing || _player.rate == 0 || _osdVisible) [self scrub:dir];
            else [self skip:dir < 0 ? -10 : 30];
            return YES;
        }
        case PXKeyRewind: [self scrub:-6]; return YES;
        case PXKeyFastForward: [self scrub:6]; return YES;
        // Up / down: software volume. Options on a long press (center or play/pause).
        case PXKeyUp: [self changeVolume:0.1f]; return YES;
        case PXKeyDown: [self changeVolume:-0.1f]; return YES;
        case PXKeySelectHold:
        case PXKeyPlayPauseHold: [self showOptions]; return YES;
        default: return NO;
    }
}

#pragma mark - Lifecycle

// Covered by another screen: pause, otherwise this player stays audible under
// the new one (and ignores its volume keys). Marked as a user pause so the
// stall watchdog does not resume it.
- (void)willDisappear {
    if (_player.rate > 0) { [_player pause]; _userPausedFlag = YES; }
    [super willDisappear];
}

- (BOOL)pxPlaying { return _player.rate > 0; }

- (void)didPop {
    _gone = YES;
    if (gCurrentPlayer == self) gCurrentPlayer = nil;
    PXLog(@"player: stop at %@", PXClock([self position]));
    if (!_ended) [self report:@"stopped"];
    [_player pause];
    [self stopSession];
    if (_timer) dispatch_source_cancel(_timer);
    _timer = nil;
    if (_endObserver) [[NSNotificationCenter defaultCenter] removeObserver:_endObserver];
    _endObserver = nil;
    if (_stallObserver) [[NSNotificationCenter defaultCenter] removeObserver:_stallObserver];
    _stallObserver = nil;
    [_player replaceCurrentItemWithPlayerItem:nil];
    _videoLayer.player = nil;
    _player = nil;
    _userPausedFlag = NO;
    [super didPop];
}

@end

PXScreen *PXPlayerScreenNewQueue(NSArray *items) {
    PXPlayerScreen *s = [PXPlayerScreen new];
    s.item = items.firstObject;
    s.queue = items;
    s.startOffset = 0;
    [s setup];
    return s;
}

PXScreen *PXPlayerScreenNew(PXItem *item, double offset) {
    PXPlayerScreen *s = [PXPlayerScreen new];
    s.item = item;
    s.startOffset = offset;
    [s setup];
    return s;
}

#pragma mark - Remote control

NSDictionary *PXVideoPlayerState(void) {
    PXPlayerScreen *p = gCurrentPlayer;
    if (!p || !p.item.ratingKey) return nil;
    return @{ @"state": [p pxPlaying] ? @"playing" : @"paused", @"time": @([p position]), @"duration": @([p duration]),
              @"ratingKey": p.item.ratingKey, @"server": p.item.server.identifier ?: @"" };
}

void PXVideoPlayerControl(NSString *command, double value) {
    PXPlayerScreen *p = gCurrentPlayer;
    if (!p) return;
    BOOL playing = [p pxPlaying];
    if ([command isEqual:@"play"]) { if (!playing) [p togglePause]; }
    else if ([command isEqual:@"pause"]) { if (playing) [p togglePause]; }
    else if ([command isEqual:@"stop"]) [p pop];
    else if ([command isEqual:@"seekTo"]) [p seekTo:value];
    else if ([command isEqual:@"stepForward"]) [p seekTo:[p position] + 30];
    else if ([command isEqual:@"stepBack"]) [p seekTo:[p position] - 15];
}
