#import "PXPlex.h"
#import "PXLocalize.h"
#import "PXSettings.h"
#import "PXLog.h"
#import "PXItem.h"
#import "PXServer.h"
#import <Security/Security.h>

NSString *const PXSelectedServersDidChange = @"PXSelectedServersDidChange";
NSString *const PXHomeUserDidChange = @"PXHomeUserDidChange";
static NSString *const kPlexTV = @"https://clients.plex.tv";
static NSString *const kProduct = @"PlexATV";
// App version, from Info.plist (CFBundleShortVersionString).
static NSString *appVersion(void) {
    return [PXKitBundle() objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0";
}

NSString *PXEncode(NSString *s) {
    return (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(
        NULL, (__bridge CFStringRef)(s ?: @""), NULL, CFSTR("!*'();:@&=+$,/?%#[] "), kCFStringEncodingUTF8);
}

// Extra trust anchors (Resources/certs/*.der) for servers whose CA is newer
// than the iOS 8 root store (e.g. Let's Encrypt ISRG Root X1). Used only when
// the default evaluation fails; chain and host name are still fully checked.
static NSArray *extraAnchors(void) {
    static NSArray *anchors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *a = [NSMutableArray array];
        NSString *dir = [[[NSBundle bundleForClass:[PXPlex class]] bundlePath] stringByAppendingPathComponent:@"certs"];
        for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL]) {
            if (![f.pathExtension isEqualToString:@"der"]) continue;
            NSData *d = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:f]];
            SecCertificateRef c = d ? SecCertificateCreateWithData(NULL, (__bridge CFDataRef)d) : NULL;
            if (c) { [a addObject:(__bridge_transfer id)c]; }
        }
        anchors = a;
        PXLog(@"tls: %lu extra anchors loaded", (unsigned long)a.count);
    });
    return anchors;
}

@interface PXPlex () <NSURLSessionDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSSet *watchlistKeys;
@end

@implementation PXPlex {
    NSMutableDictionary *_servers;   // identifier -> PXServer
    NSArray *_order;                 // identifiers in plex.tv order
}

+ (instancetype)shared {
    static PXPlex *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ p = [PXPlex new]; });
    return p;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 20;
        cfg.HTTPMaximumConnectionsPerHost = 4;
        // Callbacks (and JSON parsing, slow on the A5) off the main thread;
        // results are handed back on the main queue.
        NSOperationQueue *q = [NSOperationQueue new];
        q.maxConcurrentOperationCount = 2;
        _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:q];
        _servers = [NSMutableDictionary dictionary];
        [self loadCachedServers];
    }
    return self;
}

