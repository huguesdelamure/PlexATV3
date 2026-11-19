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
- (NSURLSession *)session;
@end

// Lower is better: direct HTTPS, direct HTTP, then relay (bandwidth-limited).
static int connectionRank(NSDictionary *c) {
    int rank = 0;
    if (PXJSONBool(c[@"relay"])) rank += 100;
    if (![PXJSONString(c[@"protocol"]) isEqualToString:@"https"]) rank += 10;
    if (PXJSONBool(c[@"IPv6"])) rank += 1;
    return rank;
}

// At equal rank, a LAN address beats a public one.
static BOOL betterConnection(NSDictionary *c, NSDictionary *than) {
    if (!than) return YES;
    int a = connectionRank(c), b = connectionRank(than);
    return a < b || (a == b && PXJSONBool(c[@"local"]) && !PXJSONBool(than[@"local"]));
}

// The address did not answer (changed network, server moved): worth a new
// probe. HTTP errors (domain PXPlex) mean the server answered.
static BOOL isNetworkFailure(NSError *e) {
    if (![e.domain isEqualToString:NSURLErrorDomain]) return NO;
    switch (e.code) {
        case NSURLErrorTimedOut:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorCannotFindHost:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorNetworkConnectionLost:
            return YES;
        default:
            return NO;
    }
}

static NSError *cancelledError(void) { return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]; }

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
        _uri = PXJSONString(PXJSONDict(PXSettingGet(@"serverURIs"))[self.identifier]);
        // A remembered relay is slow and bandwidth-limited: keep using it, but
        // look for a direct address in the background. Deferred: servers are
        // created while +[PXPlex shared] is being initialised.
        if ([self isRelay:_uri]) {
            __weak PXServer *weak = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                PXServer *me = weak;
                if (!me || ![me isRelay:me->_uri]) return;
                PXLog(@"plex: remembered address is a relay, probing for a direct one");
                [me reprobe:nil];
            });
        }
    }
    return self;
}

- (NSArray *)connections { return PXJSONArray(_resource[@"connections"]); }

- (BOOL)isRelay:(NSString *)uri {
    if (!uri) return NO;
    for (NSDictionary *c in self.connections)
        if ([PXJSONDict(c)[@"uri"] isEqual:uri]) return PXJSONBool(c[@"relay"]);
    return NO;
}

- (instancetype)initOnlineProvider:(NSString *)baseURL identifier:(NSString *)identifier name:(NSString *)name {
    if ((self = [super init])) {
        _resource = @{ @"clientIdentifier": identifier, @"name": name, @"owned": @NO, @"presence": @YES };
        _uri = baseURL;
        _provider = YES;
    }
    return self;
}

- (void)updateResource:(NSDictionary *)resource { _resource = resource; }

- (NSDictionary *)resource { return _resource; }
- (NSString *)identifier { return PXJSONString(_resource[@"clientIdentifier"]); }
- (NSString *)name { return PXJSONString(_resource[@"name"]) ?: @"Serveur"; }
- (NSString *)sourceTitle { return [_resource[@"sourceTitle"] isKindOfClass:[NSString class]] ? _resource[@"sourceTitle"] : nil; }
- (BOOL)owned { return PXJSONBool(_resource[@"owned"]); }
- (BOOL)online { return PXJSONBool(_resource[@"presence"]); }
- (NSString *)token { return PXJSONString(_resource[@"accessToken"]) ?: PXSettingGet(@"authToken"); }
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

// Probe again while the current address stays in use. Without a better
// one the address is kept and the blocks get an error.
- (void)reprobe:(PXJSONBlock)done {
    if (!_waiting) {
        _waiting = [NSMutableArray array];
        if (done) [_waiting addObject:[done copy]];
        [self probe];
    } else if (done) {
        [_waiting addObject:[done copy]];
    }
}

