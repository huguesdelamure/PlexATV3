#import "PXPlex.h"
#import "PXLocalize.h"
#import "PXSettings.h"
#import "PXLog.h"
#import "PXItem.h"
#import "PXServer.h"
#import <Security/Security.h>

NSString *const PXSelectedServersDidChange = @"PXSelectedServersDidChange";
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
    if ([url rangeOfString:@"X-Plex-Container-Size"].location == NSNotFound) {
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

- (void)saveAuthToken:(NSString *)token { PXSettingSet(@"authToken", token); [self refreshAccountProfile]; }

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
    for (NSString *k in @[ @"authToken", @"serverId", @"serverName", @"serverURI", @"serverToken", @"serverURIs", @"resources", @"selectedServers" ])
        PXSettingSet(k, nil);
    [_servers removeAllObjects];
    _order = @[];
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
    return identifier ? _servers[identifier] : nil;
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