#pragma mark - TLS

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion {
    if (![challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        completion(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        return;
    }
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    SecTrustResultType result = kSecTrustResultInvalid;
    SecTrustEvaluate(trust, &result);
    if (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed) {
        completion(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
        return;
    }
    SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)extraAnchors());
    SecTrustSetAnchorCertificatesOnly(trust, false);
    SecTrustEvaluate(trust, &result);
    BOOL ok = (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed);
    PXLog(@"tls: %@ default trust failed, with extra anchors: %@", challenge.protectionSpace.host, ok ? @"OK" : @"FAILED");
    if (ok) completion(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
    else completion(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
}

#pragma mark - HTTP

- (NSDictionary *)plexHeaders {
    return @{ @"X-Plex-Client-Identifier": PXClientId(),
              @"X-Plex-Product": kProduct,
              @"X-Plex-Version": appVersion(),
              @"X-Plex-Platform": @"iOS",
              @"X-Plex-Platform-Version": @"8.4",
              @"X-Plex-Device": @"Apple TV",
              @"X-Plex-Model": @"AppleTV3,2",
              @"X-Plex-Device-Name": @"Apple TV (PlexATV)",
              @"X-Plex-Language": PXLanguage(),   // metadata (summaries, genres) in the UI language
              @"Accept": @"application/json" };
}

// Query-string form of the identification headers (for AVPlayer URLs).
- (NSString *)plexQuery:(NSString *)token {
    NSMutableArray *q = [NSMutableArray array];
    [[self plexHeaders] enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        if (![k isEqualToString:@"Accept"]) [q addObject:[NSString stringWithFormat:@"%@=%@", k, PXEncode(v)]];
    }];
    if (token) [q addObject:[NSString stringWithFormat:@"X-Plex-Token=%@", PXEncode(token)]];
    return [q componentsJoinedByString:@"&"];
}

- (void)request:(NSString *)method url:(NSString *)url token:(NSString *)token timeout:(NSTimeInterval)timeout
           done:(PXJSONBlock)done {
    [self request:method url:url token:token headers:nil timeout:timeout done:done];
}

- (void)request:(NSString *)method url:(NSString *)url token:(NSString *)token headers:(NSDictionary *)extra
        timeout:(NSTimeInterval)timeout done:(PXJSONBlock)done {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = method;
    req.timeoutInterval = timeout;
    [[self plexHeaders] enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) { [req setValue:v forHTTPHeaderField:k]; }];
    // PMS warns that container listings without these headers will soon fail;
    // explicit query-string paging (X-Plex-Container-*=) takes precedence.
    // Not for the online providers: they answer 400 above 100 items per page.
    if ([url rangeOfString:@"X-Plex-Container-Size"].location == NSNotFound && ![req.URL.host hasSuffix:@".provider.plex.tv"]) {
        [req setValue:@"0" forHTTPHeaderField:@"X-Plex-Container-Start"];
        [req setValue:@"2000" forHTTPHeaderField:@"X-Plex-Container-Size"];
    }
    [extra enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) { [req setValue:v forHTTPHeaderField:k]; }];
    if (token) [req setValue:token forHTTPHeaderField:@"X-Plex-Token"];
    [[self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        if (!err && (code < 200 || code >= 300)) {
            err = [NSError errorWithDomain:@"PXPlex" code:code
                                  userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)code] }];
        }
        id json = nil;
        if (!err && data.length) json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
        if (err) PXLog(@"http %@ %@ -> %@", method, [url componentsSeparatedByString:@"?"].firstObject, err.localizedDescription);
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(json, err); });
    }] resume];
}

#pragma mark - plex.tv

- (BOOL)isLinked { return PXSettingGet(@"authToken") != nil; }
- (BOOL)hasServer { return self.primaryServer.connected; }
- (NSString *)serverName { return self.primaryServer.name; }

- (void)createPin:(PXJSONBlock)done {
    [self request:@"POST" url:[kPlexTV stringByAppendingString:@"/api/v2/pins"] token:nil timeout:20 done:done];
}

- (void)checkPin:(NSNumber *)pinId done:(PXJSONBlock)done {
    NSString *url = [NSString stringWithFormat:@"%@/api/v2/pins/%@", kPlexTV, pinId];
    [self request:@"GET" url:url token:nil timeout:20 done:done];
}

- (void)saveAuthToken:(NSString *)token {
    PXSettingSet(@"authToken", token);
    PXSettingSet(@"accountToken", token);
    [self refreshAccountProfile];
}

- (NSDictionary *)accountProfile {
    static BOOL refreshed;
    if (!refreshed && self.isLinked) { refreshed = YES; [self refreshAccountProfile]; }
    return PXSettingGet(@"accountProfile") ?: @{};
}

- (void)refreshAccountProfile {
    [self request:@"GET" url:[kPlexTV stringByAppendingString:@"/api/v2/user"] token:PXSettingGet(@"authToken") timeout:20 done:^(id json, NSError *err) {
        NSDictionary *p = [json isKindOfClass:[NSDictionary class]] ? json[@"profile"] : nil;
        if (![p isKindOfClass:[NSDictionary class]]) return;
        NSMutableDictionary *clean = [NSMutableDictionary dictionary];   // plist-safe values only
        [p enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) clean[k] = v;
        }];
        PXSettingSet(@"accountProfile", clean);
        PXLog(@"plex: account profile audio=%@ subtitles=%@ forced=%@", clean[@"defaultAudioLanguage"], clean[@"defaultSubtitleLanguage"], clean[@"defaultSubtitleForced"]);
    }];
}

