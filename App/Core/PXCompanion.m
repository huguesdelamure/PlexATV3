// Plex Companion: lets the Plex mobile apps find this Apple TV on the local
// network and control playback ("cast").
//  - GDM: answers the "M-SEARCH" of the apps (UDP 32412, multicast
//    239.0.0.250) and announces itself (HELLO / BYE on 32413);
//  - HTTP on TCP 32500: /resources, /player/playback/*, /player/timeline/*;
//  - timelines pushed every second to the subscribed apps.
// Started by the appliance, stopped by Réglages ("companion" = NO).

#import "PXCompanion.h"
#import "PXRouter.h"
#import "PXBackRow.h"
#import "PXPlex.h"
#import "PXServer.h"
#import "PXItem.h"
#import "PXMusicPlayer.h"
#import "PXSettings.h"
#import "PXLog.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <libkern/OSAtomic.h>

static const uint16_t kHTTPPort = 32500, kGDMPort = 32412, kGDMHelloPort = 32413;
static const char *kGDMGroup = "239.0.0.250";
static BOOL isLocalAddress(struct in_addr a);

@interface PXCompanionSubscriber : NSObject
@property (nonatomic, copy) NSString *clientId, *host, *protocol;
@property (nonatomic) int port;
@property (nonatomic) NSInteger commandID;
@end
@implementation PXCompanionSubscriber
@end

@implementation PXCompanion {
    int _httpFd, _gdmFd;
    BOOL _running;
    NSInteger _generation;             // threads of an earlier start() exit
    volatile int32_t _connections;     // HTTP requests being served
    NSMutableDictionary *_subscribers;   // clientId -> subscriber
    dispatch_source_t _pushTimer;
    NSInteger _commandID;
    NSString *_lastState;
}

+ (instancetype)shared {
    static PXCompanion *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [PXCompanion new]; });
    return c;
}

+ (BOOL)enabled { return ![PXSettingGet(@"companion") isEqual:@NO]; }

- (NSString *)deviceName { return @"Apple TV (PlexATV3)"; }

- (NSString *)version { return [PXKitBundle() objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0"; }

#pragma mark - Start / stop

- (void)start {
    if (_running || ![PXCompanion enabled]) return;
    _running = YES;
    _subscribers = [NSMutableDictionary dictionary];
    _httpFd = [self listenTCP:kHTTPPort];
    _gdmFd = [self listenGDM];
    _generation++;
    // Each thread owns its fd and generation: a stop/start cycle never leaves
    // two threads on one socket.
    if (_httpFd >= 0) [NSThread detachNewThreadSelector:@selector(acceptLoop:) toTarget:self withObject:@[ @(_httpFd), @(_generation) ]];
    if (_gdmFd >= 0) [NSThread detachNewThreadSelector:@selector(gdmLoop:) toTarget:self withObject:@[ @(_gdmFd), @(_generation) ]];
    [self sendGDM:@"HELLO * HTTP/1.0"];
    PXLog(@"companion: http %@, gdm %@", _httpFd >= 0 ? @"ok" : @"failed", _gdmFd >= 0 ? @"ok" : @"failed");
    _pushTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_pushTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 4);
    __weak PXCompanion *weak = self;
    dispatch_source_set_event_handler(_pushTimer, ^{ [weak pushTimelines]; });
    dispatch_resume(_pushTimer);
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    [self sendGDM:@"BYE * HTTP/1.0"];
    if (_pushTimer) dispatch_source_cancel(_pushTimer);
    _pushTimer = nil;
    _generation++;
    // shutdown() wakes the blocked accept()/recvfrom(), close() alone may not.
    if (_httpFd >= 0) { shutdown(_httpFd, SHUT_RDWR); close(_httpFd); }
    if (_gdmFd >= 0) { shutdown(_gdmFd, SHUT_RDWR); close(_gdmFd); }
    _httpFd = _gdmFd = -1;
    [_subscribers removeAllObjects];
    PXLog(@"companion: stopped");
}

#pragma mark - Sockets

- (int)listenTCP:(uint16_t)port {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    struct sockaddr_in a = { .sin_len = sizeof a, .sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_ANY) };
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0 || listen(fd, 8) < 0) { close(fd); return -1; }
    return fd;
}

- (int)listenGDM {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof yes);
    struct sockaddr_in a = { .sin_len = sizeof a, .sin_family = AF_INET, .sin_port = htons(kGDMPort), .sin_addr.s_addr = htonl(INADDR_ANY) };
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) { close(fd); return -1; }
    struct ip_mreq m = { .imr_multiaddr.s_addr = inet_addr(kGDMGroup), .imr_interface.s_addr = htonl(INADDR_ANY) };
    setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &m, sizeof m);
    return fd;
}