- (void)finishConnect:(NSDictionary *)best {
    NSArray *blocks = _waiting;
    _waiting = nil;
    NSError *err = nil;
    if (best) {
        _uri = best[@"uri"];
        NSMutableDictionary *uris = [PXJSONDict(PXSettingGet(@"serverURIs")) mutableCopy] ?: [NSMutableDictionary dictionary];
        if (self.identifier) uris[self.identifier] = _uri;
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
    NSMutableArray *conns = [NSMutableArray array];
    for (NSDictionary *c in self.connections) if (PXJSONString(PXJSONDict(c)[@"uri"])) [conns addObject:c];
    if (!conns.count) { [self finishConnect:nil]; return; }
    __block NSInteger pending = conns.count, pendingLocal = 0;
    for (NSDictionary *c in conns) if (PXJSONBool(c[@"local"])) pendingLocal++;
    __block NSDictionary *best = nil;
    __block BOOL finished = NO, graceStarted = NO;
    __weak PXServer *weak = self;
    // Held here too: if the server is released meanwhile, its callers still get an answer.
    NSArray *waiting = _waiting;
    void (^finish)(void) = ^{
        if (finished) return;
        finished = YES;
        PXServer *me = weak;
        if (me) { [me finishConnect:best]; return; }
        for (PXJSONBlock b in waiting) b(nil, cancelledError());
    };
    for (NSDictionary *c in conns) {
        NSDate *t0 = [NSDate date];
        // /identity needs no token: never send it over plain HTTP or a relay.
        [[PXPlex shared] request:@"GET" url:[c[@"uri"] stringByAppendingString:@"/identity"] token:nil timeout:8 done:^(id json, NSError *err) {
            PXLog(@"plex: probe %@ -> %@ (%.0f ms)", c[@"uri"], err ? err.localizedDescription : @"OK", -[t0 timeIntervalSinceNow] * 1000);
            if (!err && betterConnection(c, best)) best = c;
            if (PXJSONBool(c[@"local"])) pendingLocal--;
            // A direct HTTPS connection is good enough: do not wait for slower
            // probes. A LAN address of the same rank still pending gets 1 s.
            if (best && connectionRank(best) < 10) {
                if (PXJSONBool(best[@"local"]) || pendingLocal == 0) finish();
                else if (!graceStarted) {
                    graceStarted = YES;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), finish);
                }
            }
            if (--pending == 0) finish();
        }];
    }
}

#pragma mark - PMS

- (NSString *)plexQuery { return [[PXPlex shared] plexQuery:self.token]; }

- (void)request:(NSString *)method path:(NSString *)path timeout:(NSTimeInterval)timeout headers:(NSDictionary *)headers done:(PXJSONBlock)done {
    // The online provider has a fixed address: nothing to probe.
    [self request:method path:path timeout:timeout headers:headers retry:!_provider done:done];
}

// retry: on a network failure, probe the connections once and replay once.
- (void)request:(NSString *)method path:(NSString *)path timeout:(NSTimeInterval)timeout headers:(NSDictionary *)headers
          retry:(BOOL)retry done:(PXJSONBlock)done {
    __weak PXServer *weak = self;
    void (^run)(void) = ^{
        PXServer *me = weak;
        if (!me) { if (done) done(nil, cancelledError()); return; }
        NSString *base = me->_uri;
        NSString *url = [path isKindOfClass:[NSString class]] ? [base stringByAppendingString:path] : nil;
        [[PXPlex shared] request:method url:url token:me.token headers:headers timeout:timeout done:^(id json, NSError *err) {
            PXServer *s = weak;
            if (!retry || !s || !isNetworkFailure(err)) { if (done) done(json, err); return; }
            void (^replay)(void) = ^{ [s request:method path:path timeout:timeout headers:headers retry:NO done:done]; };
            // Another request already moved to a new address.
            if (s->_uri && ![s->_uri isEqual:base]) { replay(); return; }
            PXLog(@"plex: network failure, probing the connections again");
            [s reprobe:^(id j, NSError *e) {
                if (e) { if (done) done(json, err); return; }
                replay();
            }];
        }];
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
        NSDictionary *mc = PXJSONDict(PXJSONDict(json)[@"MediaContainer"]);
        tagServer(mc, sid);
        done(mc, err);
    }];
}

- (void)put:(NSString *)path done:(PXJSONBlock)done {
    [self request:@"PUT" path:path timeout:20 headers:nil done:done];
}

