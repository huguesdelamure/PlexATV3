#import "PXMusicPlayer.h"
#import <AVFoundation/AVFoundation.h>
#import "PXItem.h"
#import "PXServer.h"
#import "PXSettings.h"
#import "PXLog.h"

NSString *const PXMusicDidChange = @"PXMusicDidChange";

@implementation PXMusicPlayer {
    AVPlayer *_player;
    NSMutableArray *_queue;
    NSArray *_original;          // queue before shuffle
    NSInteger _index;
    NSString *_session;          // server conversion session of the current track
    PXServer *_sessionServer;
    id _timeObserver;
    NSInteger _serial;           // ignores answers for a track already skipped
    double _lastReport;
    NSInteger _failures;         // consecutive unplayable tracks
}

+ (instancetype)shared {
    static PXMusicPlayer *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ p = [PXMusicPlayer new]; });
    return p;
}

- (instancetype)init {
    if ((self = [super init])) {
        _player = [AVPlayer new];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemEnded:)
                                                     name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
        __weak PXMusicPlayer *weak = self;
        _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMake(1, 1) queue:dispatch_get_main_queue() usingBlock:^(CMTime t) {
            [weak tick];
        }];
    }
    return self;
}

- (void)changed { [[NSNotificationCenter defaultCenter] postNotificationName:PXMusicDidChange object:self]; }

#pragma mark - State

- (PXItem *)current { return _index >= 0 && _index < (NSInteger)_queue.count ? _queue[_index] : nil; }
- (NSArray *)queue { return [_queue copy] ?: @[]; }
- (NSInteger)index { return _index; }
- (BOOL)active { return self.current != nil; }
- (BOOL)playing { return _player.rate > 0; }
- (double)elapsed { double p = CMTimeGetSeconds(_player.currentTime); return isfinite(p) ? p : 0; }
- (double)duration {
    double d = CMTimeGetSeconds(_player.currentItem.duration);
    return isfinite(d) && d > 0 ? d : self.current.duration;
}
- (float)volume { NSNumber *v = PXSettingGet(@"volume"); return v ? v.floatValue : 1; }
- (void)setVolume:(float)volume {
    float v = MAX(0, MIN(1, volume));
    PXSettingSet(@"volume", @(v));   // shared with the video player
    _player.volume = v;
}

#pragma mark - Queue

- (void)playTracks:(NSArray *)tracks startAt:(NSInteger)index shuffle:(BOOL)shuffle {
    if (!tracks.count) return;
    _original = [tracks copy];
    _queue = [tracks mutableCopy];
    _index = MAX(0, MIN(index, (NSInteger)tracks.count - 1));
    _shuffle = NO;
    if (shuffle) {
        _index = arc4random_uniform((uint32_t)tracks.count);
        self.shuffle = YES;
    }
    [self startCurrent];
}

