// One Plex Media Server of the account (plex.tv resource): connection and
// every request that belongs to it. Items remember the server they come from
// (key "_server" added to each Metadata / Directory dictionary by -get:), so
// images, playback and progress reports go back to the right server.
// All completion blocks are called on the main queue.

#import <Foundation/Foundation.h>
#import "PXPlex.h"

@interface PXServer : NSObject

- (instancetype)initWithResource:(NSDictionary *)resource;
// Plex online provider (discover.provider.plex.tv: watchlist, online search),
// used like a server; images through the public images.plex.tv transcoder.
- (instancetype)initOnlineProvider:(NSString *)baseURL identifier:(NSString *)identifier name:(NSString *)name;
@property (nonatomic, readonly) BOOL provider;   // online provider, not a media server
- (void)updateResource:(NSDictionary *)resource;   // fresher plex.tv data, keeps the connection

@property (nonatomic, readonly) NSString *identifier;   // clientIdentifier
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *sourceTitle;  // owner's name for shared servers
@property (nonatomic, readonly) BOOL owned;
@property (nonatomic, readonly) BOOL online;            // plex.tv presence
@property (nonatomic, readonly) NSDictionary *resource;

// Connection: best working address, probed once and remembered.
@property (nonatomic, readonly) NSString *uri;
@property (nonatomic, readonly) NSString *token;
@property (nonatomic, readonly) BOOL connected;
- (void)connect:(PXJSONBlock)done;     // json: the chosen connection
- (void)reconnect:(PXJSONBlock)done;   // forget the address, probe again

// PMS API
- (void)get:(NSString *)path done:(PXJSONBlock)done;        // json: MediaContainer dict
- (void)put:(NSString *)path done:(PXJSONBlock)done;
- (NSURL *)imageURL:(NSString *)thumb width:(int)w height:(int)h;
- (NSURL *)artURL:(NSString *)art width:(int)w height:(int)h blur:(int)blur;
- (void)metadata:(NSString *)ratingKey done:(PXJSONBlock)done;   // json: Metadata[0] dict

// Playback (see PXPlex.h)
- (void)preparePlayback:(NSDictionary *)metadata offset:(double)seconds done:(PXJSONBlock)done;
- (void)reportTimeline:(NSDictionary *)metadata state:(NSString *)state timeMs:(long long)t;
- (void)stopTranscode:(NSString *)session;
- (void)setWatched:(BOOL)watched item:(NSDictionary *)metadata;
- (void)selectStreamsForPart:(NSDictionary *)part audio:(NSInteger)audioID subtitle:(NSInteger)subtitleID done:(PXJSONBlock)done;
// Music: json {url, directPlay, session (server conversion)}.
- (void)prepareAudio:(NSDictionary *)track done:(PXJSONBlock)done;
- (void)prepareAudio:(NSDictionary *)track convert:(BOOL)convert done:(PXJSONBlock)done;   // convert: never direct
- (void)stopAudioTranscode:(NSString *)session;
// Plain text resource of the server (lyrics streams), nil on failure.
- (void)getText:(NSString *)path done:(void (^)(NSString *text))done;
- (NSString *)plexQuery;   // identification + token query string (AVPlayer URLs)

@end

// Device of a server whose name is shared by another one of the list
// (platform: "MacOSX", "Linux"…), nil when its name is unique.
NSString *PXServerTwinLabel(NSDictionary *resource, NSArray *resources);