static NSURL *publicImageURL(NSString *url, int w, int h, int blur) {
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://images.plex.tv/photo?width=%d&height=%d&minSize=1&upscale=1%@&url=%@",
                                 w, h, blur ? [NSString stringWithFormat:@"&blur=%d", blur] : @"", PXEncode(url)]];
}

- (NSURL *)imageURL:(NSString *)thumb width:(int)w height:(int)h {
    return [self artURL:thumb width:w height:h blur:0];
}

// The fragment (never sent) names the server: PXImageCache keys its disk
// cache on it instead of the address and token, which change.
- (NSURL *)artURL:(NSString *)art width:(int)w height:(int)h blur:(int)blur {
    if (![art isKindOfClass:[NSString class]] || !art.length || !_uri) return nil;
    if (_provider) return [art hasPrefix:@"http"] ? publicImageURL(art, w, h, blur) : nil;
    // Let the server resize: decoding full-size posters would exhaust 512 MB.
    NSString *u = [NSString stringWithFormat:@"%@/photo/:/transcode?width=%d&height=%d&minSize=1&upscale=1%@&url=%@&X-Plex-Token=%@#%@",
                   _uri, w, h, blur ? [NSString stringWithFormat:@"&blur=%d", blur] : @"", PXEncode(art), PXEncode(self.token),
                   PXEncode(self.identifier)];
    return [NSURL URLWithString:u];
}

- (void)metadata:(NSString *)ratingKey done:(PXJSONBlock)done {
    NSString *path = [NSString stringWithFormat:@"/library/metadata/%@?includeChapters=1&includeExtras=1&includeMarkers=1", ratingKey];
    [self get:path done:^(NSDictionary *mc, NSError *err) {
        id m = PXJSONDict(PXJSONArray(mc[@"Metadata"]).firstObject);
        done(m, err ?: (m ? nil : [NSError errorWithDomain:@"PXPlex" code:4 userInfo:@{ NSLocalizedDescriptionKey: PXL(@"Élément introuvable") }]));
    }];
}

#pragma mark - Playback

// What the A5 decodes in hardware with AVPlayer (Apple TV 3 specs):
// H.264 High <= 4.1 up to 1080p30 in MP4/MOV, AAC / MP3 audio.
// AC-3 is listed by Apple but measured on this device: AVPlayer recognises the
// track and stalls at 0 s. Anything not AAC/MP3 goes through the server.
// video: the video Stream of the part (profile, level, bitDepth), nil if the
// metadata has no streams; values missing there are not held against the file.
static BOOL canDirectPlay(NSDictionary *media, NSDictionary *video) {
    NSString *v = [PXJSONString(media[@"videoCodec"]) lowercaseString];
    NSString *a = [PXJSONString(media[@"audioCodec"]) lowercaseString];
    NSString *c = [PXJSONString(media[@"container"]) lowercaseString];
    NSString *fps = [PXJSONString(media[@"videoFrameRate"]) lowercaseString];
    double w = PXJSONNumber(media[@"width"]), h = PXJSONNumber(media[@"height"]);
    NSString *profile = [(PXJSONString(video[@"profile"]) ?: PXJSONString(media[@"videoProfile"])) lowercaseString];
    BOOL okV = [v isEqualToString:@"h264"] && w > 0 && h > 0 && h <= 1088 && w <= 1920
        && (!profile.length || [@[ @"baseline", @"constrained baseline", @"main", @"high" ] containsObject:profile])
        && PXJSONNumber(video[@"level"]) <= 41 && PXJSONNumber(video[@"bitDepth"]) <= 8;
    BOOL okA = [@[ @"aac", @"mp3" ] containsObject:a ?: @""];
    BOOL okC = [@[ @"mp4", @"mov", @"m4v" ] containsObject:c ?: @""];
    BOOL okF = !([fps isEqualToString:@"60p"] || [fps isEqualToString:@"50p"]);
    return okV && okA && okC && okF;
}

