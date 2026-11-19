#import "PXPlex.h"
#import "PXLocalize.h"
#import "PXSettings.h"
#import "PXLog.h"
#import "PXItem.h"
#import "PXServer.h"
#import "PXImageCache.h"
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
    NSDictionary *_headers;          // identification headers, for _headersLanguage
    NSString *_headersLanguage;
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
        // Watch state changes on other clients: never answer from a local cache.
        cfg.URLCache = nil;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.HTTPMaximumConnectionsPerHost = 4;
        // Callbacks (and JSON parsing, slow on the A5) off the main thread;
        // results are handed back on the main queue.
        NSOperationQueue *q = [NSOperationQueue new];
        q.maxConcurrentOperationCount = 2;
        _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:q];
        // Image downloads go to the same servers: same TLS trust.
        [[PXImageCache shared] setTrustDelegate:self];
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

// Built once; only the UI language can change while the app runs (the
// token is not part of them).
- (NSDictionary *)plexHeaders {
    NSString *language = PXLanguage();
    @synchronized (self) {
        if (!_headers || ![_headersLanguage isEqualToString:language]) {
            _headersLanguage = language;
            _headers = @{ @"X-Plex-Client-Identifier": PXClientId(),
                          @"X-Plex-Product": kProduct,
                          @"X-Plex-Version": appVersion(),
                          @"X-Plex-Platform": @"iOS",
                          @"X-Plex-Platform-Version": @"8.4",
                          @"X-Plex-Device": @"Apple TV",
                          @"X-Plex-Model": @"AppleTV3,2",
                          @"X-Plex-Device-Name": @"Apple TV (PlexATV)",
                          @"X-Plex-Language": language ?: @"en",   // metadata (summaries, genres) in the UI language
                          @"Accept": @"application/json" };
        }
        return _headers;
    }
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
    NSURL *u = [url isKindOfClass:[NSString class]] ? [NSURL URLWithString:url] : nil;
    if (!u) {
        PXLog(@"http %@: invalid URL", method);
        NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL userInfo:nil];
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(nil, err); });
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
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
    // Some PMS routes (watch history) ignore paging in the query string: send it
    // as headers too.
    for (NSString *q in [req.URL.query componentsSeparatedByString:@"&"]) {
        if ([q hasPrefix:@"X-Plex-Container-Size="] || [q hasPrefix:@"X-Plex-Container-Start="]) {
            NSArray *kv = [q componentsSeparatedByString:@"="];
            if (kv.count == 2) [req setValue:kv[1] forHTTPHeaderField:kv[0]];
        }
    }
    if ([req valueForHTTPHeaderField:@"X-Plex-Container-Size"] && ![req valueForHTTPHeaderField:@"X-Plex-Container-Start"])
        [req setValue:@"0" forHTTPHeaderField:@"X-Plex-Container-Start"];
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
    self.watchlistKeys = nil;
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
    for (NSDictionary *u in self.homeUsers) if ([u isKindOfClass:[NSDictionary class]] && (uuid ? [u[@"uuid"] isEqual:uuid] : PXJSONBool(u[@"admin"]))) return u;
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
            if (err.code == 401 || err.code == 403 || err.code == 422) err = nil;   // wrong PIN
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
        // Linked before profiles existed: keep the account token before replacing it.
        if (!PXSettingGet(@"accountToken")) PXSettingSet(@"accountToken", PXSettingGet(@"authToken"));
        PXSettingSet(@"authToken", token);
        self.watchlistKeys = nil;   // the other profile's watchlist
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
        NSString *sid = PXJSONString(PXJSONDict(r)[@"clientIdentifier"]);
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
                if ([PXJSONString(PXJSONDict(r)[@"provides"]) containsString:@"server"]) [servers addObject:plistSafe(r)];
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

// Pages of 100 (the provider refuses more), up to 1000 titles: the first page
// gives the total, the others are fetched together, kept in order.
static const NSInteger kWatchlistPage = 100, kWatchlistMax = 1000;

- (void)fetchWatchlistPage:(NSInteger)page done:(PXJSONBlock)done {
    NSString *path = [NSString stringWithFormat:@"/library/sections/watchlist/all?includeCollections=1&includeExternalMedia=1"
                      @"&X-Plex-Container-Start=%ld&X-Plex-Container-Size=%ld", (long)(page * kWatchlistPage), (long)kWatchlistPage];
    [self.onlineProvider get:path done:done];
}

- (void)fetchWatchlist:(PXJSONBlock)done {
    [self fetchWatchlistPage:0 done:^(NSDictionary *mc, NSError *err) {
        NSArray *first = [PXItem itemsWithJSON:mc[@"Metadata"]];
        NSInteger total = MIN((NSInteger)PXJSONNumber(mc[@"totalSize"]), kWatchlistMax);
        NSInteger pages = (total + kWatchlistPage - 1) / kWatchlistPage;
        if (err || !mc || (NSInteger)first.count < kWatchlistPage || pages <= 1) {
            [self finishWatchlist:@[ first ] ok:(!err && mc) error:err done:done];
            return;
        }
        NSMutableArray *slots = [NSMutableArray arrayWithObject:first];
        for (NSInteger p = 1; p < pages; p++) [slots addObject:@[]];
        __block NSInteger pending = pages - 1;
        __block NSError *firstError = nil;
        for (NSInteger p = 1; p < pages; p++) {
            [self fetchWatchlistPage:p done:^(NSDictionary *pmc, NSError *perr) {
                slots[p] = [PXItem itemsWithJSON:pmc[@"Metadata"]];
                if (!firstError && (perr || !pmc)) firstError = perr ?: [NSError errorWithDomain:@"PXPlex" code:5 userInfo:nil];
                if (--pending == 0) [self finishWatchlist:slots ok:!firstError error:firstError done:done];
            }];
        }
    }];
}

// ok: every page arrived, the watchlist keys can be replaced.
- (void)finishWatchlist:(NSArray *)pages ok:(BOOL)ok error:(NSError *)err done:(PXJSONBlock)done {
    NSMutableArray *all = [NSMutableArray array];
    for (NSArray *items in pages) [all addObjectsFromArray:items];
    if (ok) {
        NSMutableSet *keys = [NSMutableSet set];
        for (PXItem *it in all) if (it.ratingKey) [keys addObject:it.ratingKey];
        self.watchlistKeys = keys;
    }
    if (done) done(all, err);
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
        NSString *path = [NSString stringWithFormat:@"/library/all?guid=%@&X-Plex-Container-Start=0&X-Plex-Container-Size=1", PXEncode(guid)];
        [s get:path done:^(NSDictionary *mc, NSError *err) {
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
        for (NSDictionary *r in PXJSONArray(mc[@"SearchResults"]))
            for (NSDictionary *x in PXJSONArray(PXJSONDict(r)[@"SearchResult"])) {
                if (![x isKindOfClass:[NSDictionary class]] || ![x[@"Metadata"] isKindOfClass:[NSDictionary class]]) continue;
                NSMutableDictionary *m = [x[@"Metadata"] mutableCopy];
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

- (void)preparePlayback:(NSDictionary *)metadata offset:(double)seconds done:(PXJSONBlock)done {
    [[self serverFor:metadata] preparePlayback:metadata offset:seconds done:done];
}
- (void)reportTimeline:(NSDictionary *)metadata state:(NSString *)state timeMs:(long long)t {
    [[self serverFor:metadata] reportTimeline:metadata state:state timeMs:t];
}
- (void)setWatched:(BOOL)watched item:(NSDictionary *)metadata { [[self serverFor:metadata] setWatched:watched item:metadata]; }

@end