- (NSString *)gdmHeaders {
    return [NSString stringWithFormat:
        @"Content-Type: plex/media-player\r\nResource-Identifier: %@\r\nName: %@\r\nPort: %d\r\nProduct: PlexATV3\r\n"
        @"Version: %@\r\nProtocol: plex\r\nProtocol-Version: 1\r\nProtocol-Capabilities: timeline,playback,playqueues\r\n"
        @"Device-Class: stb\r\n\r\n", PXClientId(), [self deviceName], kHTTPPort, [self version]];
}

- (void)sendGDM:(NSString *)first {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return;
    NSData *d = [[NSString stringWithFormat:@"%@\r\n%@", first, [self gdmHeaders]] dataUsingEncoding:NSUTF8StringEncoding];
    struct sockaddr_in a = { .sin_len = sizeof a, .sin_family = AF_INET, .sin_port = htons(kGDMHelloPort), .sin_addr.s_addr = inet_addr(kGDMGroup) };
    sendto(fd, d.bytes, d.length, 0, (struct sockaddr *)&a, sizeof a);
    close(fd);
}

- (void)gdmLoop:(NSArray *)args {
    int fd = [args[0] intValue];
    NSInteger gen = [args[1] integerValue];
    char buf[2048];
    while (_running && gen == _generation) {
        struct sockaddr_in from; socklen_t len = sizeof from;
        ssize_t n = recvfrom(fd, buf, sizeof buf - 1, 0, (struct sockaddr *)&from, &len);
        if (n <= 0) { if (!_running || gen != _generation) break; usleep(100 * 1000); continue; }
        if (!isLocalAddress(from.sin_addr)) continue;
        buf[n] = 0;
        if (strncmp(buf, "M-SEARCH", 8) != 0) continue;
        NSData *d = [[@"HTTP/1.0 200 OK\r\n" stringByAppendingString:[self gdmHeaders]] dataUsingEncoding:NSUTF8StringEncoding];
        sendto(fd, d.bytes, d.length, 0, (struct sockaddr *)&from, len);
    }
}

// Private networks only: the protocol has no authentication.
static BOOL isLocalAddress(struct in_addr a) {
    uint32_t ip = ntohl(a.s_addr);
    return (ip >> 24) == 10 || (ip >> 24) == 127 || (ip >> 20) == 0xAC1 || (ip >> 16) == 0xC0A8 || (ip >> 16) == 0xA9FE;
}

- (void)acceptLoop:(NSArray *)args {
    int fd = [args[0] intValue];
    NSInteger gen = [args[1] integerValue];
    while (_running && gen == _generation) {
        struct sockaddr_in from; socklen_t len = sizeof from;
        int c = accept(fd, (struct sockaddr *)&from, &len);
        if (c < 0) { if (!_running || gen != _generation) break; usleep(100 * 1000); continue; }
        int yes = 1;
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof yes);   // a client leaving early must not kill the process
        if (!isLocalAddress(from.sin_addr) || OSAtomicIncrement32(&_connections) > 8) {
            if (isLocalAddress(from.sin_addr)) OSAtomicDecrement32(&_connections);
            close(c);
            continue;
        }
        NSString *host = [NSString stringWithUTF8String:inet_ntoa(from.sin_addr)];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self serve:c from:host];
            OSAtomicDecrement32(&self->_connections);
        });
    }
}

#pragma mark - HTTP

static NSDictionary *queryOf(NSString *q) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *pair in [q componentsSeparatedByString:@"&"]) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [[pair substringToIndex:eq.location] stringByRemovingPercentEncoding];
        NSString *v = [[[pair substringFromIndex:eq.location + 1] stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByRemovingPercentEncoding];
        if (k && v) d[k] = v;
    }
    return d;
}