static NSDictionary *videoStream(NSDictionary *part) {
    for (id s in PXJSONArray(part[@"Stream"])) if (PXJSONNumber(PXJSONDict(s)[@"streamType"]) == 1) return s;
    return nil;
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
    // Extras (trailers…) are hosted online: the iOS 8 TLS stack fails on their
    // CDN, the server fetches them instead.
    BOOL online = it.type == PXItemClip || [PXSettingGet(@"audioBoost") intValue] > 100;   // boost: through the server
    if (media && PXJSONString(part[@"key"]) && canDirectPlay(media, videoStream(part)) && defaultTracks && !online) {
        NSString *u = [NSString stringWithFormat:@"%@%@?%@", _uri, part[@"key"], [self plexQuery]];
        done(@{ @"url": [NSURL URLWithString:u], @"directPlay": @YES, @"mode": PXL(@"Lecture directe") }, nil);
        return;
    }
    int boost = [PXSettingGet(@"audioBoost") intValue] ?: 100;   // Réglages > Boost audio
    NSString *session = [[NSUUID UUID] UUIDString].lowercaseString;
    NSString *profile =
        @"add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264&audioCodec=aac&replace=true)"
        @"+add-limitation(scope=videoCodec&scopeName=h264&type=upperBound&name=video.level&value=40)"
        @"+add-limitation(scope=videoCodec&scopeName=h264&type=upperBound&name=video.width&value=1920)"
        @"+add-limitation(scope=videoCodec&scopeName=h264&type=upperBound&name=video.height&value=1080)";
    NSString *query = [NSString stringWithFormat:
        @"path=%@&mediaIndex=%ld&partIndex=0&protocol=hls&fastSeek=1"
        @"&directPlay=0&directStream=1&directStreamAudio=%d&videoQuality=100&maxVideoBitrate=%d&videoResolution=1920x1080"
        @"&subtitles=burn&subtitleSize=%d&audioBoost=%d&location=wan&offset=%.0f&session=%@&X-Plex-Session-Identifier=%@"
        @"&X-Plex-Client-Profile-Extra=%@",
        PXEncode([@"/library/metadata/" stringByAppendingString:PXJSONString(metadata[@"ratingKey"]) ?: @""]), (long)mediaIndex,
        boost > 100 ? 0 : 1,   // a boost needs the audio converted, not copied
        [PXSettingGet(@"maxBitrate") intValue] ?: 8000, [PXSettingGet(@"subtitleSize") intValue] ?: 100, boost, seconds, session, session, PXEncode(profile)];
    // Current PMS refuses start.m3u8 for a session that has not asked for a
    // decision first ("session lacking decision"): ask, then start.
    NSString *base = _uri;
    [self request:@"GET" path:[@"/video/:/transcode/universal/decision?" stringByAppendingString:query] timeout:30
          headers:@{ @"X-Plex-Session-Identifier": session } done:^(NSDictionary *json, NSError *err) {
        NSDictionary *mc = PXJSONDict(PXJSONDict(json)[@"MediaContainer"]);
        NSInteger code = (NSInteger)PXJSONNumber(mc[@"generalDecisionCode"]);
        if (err || (code >= 2000)) {
            NSString *why = PXJSONString(mc[@"generalDecisionText"]) ?: PXJSONString(mc[@"transcodeDecisionText"]) ?: err.localizedDescription ?: PXL(@"refus du serveur");
            PXLog(@"playback: decision failed %ld %@", (long)code, why);
            done(nil, [NSError errorWithDomain:@"PXPlex" code:code userInfo:@{ NSLocalizedDescriptionKey: why }]);
            return;
        }
        // Per-stream decisions: copy (remux) or transcode.
        NSString *video = @"?", *audio = @"?";
        NSDictionary *dm = PXJSONDict(PXJSONArray(PXJSONDict(PXJSONArray(mc[@"Metadata"]).firstObject)[@"Media"]).firstObject);
        id streams = PXJSONDict(PXJSONArray(dm[@"Part"]).firstObject)[@"Stream"];
        for (NSDictionary *st in PXJSONArray(streams)) {
            if (![st isKindOfClass:[NSDictionary class]]) continue;
            NSString *d = [st[@"decision"] isEqual:@"copy"] ? PXL(@"copie") : ([st[@"decision"] isEqual:@"transcode"] ? PXL(@"transcodage") : PXJSONString(st[@"decision"]));
            if (PXJSONNumber(st[@"streamType"]) == 1 && d) video = d;
            if (PXJSONNumber(st[@"streamType"]) == 2 && d) audio = d;
        }
        NSString *mode = PXLF(@"Vidéo : %@ · Audio : %@", video, audio);
        PXLog(@"playback: decision %ld (%@) %@", (long)code, mc[@"generalDecisionText"], mode);
        // The decision request may have moved to another address (network failure, new probe).
        NSString *u = [NSString stringWithFormat:@"%@/video/:/transcode/universal/start.m3u8?%@&%@", self.uri ?: base, query, [[PXPlex shared] plexQuery:token]];
        done(@{ @"url": [NSURL URLWithString:u], @"directPlay": @NO, @"session": session, @"mode": mode }, nil);
    }];
}

