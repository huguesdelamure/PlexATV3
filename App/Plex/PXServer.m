#import "PXServer.h"
#import "PXSettings.h"
#import "PXLog.h"
#import "PXLocalize.h"
#import "PXItem.h"

// HTTP helpers shared with PXPlex (one URL session, TLS handling, headers).
@interface PXPlex (HTTP)
- (void)request:(NSString *)method url:(NSString *)url token:(NSString *)token timeout:(NSTimeInterval)timeout done:(PXJSONBlock)done;
- (void)request:(NSString *)method url:(NSString *)url token:(NSString *)token headers:(NSDictionary *)extra
        timeout:(NSTimeInterval)timeout done:(PXJSONBlock)done;
- (NSString *)plexQuery:(NSString *)token;
- (void)serverDidConnect:(PXServer *)server;
@end

// Lower is better: direct HTTPS, direct HTTP, then relay (bandwidth-limited).
static int connectionRank(NSDictionary *c) {
    int rank = 0;
    if ([c[@"relay"] boolValue]) rank += 100;
    if (![c[@"protocol"] isEqualToString:@"https"]) rank += 10;
    if ([c[@"IPv6"] boolValue]) rank += 1;
    return rank;
}

// Tag every item / section dictionary of a response with its server.
static void tagServer(id obj, NSString *serverID) {
    if (![obj isKindOfClass:[NSMutableDictionary class]]) return;
    for (NSString *key in @[ @"Metadata", @"Directory", @"Hub" ]) {
        id list = obj[key];
        if (![list isKindOfClass:[NSArray class]]) continue;
        for (id d in list) {
            if (![d isKindOfClass:[NSMutableDictionary class]]) continue;
            d[@"_server"] = serverID;
            if ([key isEqual:@"Hub"]) tagServer(d, serverID);
        }
    }
}

@implementation PXServer {
    NSDictionary *_resource;
    NSString *_uri;
    NSMutableArray *_waiting;    // connect callbacks while probing
}

- (instancetype)initWithResource:(NSDictionary *)resource {
    if ((self = [super init])) {
        _resource = resource;
        // Last working address, so the app starts without probing.
        NSDictionary *uris = PXSettingGet(@"serverURIs");
        _uri = [uris isKindOfClass:[NSDictionary class]] ? uris[self.identifier] : nil;
    }
    return self;
}

- (void)updateResource:(NSDictionary *)resource { _resource = resource; }

- (NSDictionary *)resource { return _resource; }
- (NSString *)identifier { return _resource[@"clientIdentifier"]; }
- (NSString *)name { return _resource[@"name"] ?: @"Serveur"; }
- (NSString *)sourceTitle { return [_resource[@"sourceTitle"] isKindOfClass:[NSString class]] ? _resource[@"sourceTitle"] : nil; }
- (BOOL)owned { return [_resource[@"owned"] boolValue]; }
- (BOOL)online { return [_resource[@"presence"] boolValue]; }
- (NSString *)token { return _resource[@"accessToken"] ?: PXSettingGet(@"authToken"); }
- (NSString *)uri { return _uri; }
- (BOOL)connected { return _uri != nil; }

- (NSString *)description { return [NSString stringWithFormat:@"<PXServer %@ %@>", self.name, _uri ?: @"(not connected)"]; }

#pragma mark - Connection

- (void)connect:(PXJSONBlock)done {
    if (_uri) { done(@{ @"uri": _uri }, nil); return; }
    if (_waiting) { [_waiting addObject:[done copy]]; return; }
    _waiting = [NSMutableArray arrayWithObject:[done copy]];
    [self probe];
}

- (void)reconnect:(PXJSONBlock)done {
    _uri = nil;
    [self connect:done];
}

- (void)finishConnect:(NSDictionary *)best {
    NSArray *blocks = _waiting;
    _waiting = nil;
    NSError *err = nil;
    if (best) {
        _uri = best[@"uri"];
        NSMutableDictionary *uris = [PXSettingGet(@"serverURIs") mutableCopy] ?: [NSMutableDictionary dictionary];
        uris[self.identifier] = _uri;
        PXSettingSet(@"serverURIs", uris);
        PXLog(@"plex: using %@ for %@", _uri, self.name);
        [[PXPlex shared] serverDidConnect:self];
    } else {
        err = [NSError errorWithDomain:@"PXPlex" code:2 userInfo:@{ NSLocalizedDescriptionKey: PXLF(@"%@ injoignable", self.name) }];
    }
    for (PXJSONBlock b in blocks) b(best, err);
}