- (void)serve:(int)fd from:(NSString *)host {
    struct timeval tv = { .tv_sec = 5 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    NSMutableData *req = [NSMutableData data];
    char buf[4096];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];   // whole request, not per recv()
    while (req.length < 65536 && [deadline timeIntervalSinceNow] > 0) {
        ssize_t n = recv(fd, buf, sizeof buf, 0);
        if (n <= 0) break;
        [req appendBytes:buf length:n];
        if ([req rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, req.length)].location != NSNotFound) break;
    }
    NSString *text = [[NSString alloc] initWithData:req encoding:NSUTF8StringEncoding] ?: @"";
    NSArray *lines = [text componentsSeparatedByString:@"\r\n"];
    NSArray *first = [lines.firstObject componentsSeparatedByString:@" "];
    NSString *method = first.count > 1 ? first[0] : @"GET";
    NSString *target = first.count > 1 ? first[1] : @"/";
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (NSString *l in lines) {
        NSRange c = [l rangeOfString:@": "];
        if (c.location != NSNotFound) headers[[[l substringToIndex:c.location] lowercaseString]] = [l substringFromIndex:c.location + 2];
    }
    NSRange q = [target rangeOfString:@"?"];
    NSString *path = q.location == NSNotFound ? target : [target substringToIndex:q.location];
    NSDictionary *params = q.location == NSNotFound ? @{} : queryOf([target substringFromIndex:q.location + 1]);
    // Long poll: give the state a moment to change instead of a busy loop.
    if ([path isEqual:@"/player/timeline/poll"] && [params[@"wait"] isEqual:@"1"]) usleep(900 * 1000);
    __block NSString *body = nil;
    if ([method isEqual:@"OPTIONS"]) body = @"";
    else dispatch_sync(dispatch_get_main_queue(), ^{ body = [self handle:path params:params headers:headers host:host]; });
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\nContent-Type: text/xml; charset=utf-8\r\nContent-Length: %lu\r\nConnection: close\r\n"
        @"X-Plex-Client-Identifier: %@\r\n\r\n", (unsigned long)[body lengthOfBytesUsingEncoding:NSUTF8StringEncoding], PXClientId()];
    NSMutableData *out = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [out appendData:[body dataUsingEncoding:NSUTF8StringEncoding]];
    send(fd, out.bytes, out.length, 0);
    close(fd);
}

static NSString *ok(void) { return @"<?xml version=\"1.0\" encoding=\"UTF-8\"?><Response code=\"200\" status=\"OK\"/>"; }

- (NSString *)handle:(NSString *)path params:(NSDictionary *)p headers:(NSDictionary *)h host:(NSString *)host {
    NSString *client = h[@"x-plex-client-identifier"] ?: p[@"X-Plex-Client-Identifier"] ?: host;
    if (p[@"commandID"]) _commandID = [p[@"commandID"] integerValue];
    if ([path isEqual:@"/resources"]) {
        return [NSString stringWithFormat:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?><MediaContainer size=\"1\">"
                @"<Player title=\"%@\" protocol=\"plex\" protocolVersion=\"1\" protocolCapabilities=\"timeline,playback,playqueues\" "
                @"machineIdentifier=\"%@\" product=\"PlexATV3\" platform=\"iOS\" platformVersion=\"8.4\" deviceClass=\"stb\"/></MediaContainer>",
                [self deviceName], PXClientId()];
    }
    if ([path isEqual:@"/player/timeline/subscribe"]) {
        PXCompanionSubscriber *s = [PXCompanionSubscriber new];
        s.clientId = client; s.host = host; s.port = [p[@"port"] intValue] ?: 32400;
        s.protocol = p[@"protocol"] ?: @"http"; s.commandID = [p[@"commandID"] integerValue];
        _subscribers[client] = s;
        PXLog(@"companion: %@ subscribed", host);
        _lastState = nil;   // the new subscriber gets the current state now
        [self pushTimelines];
        return ok();
    }
    if ([path isEqual:@"/player/timeline/unsubscribe"]) { [_subscribers removeObjectForKey:client]; return ok(); }
    if ([path isEqual:@"/player/timeline/poll"]) return [self timelineXML];
    if ([path isEqual:@"/player/playback/playMedia"]) { [self playMedia:p]; return ok(); }
    if ([path hasPrefix:@"/player/playback/"]) {
        NSString *cmd = [path substringFromIndex:17];
        PXMusicPlayer *mp = [PXMusicPlayer shared];
        if (mp.active && !PXVideoPlayerState()) {
            if ([cmd isEqual:@"play"] || [cmd isEqual:@"pause"]) { if (([cmd isEqual:@"play"]) != mp.playing) [mp togglePause]; }
            else if ([cmd isEqual:@"skipNext"]) [mp next];
            else if ([cmd isEqual:@"skipPrevious"]) [mp previous];
            else if ([cmd isEqual:@"stop"]) [mp stop];
        } else {
            PXVideoPlayerControl(cmd, [p[@"offset"] doubleValue] / 1000);
        }
        if ([cmd isEqual:@"setParameters"] && p[@"volume"]) mp.volume = [p[@"volume"] floatValue] / 100;   // shared with the video player
        PXLog(@"companion: %@ from %@", cmd, host);
        return ok();
    }
    return ok();
}