#pragma mark - Music

// Direct play for what AVPlayer decodes (MP3, AAC, ALAC); anything else
// (FLAC, Opus, Vorbis, WMA…) is converted by the server to AAC over HLS.
- (void)prepareAudio:(NSDictionary *)track done:(PXJSONBlock)done { [self prepareAudio:track convert:NO done:done]; }

- (void)prepareAudio:(NSDictionary *)track convert:(BOOL)convert done:(PXJSONBlock)done {
    if (!_uri) {
        __weak PXServer *weak = self;
        [self connect:^(id json, NSError *err) {
            if (err) { done(nil, err); return; }
            [weak prepareAudio:track convert:convert done:done];
        }];
        return;
    }
    PXItem *it = [PXItem itemWithJSON:track];
    NSString *codec = [PXJSONString(it.media[@"audioCodec"]) lowercaseString] ?: @"";
    NSString *key = PXJSONString(it.part[@"key"]);
    if (!convert && key && [@[ @"mp3", @"aac", @"alac" ] containsObject:codec]) {
        NSString *u = [NSString stringWithFormat:@"%@%@?%@", _uri, key, [self plexQuery]];
        done(@{ @"url": [NSURL URLWithString:u], @"directPlay": @YES }, nil);
        return;
    }
    NSString *session = [[NSUUID UUID] UUIDString].lowercaseString;
    NSString *profile = @"add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mpegts&audioCodec=aac&replace=true)";
    NSString *query = [NSString stringWithFormat:
        @"path=%@&mediaIndex=0&partIndex=0&protocol=hls&directPlay=0&directStream=1&musicBitrate=320"
        @"&session=%@&X-Plex-Session-Identifier=%@&X-Plex-Client-Profile-Extra=%@",
        PXEncode([@"/library/metadata/" stringByAppendingString:PXJSONString(track[@"ratingKey"]) ?: @""]), session, session, PXEncode(profile)];
    NSString *base = _uri, *token = self.token;
    [self request:@"GET" path:[@"/music/:/transcode/universal/decision?" stringByAppendingString:query] timeout:30
          headers:@{ @"X-Plex-Session-Identifier": session } done:^(NSDictionary *json, NSError *err) {
        NSDictionary *mc = PXJSONDict(PXJSONDict(json)[@"MediaContainer"]);
        NSInteger code = (NSInteger)PXJSONNumber(mc[@"generalDecisionCode"]);
        if (err || code >= 2000) {
            NSString *why = PXJSONString(mc[@"generalDecisionText"]) ?: err.localizedDescription ?: PXL(@"refus du serveur");
            PXLog(@"music: decision failed %ld %@", (long)code, why);
            done(nil, [NSError errorWithDomain:@"PXPlex" code:code userInfo:@{ NSLocalizedDescriptionKey: why }]);
            return;
        }
        NSString *u = [NSString stringWithFormat:@"%@/music/:/transcode/universal/start.m3u8?%@&%@", self.uri ?: base, query, [[PXPlex shared] plexQuery:token]];
        done(@{ @"url": [NSURL URLWithString:u], @"directPlay": @NO, @"session": session }, nil);
    }];
}