- (void)signOut {
    for (NSString *k in @[ @"authToken", @"accountToken", @"homeUsers", @"homeUserUUID", @"profiles", @"accountProfile",
                           @"serverId", @"serverName", @"serverURI", @"serverToken", @"serverURIs", @"resources", @"selectedServers" ])
        PXSettingSet(k, nil);
    [_servers removeAllObjects];
    _order = @[];
}

#pragma mark - Plex Home users

static id plistSafe(id v);

static NSString *accountToken(void) { return PXSettingGet(@"accountToken") ?: PXSettingGet(@"authToken"); }

- (NSArray *)homeUsers {
    NSArray *u = PXSettingGet(@"homeUsers");
    return [u isKindOfClass:[NSArray class]] ? u : @[];
}

- (NSDictionary *)currentHomeUser {
    NSString *uuid = PXSettingGet(@"homeUserUUID");
    for (NSDictionary *u in self.homeUsers) if (uuid ? [u[@"uuid"] isEqual:uuid] : [u[@"admin"] boolValue]) return u;
    return nil;
}

- (void)fetchHomeUsers:(PXJSONBlock)done {
    [self request:@"GET" url:[kPlexTV stringByAppendingString:@"/api/v2/home/users"] token:accountToken() timeout:20 done:^(id json, NSError *err) {
        NSArray *raw = [json isKindOfClass:[NSDictionary class]] ? json[@"users"] : nil;
        NSMutableArray *users = [NSMutableArray array];
        for (NSDictionary *u in [raw isKindOfClass:[NSArray class]] ? raw : @[]) {
            if (![u isKindOfClass:[NSDictionary class]] || !u[@"uuid"]) continue;
            NSMutableDictionary *c = [NSMutableDictionary dictionary];   // what the UI needs, never a token
            for (NSString *k in @[ @"uuid", @"title", @"username", @"thumb", @"admin", @"guest", @"restricted", @"protected" ])
                if (plistSafe(u[k])) c[k] = plistSafe(u[k]);
            [users addObject:c];
        }
        if (raw) PXSettingSet(@"homeUsers", users);
        PXLog(@"plex: home users %lu%@", (unsigned long)users.count, err ? [@" error " stringByAppendingString:err.localizedDescription] : @"");
        if (done) done(raw ? users : self.homeUsers, err);
    }];
}

- (void)switchToHomeUser:(NSDictionary *)user pin:(NSString *)pin done:(PXJSONBlock)done {
    NSString *uuid = user[@"uuid"];
    NSString *url = [NSString stringWithFormat:@"%@/api/v2/home/users/%@/switch%@", kPlexTV, PXEncode(uuid),
                     pin.length ? [@"?pin=" stringByAppendingString:PXEncode(pin)] : @""];
    [self request:@"POST" url:url token:accountToken() timeout:20 done:^(id json, NSError *err) {
        NSString *token = [json isKindOfClass:[NSDictionary class]] ? json[@"authToken"] : nil;
        if (![token isKindOfClass:[NSString class]] || !token.length) {
            done(nil, err ?: [NSError errorWithDomain:@"PXPlex" code:401 userInfo:@{ NSLocalizedDescriptionKey: PXL(@"Code PIN incorrect") }]);
            return;
        }
        // Keep the server choice of the profile we leave, restore the other's.
        NSMutableDictionary *profiles = [PXSettingGet(@"profiles") mutableCopy] ?: [NSMutableDictionary dictionary];
        NSString *old = PXSettingGet(@"homeUserUUID") ?: [self currentHomeUser][@"uuid"];
        NSMutableDictionary *state = [NSMutableDictionary dictionary];
        for (NSString *k in @[ @"serverId", @"selectedServers", @"resources" ]) if (PXSettingGet(k)) state[k] = PXSettingGet(k);
        if (old) profiles[old] = state;
        NSDictionary *next = profiles[uuid] ?: @{};
        for (NSString *k in @[ @"serverId", @"selectedServers", @"resources" ]) PXSettingSet(k, next[k]);
        PXSettingSet(@"profiles", profiles);
        PXSettingSet(@"homeUserUUID", uuid);
        PXSettingSet(@"authToken", token);
        PXSettingSet(@"accountProfile", nil);
        [self->_servers removeAllObjects];
        self->_order = @[];
        [self loadCachedServers];
        PXLog(@"plex: switched to profile %@", user[@"title"]);
        [self refreshAccountProfile];
        [self fetchServers:^(NSArray *servers, NSError *e) {
            [[NSNotificationCenter defaultCenter] postNotificationName:PXHomeUserDidChange object:nil];
            done(user, e);
        }];
    }];
}