- (void)playMedia:(NSDictionary *)p {
    NSString *key = p[@"key"];
    NSString *rk = [[key componentsSeparatedByString:@"/"] lastObject];
    if (!rk.length) return;
    PXServer *server = [[PXPlex shared] serverWithID:p[@"machineIdentifier"]] ?: [PXPlex shared].primaryServer;
    double offset = [p[@"offset"] doubleValue] / 1000;
    PXLog(@"companion: playMedia %@ on %@ at %.0f s", rk, server.name, offset);
    id stack = [[PXCls("BRApplicationStackManager") singleton] stack];
    if ([p[@"type"] isEqual:@"music"]) {
        [server metadata:rk done:^(NSDictionary *m, NSError *err) {
            if (!m) return;
            [[PXMusicPlayer shared] playTracks:@[ [PXItem itemWithJSON:m] ] startAt:0 shuffle:NO];
            if (!PXNowPlayingIsShown()) [stack pushController:PXHostControllerForScreen(PXNowPlayingScreenNew())];
        }];
        return;
    }
    PXVideoPlayerControl(@"stop", 0);
    PXItem *it = [PXItem itemWithJSON:@{ @"ratingKey": rk, @"type": @"movie", @"_server": server.identifier ?: @"" }];
    [stack pushController:PXHostControllerForScreen(PXPlayerScreenNew(it, offset > 0 ? offset : -1))];
}

#pragma mark - Timelines

- (NSString *)timelineXML {
    NSDictionary *v = PXVideoPlayerState();
    PXMusicPlayer *mp = [PXMusicPlayer shared];
    NSString *(^line)(NSString *, NSString *, NSDictionary *) = ^NSString *(NSString *type, NSString *state, NSDictionary *d) {
        if (!d) return [NSString stringWithFormat:@"<Timeline type=\"%@\" state=\"stopped\"/>", type];
        PXServer *s = [[PXPlex shared] serverWithID:d[@"server"]];
        NSURL *u = [NSURL URLWithString:s.uri ?: @""];
        return [NSString stringWithFormat:@"<Timeline type=\"%@\" state=\"%@\" time=\"%.0f\" duration=\"%.0f\" ratingKey=\"%@\" "
                @"key=\"/library/metadata/%@\" machineIdentifier=\"%@\" address=\"%@\" port=\"%@\" protocol=\"%@\" volume=\"%.0f\" controllable=\"%@\"/>",
                type, state, [d[@"time"] doubleValue] * 1000, [d[@"duration"] doubleValue] * 1000, d[@"ratingKey"], d[@"ratingKey"],
                d[@"server"] ?: @"", u.host ?: @"", u.port ?: @32400, u.scheme ?: @"https", mp.volume * 100,
                @"playPause,stop,seekTo,skipPrevious,skipNext,stepBack,stepForward,volume"];
    };
    NSDictionary *music = mp.active ? @{ @"time": @(mp.elapsed), @"duration": @(mp.duration), @"ratingKey": mp.current.ratingKey ?: @"",
                                         @"server": mp.current.server.identifier ?: @"" } : nil;
    return [NSString stringWithFormat:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?><MediaContainer commandID=\"%ld\" location=\"%@\">%@%@%@</MediaContainer>",
            (long)_commandID, v ? @"fullScreenVideo" : (music ? @"fullScreenMusic" : @"navigation"),
            line(@"video", v[@"state"], v), line(@"music", mp.playing ? @"playing" : @"paused", music), line(@"photo", nil, nil)];
}

- (void)pushTimelines {
    if (!_subscribers.count) return;
    NSString *xml = [self timelineXML];
    // Every second while something plays, else only when the state changes.
    BOOL idle = !PXVideoPlayerState() && ![PXMusicPlayer shared].active;
    if (idle && [xml isEqual:_lastState]) return;
    _lastState = xml;
    for (PXCompanionSubscriber *s in _subscribers.allValues) {
        NSString *u = [NSString stringWithFormat:@"%@://%@:%d/:/timeline", s.protocol, s.host, s.port];
        NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u]];
        r.HTTPMethod = @"POST";
        r.timeoutInterval = 3;
        r.HTTPBody = [xml dataUsingEncoding:NSUTF8StringEncoding];
        [r setValue:@"text/xml" forHTTPHeaderField:@"Content-Type"];
        [r setValue:PXClientId() forHTTPHeaderField:@"X-Plex-Client-Identifier"];
        [r setValue:@"PlexATV3" forHTTPHeaderField:@"X-Plex-Product"];
        [r setValue:[self deviceName] forHTTPHeaderField:@"X-Plex-Device-Name"];
        NSString *cid = s.clientId;
        __weak PXCompanion *weak = self;
        [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
            if (!e) return;
            // An app that went away: drop it.
            dispatch_async(dispatch_get_main_queue(), ^{ PXCompanion *me = weak; if (me) [me->_subscribers removeObjectForKey:cid]; });
        }] resume];
    }
}

@end