- (void)getText:(NSString *)path done:(void (^)(NSString *))done {
    NSURL *url = nil;
    if (_uri && [path isKindOfClass:[NSString class]])
        url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@%@%@", _uri, path, [path containsString:@"?"] ? @"&" : @"?", [self plexQuery]]];
    if (!url) { done(nil); return; }
    // PXPlex's session: its delegate trusts the extra CA anchors.
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 20;
    [[[[PXPlex shared] session] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSInteger code = [(NSHTTPURLResponse *)r statusCode];
        NSString *t = nil;
        if (!e && code == 200 && d.length) {
            // Older text files are often Latin-1, which UTF-8 decoding rejects.
            t = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(t); });
    }] resume];
}

- (void)stopAudioTranscode:(NSString *)session {
    if (!session) return;
    NSString *path = [NSString stringWithFormat:@"/music/:/transcode/universal/stop?session=%@&X-Plex-Session-Identifier=%@", session, session];
    [self request:@"GET" path:path timeout:10 headers:@{ @"X-Plex-Session-Identifier": session } done:nil];
}

// Play queue of the server with its cinema trailers before the movie (count
// set in Réglages; which trailers is the server's "cinema trailers" setting).
- (void)trailersBefore:(NSDictionary *)movie count:(int)count done:(PXJSONBlock)done {
    NSString *uri = [NSString stringWithFormat:@"server://%@/com.plexapp.plugins.library/library/metadata/%@", self.identifier, movie[@"ratingKey"]];
    NSString *path = [NSString stringWithFormat:@"/playQueues?type=video&uri=%@&extrasPrefixCount=%d&shuffle=0&continuous=0&repeat=0&includeChapters=1&includeMarkers=1",
                      PXEncode(uri), count];
    NSString *sid = self.identifier;
    [self request:@"POST" path:path timeout:20 headers:nil done:^(id json, NSError *err) {
        id mc = [json isKindOfClass:[NSDictionary class]] ? json[@"MediaContainer"] : nil;
        tagServer(mc, sid);
        NSArray *items = [PXItem itemsWithJSON:mc[@"Metadata"]];
        PXLog(@"playqueue: %lu items (%d trailers asked) %@", (unsigned long)items.count, count, err.localizedDescription ?: @"");
        done(items, err);
    }];
}

- (void)reportTimeline:(NSDictionary *)metadata state:(NSString *)state timeMs:(long long)t {
    NSString *rk = PXJSONString(metadata[@"ratingKey"]);
    if (!rk || !state) return;
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
    if (!PXJSONString(metadata[@"ratingKey"])) return;
    NSString *path = [NSString stringWithFormat:@"/:/%@?key=%@&identifier=com.plexapp.plugins.library",
                      watched ? @"scrobble" : @"unscrobble", metadata[@"ratingKey"]];
    [self request:@"GET" path:path timeout:10 headers:nil done:nil];
}

- (void)selectStreamsForPart:(NSDictionary *)part audio:(NSInteger)audioID subtitle:(NSInteger)subtitleID done:(PXJSONBlock)done {
    if (!PXJSONString(part[@"id"])) { if (done) done(nil, cancelledError()); return; }
    NSMutableString *path = [NSMutableString stringWithFormat:@"/library/parts/%@?allParts=1", part[@"id"]];
    if (audioID >= 0) [path appendFormat:@"&audioStreamID=%ld", (long)audioID];
    if (subtitleID >= 0) [path appendFormat:@"&subtitleStreamID=%ld", (long)subtitleID];
    [self put:path done:done];
}

@end

NSString *PXServerTwinLabel(NSDictionary *resource, NSArray *resources) {
    NSString *name = resource[@"name"];
    NSUInteger same = 0;
    for (NSDictionary *r in resources) if ([PXJSONDict(r)[@"name"] isEqual:name]) same++;
    if (same < 2) return nil;
    NSString *device = resource[@"device"], *platform = resource[@"platform"];
    if ([platform isKindOfClass:[NSString class]] && platform.length) return platform;
    if ([device isKindOfClass:[NSString class]] && device.length) return device;
    NSString *cid = resource[@"clientIdentifier"];
    return [cid isKindOfClass:[NSString class]] && cid.length >= 6 ? [cid substringToIndex:6] : nil;
}