#pragma mark - Servers

// plist-safe copy of a plex.tv resource (no NSNull).
static id plistSafe(id v) {
    if ([v isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        [v enumerateKeysAndObjectsUsingBlock:^(id k, id o, BOOL *stop) { id c = plistSafe(o); if (c) d[k] = c; }];
        return d;
    }
    if ([v isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray array];
        for (id o in v) { id c = plistSafe(o); if (c) [a addObject:c]; }
        return a;
    }
    return ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) ? v : nil;
}

- (void)setResources:(NSArray *)resources {
    NSMutableArray *order = [NSMutableArray array];
    for (NSDictionary *r in resources) {
        NSString *sid = r[@"clientIdentifier"];
        if (!sid || [order containsObject:sid]) continue;   // plex.tv may list a server twice
        PXServer *s = _servers[sid];
        if (s) [s updateResource:r]; else _servers[sid] = [[PXServer alloc] initWithResource:r];
        [order addObject:sid];
    }
    _order = order;
}

// Servers known from the last plex.tv answer: the app starts offline-first.
- (void)loadCachedServers {
    NSArray *cached = PXSettingGet(@"resources");
    if ([cached isKindOfClass:[NSArray class]]) [self setResources:cached];
    // Single-server settings of earlier versions.
    NSString *oldId = PXSettingGet(@"serverId"), *oldURI = PXSettingGet(@"serverURI");
    if (oldId && oldURI) {
        NSMutableDictionary *uris = [PXSettingGet(@"serverURIs") mutableCopy] ?: [NSMutableDictionary dictionary];
        if (!uris[oldId]) { uris[oldId] = oldURI; PXSettingSet(@"serverURIs", uris); }
        if (!_servers[oldId]) {
            NSDictionary *r = @{ @"clientIdentifier": oldId, @"name": PXSettingGet(@"serverName") ?: @"Plex", @"owned": @YES, @"presence": @YES,
                                 @"accessToken": PXSettingGet(@"serverToken") ?: @"", @"connections": @[] };
            [self setResources:[@[ r ] arrayByAddingObjectsFromArray:[cached isKindOfClass:[NSArray class]] ? cached : @[]]];
        }
    }
}

- (void)fetchServers:(PXJSONBlock)done {
    NSString *url = [kPlexTV stringByAppendingString:@"/api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=1"];
    [self request:@"GET" url:url token:PXSettingGet(@"authToken") timeout:20 done:^(id json, NSError *err) {
        NSMutableArray *servers = [NSMutableArray array];
        if ([json isKindOfClass:[NSArray class]])
            for (NSDictionary *r in json)
                if ([r[@"provides"] containsString:@"server"]) [servers addObject:plistSafe(r)];
        if (servers.count) {
            PXSettingSet(@"resources", servers);
            [self setResources:servers];
        }
        done(servers, err);
    }];
}

- (NSArray *)servers {
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *sid in _order) if (_servers[sid]) [a addObject:_servers[sid]];
    return a;
}

- (PXServer *)serverWithID:(NSString *)identifier {
    if ([identifier isEqual:self.onlineProvider.identifier]) return self.onlineProvider;
    return identifier ? _servers[identifier] : nil;
}

#pragma mark - Online

- (PXServer *)onlineProvider {
    static PXServer *p;
    if (!p) p = [[PXServer alloc] initOnlineProvider:@"https://discover.provider.plex.tv" identifier:@"tv.plex.provider.discover" name:@"Plex"];
    return p;
}

static NSString *onlineKey(NSString *guid) {
    // plex://movie/5d77682e… -> 5d77682e… (the provider's ratingKey)
    return [guid hasPrefix:@"plex://"] ? [[guid componentsSeparatedByString:@"/"] lastObject] : nil;
}