// Probe every published connection, keep the best working one.
- (void)probe {
    NSArray *conns = [_resource[@"connections"] isKindOfClass:[NSArray class]] ? _resource[@"connections"] : @[];
    if (!conns.count) { [self finishConnect:nil]; return; }
    __block NSInteger pending = conns.count;
    __block NSDictionary *best = nil;
    __block BOOL finished = NO;
    __weak PXServer *weak = self;
    void (^finish)(void) = ^{
        if (finished) return;
        finished = YES;
        [weak finishConnect:best];
    };
    NSString *token = self.token;
    for (NSDictionary *c in conns) {
        NSDate *t0 = [NSDate date];
        [[PXPlex shared] request:@"GET" url:[c[@"uri"] stringByAppendingString:@"/identity"] token:token timeout:8 done:^(id json, NSError *err) {
            PXLog(@"plex: probe %@ -> %@ (%.0f ms)", c[@"uri"], err ? err.localizedDescription : @"OK", -[t0 timeIntervalSinceNow] * 1000);
            if (!err && (!best || connectionRank(c) < connectionRank(best))) best = c;
            // A direct HTTPS connection is good enough: do not wait for slower probes.
            if (best && connectionRank(best) < 10) finish();
            if (--pending == 0) finish();
        }];
    }
}

#pragma mark - PMS

- (NSString *)plexQuery { return [[PXPlex shared] plexQuery:self.token]; }

- (void)request:(NSString *)method path:(NSString *)path timeout:(NSTimeInterval)timeout headers:(NSDictionary *)headers done:(PXJSONBlock)done {
    __weak PXServer *weak = self;
    void (^run)(void) = ^{
        PXServer *me = weak;
        if (!me) return;
        [[PXPlex shared] request:method url:[me->_uri stringByAppendingString:path] token:me.token headers:headers timeout:timeout done:done];
    };
    if (_uri) { run(); return; }
    [self connect:^(id json, NSError *err) {
        if (err) { if (done) done(nil, err); return; }
        run();
    }];
}

- (void)get:(NSString *)path done:(PXJSONBlock)done {
    NSString *sid = self.identifier;
    [self request:@"GET" path:path timeout:20 headers:nil done:^(id json, NSError *err) {
        id mc = [json isKindOfClass:[NSDictionary class]] ? json[@"MediaContainer"] : nil;
        tagServer(mc, sid);
        done(mc, err);
    }];
}

- (void)put:(NSString *)path done:(PXJSONBlock)done {
    [self request:@"PUT" path:path timeout:20 headers:nil done:done];
}

- (NSURL *)imageURL:(NSString *)thumb width:(int)w height:(int)h {
    if (!thumb.length || !_uri) return nil;
    // Let the server resize: decoding full-size posters would exhaust 512 MB.
    NSString *u = [NSString stringWithFormat:@"%@/photo/:/transcode?width=%d&height=%d&minSize=1&upscale=1&url=%@&X-Plex-Token=%@",
                   _uri, w, h, PXEncode(thumb), PXEncode(self.token)];
    return [NSURL URLWithString:u];
}

- (NSURL *)artURL:(NSString *)art width:(int)w height:(int)h blur:(int)blur {
    if (!art.length || !_uri) return nil;
    NSString *u = [NSString stringWithFormat:@"%@/photo/:/transcode?width=%d&height=%d&minSize=1&upscale=1%@&url=%@&X-Plex-Token=%@",
                   _uri, w, h, blur ? [NSString stringWithFormat:@"&blur=%d", blur] : @"", PXEncode(art), PXEncode(self.token)];
    return [NSURL URLWithString:u];
}

- (void)metadata:(NSString *)ratingKey done:(PXJSONBlock)done {
    NSString *path = [NSString stringWithFormat:@"/library/metadata/%@?includeChapters=1", ratingKey];
    [self get:path done:^(NSDictionary *mc, NSError *err) {
        id m = [mc[@"Metadata"] isKindOfClass:[NSArray class]] ? [mc[@"Metadata"] firstObject] : nil;
        done(m, err ?: (m ? nil : [NSError errorWithDomain:@"PXPlex" code:4 userInfo:@{ NSLocalizedDescriptionKey: PXL(@"Élément introuvable") }]));
    }];
}