- (void)setShuffle:(BOOL)shuffle {
    if (shuffle == _shuffle || !_queue.count) { _shuffle = shuffle; return; }
    _shuffle = shuffle;
    PXItem *cur = self.current;
    if (shuffle) {
        // Current track first, the others in random order.
        NSMutableArray *rest = [_original mutableCopy];
        if (cur) [rest removeObject:cur];
        for (NSUInteger i = rest.count; i > 1; i--) [rest exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
        _queue = [NSMutableArray arrayWithObject:cur];
        [_queue addObjectsFromArray:rest];
        _index = 0;
    } else {
        _queue = [_original mutableCopy];
        _index = MAX(0, (NSInteger)[_queue indexOfObject:cur]);
    }
    [self changed];
}

- (void)setRepeat:(PXRepeatMode)repeat { _repeat = repeat; [self changed]; }

- (void)next {
    if (!_queue.count) return;
    if (_index + 1 < (NSInteger)_queue.count) _index++;
    else if (_repeat == PXRepeatAll) _index = 0;
    else { [self stop]; return; }
    [self startCurrent];
}

- (void)previous {
    if (!_queue.count) return;
    if (self.elapsed > 3 || _index == 0) { [_player seekToTime:kCMTimeZero]; return; }
    _index--;
    [self startCurrent];
}

- (void)itemEnded:(NSNotification *)n {
    if (n.object != _player.currentItem) return;
    [self report:@"stopped"];
    if (_repeat == PXRepeatOne) { [_player seekToTime:kCMTimeZero]; [_player play]; return; }
    [self next];
}

- (void)togglePause {
    if (!self.active) return;
    if (self.playing) [_player pause]; else [_player play];
    [self report:self.playing ? @"playing" : @"paused"];
    [self changed];
}

- (void)stop {
    if (self.active) [self report:@"stopped"];
    [self endSession];
    [_player pause];
    [_player replaceCurrentItemWithPlayerItem:nil];
    _queue = nil;
    _original = nil;
    _index = 0;
    _serial++;
    [self changed];
}

#pragma mark - Playback

- (void)endSession {
    if (_session) [_sessionServer stopAudioTranscode:_session];
    _session = nil;
    _sessionServer = nil;
}

- (void)startCurrent { [self startCurrentConverted:NO]; }

- (void)startCurrentConverted:(BOOL)convert {
    PXItem *track = self.current;
    if (!track) return;
    [self endSession];
    [_player pause];
    NSInteger serial = ++_serial;
    [self changed];
    __weak PXMusicPlayer *weak = self;
    PXServer *server = track.server;
    [server prepareAudio:track.raw convert:convert done:^(NSDictionary *r, NSError *err) {
        PXMusicPlayer *me = weak;
        if (!me || serial != me->_serial) { if (r[@"session"]) [server stopAudioTranscode:r[@"session"]]; return; }
        if (!r[@"url"]) {
            PXLog(@"music: cannot play %@: %@", track.title, err.localizedDescription);
            if (++me->_failures >= (NSInteger)me->_queue.count) { [me stop]; return; }
            [me next];   // skip unplayable tracks
            return;
        }
        me->_session = r[@"session"];
        me->_sessionServer = server;
        PXLog(@"music: %@ (%@)", track.title, [r[@"directPlay"] boolValue] ? @"direct" : @"converted");
        [me->_player replaceCurrentItemWithPlayerItem:[AVPlayerItem playerItemWithURL:r[@"url"]]];
        me->_player.volume = me.volume;
        [me->_player play];
        me->_lastReport = 0;
        [me report:@"playing"];
        // A file the server cannot serve directly (404, unreadable): through
        // the server conversion once, then the next track.
        AVPlayerItem *pi = me->_player.currentItem;
        BOOL direct = [r[@"directPlay"] boolValue];
        [me checkItem:pi serial:serial direct:direct track:track attempt:0];
        [me changed];
    }];
}

// A file the server cannot serve directly (404, unreadable): through the
// server conversion once, then the next track. Still loading after 10 s
// counts as a failure too.
- (void)checkItem:(AVPlayerItem *)pi serial:(NSInteger)serial direct:(BOOL)direct track:(PXItem *)track attempt:(int)attempt {
    __weak PXMusicPlayer *weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (attempt ? 6 : 4) * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        PXMusicPlayer *me = weak;
        if (!me || serial != me->_serial) return;
        if (pi.status == AVPlayerItemStatusUnknown && attempt == 0) { [me checkItem:pi serial:serial direct:direct track:track attempt:1]; return; }
        if (pi.status == AVPlayerItemStatusReadyToPlay) return;
        PXLog(@"music: %@ failed (%@): %@", track.title, direct ? @"direct" : @"converted", pi.error.localizedDescription ?: @"timeout");
        if (direct) { [me startCurrentConverted:YES]; return; }
        // Every track of the queue failed: stop instead of looping on the server.
        if (++me->_failures >= (NSInteger)me->_queue.count) { PXLog(@"music: nothing playable, stopping"); [me stop]; return; }
        [me next];
    });
}

- (void)tick {
    if (!self.active) return;
    if (self.elapsed > 1) _failures = 0;   // this one plays
    // Server timeline every 10 s (play count, "recently played", other clients).
    if (self.playing && self.elapsed - _lastReport >= 10) { _lastReport = self.elapsed; [self report:@"playing"]; }
    [self changed];
}

- (void)report:(NSString *)state {
    PXItem *t = self.current;
    if (!t.ratingKey) return;
    [t.server reportTimeline:t.raw state:state timeMs:(long long)(self.elapsed * 1000)];
}

@end