- (void)fetchWatchlist:(PXJSONBlock)done {
    [self.onlineProvider get:@"/library/sections/watchlist/all?includeCollections=1&includeExternalMedia=1&X-Plex-Container-Size=100" done:^(NSDictionary *mc, NSError *err) {
        NSArray *items = [PXItem itemsWithJSON:mc[@"Metadata"]];
        if (mc) {
            NSMutableSet *keys = [NSMutableSet set];
            for (PXItem *it in items) if (it.ratingKey) [keys addObject:it.ratingKey];
            self->_watchlistKeys = keys;
        }
        if (done) done(items, err);
    }];
}

- (BOOL)isWatchlisted:(NSString *)guid { NSString *k = onlineKey(guid); return k && [_watchlistKeys containsObject:k]; }

- (void)setWatchlisted:(BOOL)on guid:(NSString *)guid done:(PXJSONBlock)done {
    NSString *k = onlineKey(guid);
    if (!k) { if (done) done(nil, nil); return; }
    NSString *path = [NSString stringWithFormat:@"/actions/%@?ratingKey=%@", on ? @"addToWatchlist" : @"removeFromWatchlist", k];
    [self.onlineProvider put:path done:^(id json, NSError *err) {
        if (!err) {
            NSMutableSet *keys = [self->_watchlistKeys mutableCopy] ?: [NSMutableSet set];
            if (on) [keys addObject:k]; else [keys removeObject:k];
            self->_watchlistKeys = keys;
        }
        PXLog(@"online: watchlist %@ %@ -> %@", on ? @"add" : @"remove", k, err ? err.localizedDescription : @"ok");
        if (done) done(@(on), err);
    }];
}

- (void)findLocalForGuid:(NSString *)guid done:(PXJSONBlock)done {
    NSMutableArray *servers = [NSMutableArray array];
    for (PXServer *s in [@[ self.primaryServer ?: [NSNull null] ] arrayByAddingObjectsFromArray:self.selectedServers])
        if ([s isKindOfClass:[PXServer class]] && s.connected && ![servers containsObject:s]) [servers addObject:s];
    if (!guid.length || !servers.count) { done(nil, nil); return; }
    __block NSInteger pending = servers.count;
    __block BOOL answered = NO;
    void (^finish)(PXItem *) = ^(PXItem *it) {
        if (answered) return;
        if (it || --pending == 0) { answered = YES; done(it, nil); }
    };
    for (PXServer *s in servers) {
        [s get:[@"/library/all?guid=" stringByAppendingString:PXEncode(guid)] done:^(NSDictionary *mc, NSError *err) {
            finish([PXItem itemsWithJSON:mc[@"Metadata"]].firstObject);
        }];
    }
    // Slow servers do not hold the answer forever.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ if (!answered) { answered = YES; done(nil, nil); } });
}

- (void)searchOnline:(NSString *)query done:(PXJSONBlock)done {
    NSString *path = [NSString stringWithFormat:@"/library/search?query=%@&limit=20&searchTypes=movies,tv&searchProviders=discover&includeMetadata=1", PXEncode(query)];
    [self.onlineProvider get:path done:^(NSDictionary *mc, NSError *err) {
        NSMutableArray *raw = [NSMutableArray array];
        for (NSDictionary *r in mc[@"SearchResults"])
            for (NSDictionary *x in r[@"SearchResult"]) {
                NSMutableDictionary *m = [x[@"Metadata"] mutableCopy];
                if (![m isKindOfClass:[NSDictionary class]]) continue;
                m[@"_server"] = self.onlineProvider.identifier;   // nested: not tagged by get
                [raw addObject:m];
            }
        PXLog(@"online: search '%@' -> %lu%@", query, (unsigned long)raw.count, err ? [@" " stringByAppendingString:err.localizedDescription] : @"");
        done([PXItem itemsWithJSON:raw], err);
    }];
}

- (PXServer *)primaryServer {
    PXServer *s = [self serverWithID:PXSettingGet(@"serverId")];
    if (s) return s;
    for (PXServer *o in self.servers) if (o.owned) return o;
    return self.servers.firstObject;
}