#pragma mark - Playback

// What the A5 decodes in hardware with AVPlayer (Apple TV 3 specs):
// H.264 High <= 4.1 up to 1080p30 in MP4/MOV, AAC / MP3 audio.
// AC-3 is listed by Apple but measured on this device: AVPlayer recognises the
// track and stalls at 0 s. Anything not AAC/MP3 goes through the server.
static BOOL canDirectPlay(NSDictionary *media) {
    NSString *v = [media[@"videoCodec"] lowercaseString];
    NSString *a = [media[@"audioCodec"] lowercaseString];
    NSString *c = [media[@"container"] lowercaseString];
    NSString *fps = [media[@"videoFrameRate"] lowercaseString];
    BOOL okV = [v isEqualToString:@"h264"] && [media[@"height"] intValue] <= 1088 && [media[@"width"] intValue] <= 1920;
    BOOL okA = [@[ @"aac", @"mp3" ] containsObject:a ?: @""];
    BOOL okC = [@[ @"mp4", @"mov", @"m4v" ] containsObject:c ?: @""];
    BOOL okF = !([fps isEqualToString:@"60p"] || [fps isEqualToString:@"50p"]);
    return okV && okA && okC && okF;
}

- (void)preparePlayback:(NSDictionary *)metadata offset:(double)seconds done:(PXJSONBlock)done {
    if (!_uri) {
        __weak PXServer *weak = self;
        [self connect:^(id json, NSError *err) {
            if (err) { done(nil, err); return; }
            [weak preparePlayback:metadata offset:seconds done:done];
        }];
        return;
    }
    // Chosen version (Media entry), see -[PXItem mediaIndex].
    PXItem *it = [PXItem itemWithJSON:metadata];
    NSDictionary *media = it.media;
    NSDictionary *part = it.part;
    NSInteger mediaIndex = it.mediaIndex;
    NSString *token = self.token;
    // Direct play only plays the default audio track and no subtitles:
    // any other choice goes through the server (remux or transcode).
    BOOL defaultTracks = !it.selectedSubtitle && (!it.selectedAudio || it.selectedAudio.streamID == [it.audioStreams.firstObject streamID]);
    if (media && part[@"key"] && canDirectPlay(media) && defaultTracks) {
        NSString *u = [NSString stringWithFormat:@"%@%@?%@", _uri, part[@"key"], [self plexQuery]];
        done(@{ @"url": [NSURL URLWithString:u], @"directPlay": @YES, @"mode": PXL(@"Lecture directe") }, nil);
        return;
    }
    NSString *session = [[NSUUID UUID] UUIDString].lowercaseString;
    NSString *profile =
        @"add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264&audioCodec=aac&replace=true)"
        @"+add-limitation(scope=videoCodec&scopeName=h264&type=upperBound&name=video.level&value=40)"
        @"+add-limitation(scope=videoCodec&scopeName=h264&type=upperBound&name=video.width&value=1920)"
        @"+add-limitation(scope=videoCodec&scopeName=h264&type=upperBound&name=video.height&value=1080)";
    NSString *query = [NSString stringWithFormat:
        @"path=%@&mediaIndex=%ld&partIndex=0&protocol=hls&fastSeek=1"
        @"&directPlay=0&directStream=1&directStreamAudio=1&videoQuality=100&maxVideoBitrate=%d&videoResolution=1920x1080"
        @"&subtitles=burn&subtitleSize=100&audioBoost=100&location=wan&offset=%.0f&session=%@&X-Plex-Session-Identifier=%@"
        @"&X-Plex-Client-Profile-Extra=%@",
        PXEncode([@"/library/metadata/" stringByAppendingString:metadata[@"ratingKey"] ?: @""]), (long)mediaIndex,
        [PXSettingGet(@"maxBitrate") intValue] ?: 8000, seconds, session, session, PXEncode(profile)];
    // Current PMS refuses start.m3u8 for a session that has not asked for a
    // decision first ("session lacking decision"): ask, then start.
    NSString *base = _uri;
    [self request:@"GET" path:[@"/video/:/transcode/universal/decision?" stringByAppendingString:query] timeout:30
          headers:@{ @"X-Plex-Session-Identifier": session } done:^(NSDictionary *json, NSError *err) {
        NSDictionary *mc = json[@"MediaContainer"];
        NSInteger code = [mc[@"generalDecisionCode"] integerValue];
        if (err || (code >= 2000)) {
            NSString *why = mc[@"generalDecisionText"] ?: mc[@"transcodeDecisionText"] ?: err.localizedDescription ?: PXL(@"refus du serveur");
            PXLog(@"playback: decision failed %ld %@", (long)code, why);
            done(nil, [NSError errorWithDomain:@"PXPlex" code:code userInfo:@{ NSLocalizedDescriptionKey: why }]);
            return;
        }
        // Per-stream decisions: copy (remux) or transcode.
        NSString *video = @"?", *audio = @"?";
        NSDictionary *dm = [[mc[@"Metadata"] firstObject][@"Media"] firstObject];
        id streams = [[dm[@"Part"] firstObject] objectForKey:@"Stream"];
        for (NSDictionary *st in [streams isKindOfClass:[NSArray class]] ? streams : @[]) {
            NSString *d = [st[@"decision"] isEqual:@"copy"] ? PXL(@"copie") : ([st[@"decision"] isEqual:@"transcode"] ? PXL(@"transcodage") : st[@"decision"]);
            if ([st[@"streamType"] intValue] == 1 && d) video = d;
            if ([st[@"streamType"] intValue] == 2 && d) audio = d;
        }
        NSString *mode = PXLF(@"Vidéo : %@ · Audio : %@", video, audio);
        PXLog(@"playback: decision %ld (%@) %@", (long)code, mc[@"generalDecisionText"], mode);
        NSString *u = [NSString stringWithFormat:@"%@/video/:/transcode/universal/start.m3u8?%@&%@", base, query, [[PXPlex shared] plexQuery:token]];
        done(@{ @"url": [NSURL URLWithString:u], @"directPlay": @NO, @"session": session, @"mode": mode }, nil);
    }];
}