- (void)setPrimaryServer:(PXServer *)server {
    PXSettingSet(@"serverId", server.identifier);
    PXSettingSet(@"serverName", server.name);
}

- (NSArray *)selectedServers {
    NSArray *ids = PXSettingGet(@"selectedServers");
    NSMutableArray *a = [NSMutableArray array];
    if ([ids isKindOfClass:[NSArray class]]) for (NSString *sid in ids) if (_servers[sid]) [a addObject:_servers[sid]];
    if (!a.count && self.primaryServer) [a addObject:self.primaryServer];
    return a;
}

- (BOOL)hasServerSelection { return [PXSettingGet(@"selectedServers") isKindOfClass:[NSArray class]]; }

- (void)setSelectedServers:(NSArray *)servers {
    PXSettingSet(@"selectedServers", [servers valueForKey:@"identifier"] ?: @[]);
    [[NSNotificationCenter defaultCenter] postNotificationName:PXSelectedServersDidChange object:self];
}

- (void)serverDidConnect:(PXServer *)server {
    // Keep the single-server keys of earlier versions in sync (settings screen, BIF).
    if (server == self.primaryServer) {
        PXSettingSet(@"serverURI", server.uri);
        PXSettingSet(@"serverToken", server.token);
    }
}

- (void)connectToServer:(NSDictionary *)resource done:(PXJSONBlock)done {
    [self setResources:[self.servers.count ? [self.servers valueForKey:@"resource"] : @[] arrayByAddingObject:resource]];
    PXServer *s = [self serverWithID:resource[@"clientIdentifier"]];
    [self setPrimaryServer:s];
    [s connect:done];
}

- (void)reconnect:(PXJSONBlock)done {
    [self fetchServers:^(NSArray *servers, NSError *err) {
        PXServer *s = self.primaryServer;
        if (!s) { done(nil, err ?: [NSError errorWithDomain:@"PXPlex" code:3 userInfo:@{ NSLocalizedDescriptionKey: PXL(@"Aucun serveur sur ce compte") }]); return; }
        [s reconnect:done];
    }];
}

// Server of an item / metadata dictionary (tagged by -[PXServer get:]), else the primary one.
- (PXServer *)serverFor:(NSDictionary *)metadata {
    return [self serverWithID:[metadata isKindOfClass:[NSDictionary class]] ? metadata[@"_server"] : nil] ?: self.primaryServer;
}

#pragma mark - PMS (primary server, or the server of the given item)

- (void)get:(NSString *)path done:(PXJSONBlock)done { [self.primaryServer get:path done:done]; }
- (void)put:(NSString *)path { [self.primaryServer put:path done:nil]; }
- (void)put:(NSString *)path done:(PXJSONBlock)done { [self.primaryServer put:path done:done]; }
- (NSURL *)imageURL:(NSString *)thumb width:(int)w height:(int)h { return [self.primaryServer imageURL:thumb width:w height:h]; }
- (NSURL *)artURL:(NSString *)art width:(int)w height:(int)h blur:(int)blur { return [self.primaryServer artURL:art width:w height:h blur:blur]; }
- (void)metadata:(NSString *)ratingKey done:(PXJSONBlock)done { [self.primaryServer metadata:ratingKey done:done]; }

- (void)preparePlayback:(NSDictionary *)metadata offset:(double)seconds done:(PXJSONBlock)done {
    [[self serverFor:metadata] preparePlayback:metadata offset:seconds done:done];
}
- (void)reportTimeline:(NSDictionary *)metadata state:(NSString *)state timeMs:(long long)t {
    [[self serverFor:metadata] reportTimeline:metadata state:state timeMs:t];
}
- (void)stopTranscode:(NSString *)session { [self.primaryServer stopTranscode:session]; }
- (void)setWatched:(BOOL)watched item:(NSDictionary *)metadata { [[self serverFor:metadata] setWatched:watched item:metadata]; }
- (void)selectStreamsForPart:(NSDictionary *)part audio:(NSInteger)audioID subtitle:(NSInteger)subtitleID done:(PXJSONBlock)done {
    [self.primaryServer selectStreamsForPart:part audio:audioID subtitle:subtitleID done:done];
}

@end