- (void)reportTimeline:(NSDictionary *)metadata state:(NSString *)state timeMs:(long long)t {
    NSString *rk = metadata[@"ratingKey"];
    NSString *path = [NSString stringWithFormat:@"/:/timeline?ratingKey=%@&key=%@&state=%@&time=%lld&duration=%@&identifier=com.plexapp.plugins.library",
                      rk, PXEncode([@"/library/metadata/" stringByAppendingString:rk]), state, t, metadata[@"duration"] ?: @0];
    [self request:@"GET" path:path timeout:10 headers:nil done:nil];
}

- (void)stopTranscode:(NSString *)session {
    if (!session) return;
    NSString *path = [NSString stringWithFormat:@"/video/:/transcode/universal/stop?session=%@&X-Plex-Session-Identifier=%@", session, session];
    [self request:@"GET" path:path timeout:10 headers:@{ @"X-Plex-Session-Identifier": session } done:nil];
}

- (void)setWatched:(BOOL)watched item:(NSDictionary *)metadata {
    NSString *path = [NSString stringWithFormat:@"/:/%@?key=%@&identifier=com.plexapp.plugins.library",
                      watched ? @"scrobble" : @"unscrobble", metadata[@"ratingKey"]];
    [self request:@"GET" path:path timeout:10 headers:nil done:nil];
}

- (void)selectStreamsForPart:(NSDictionary *)part audio:(NSInteger)audioID subtitle:(NSInteger)subtitleID done:(PXJSONBlock)done {
    NSMutableString *path = [NSMutableString stringWithFormat:@"/library/parts/%@?allParts=1", part[@"id"]];
    if (audioID >= 0) [path appendFormat:@"&audioStreamID=%ld", (long)audioID];
    if (subtitleID >= 0) [path appendFormat:@"&subtitleStreamID=%ld", (long)subtitleID];
    [self put:path done:done];
}

@end

NSString *PXServerTwinLabel(NSDictionary *resource, NSArray *resources) {
    NSString *name = resource[@"name"];
    NSUInteger same = 0;
    for (NSDictionary *r in resources) if ([r[@"name"] isEqual:name]) same++;
    if (same < 2) return nil;
    NSString *device = resource[@"device"], *platform = resource[@"platform"];
    if ([platform isKindOfClass:[NSString class]] && platform.length) return platform;
    if ([device isKindOfClass:[NSString class]] && device.length) return device;
    NSString *cid = resource[@"clientIdentifier"];
    return [cid isKindOfClass:[NSString class]] && cid.length >= 6 ? [cid substringToIndex:6] : nil;
}
