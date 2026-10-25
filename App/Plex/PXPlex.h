// Plex client: plex.tv auth (PIN), server discovery, PMS JSON API,
// playback URL decision (direct play vs HLS transcode), timeline reporting.
// All completion blocks are called on the main queue.

#import <Foundation/Foundation.h>

typedef void (^PXJSONBlock)(id json, NSError *error);
@class PXServer;

@interface PXPlex : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL isLinked;      // have a plex.tv token
@property (nonatomic, readonly) BOOL hasServer;     // have a working server URI
@property (nonatomic, readonly) NSString *serverName;

// --- plex.tv (served through clients.plex.tv: plex.tv itself fails TLS on iOS 8)
- (void)createPin:(PXJSONBlock)done;                        // json: {id, code}
- (void)checkPin:(NSNumber *)pinId done:(PXJSONBlock)done;  // json: {authToken|null}
- (void)saveAuthToken:(NSString *)token;
- (void)signOut;
- (void)fetchServers:(PXJSONBlock)done;                     // json: array of server resources
// plex.tv account profile (defaultAudioLanguage, defaultSubtitleLanguage,
// defaultSubtitleForced, ...), cached in the settings, refreshed in the background.
- (NSDictionary *)accountProfile;
- (void)refreshAccountProfile;
// Probe every connection of a server resource, keep the best working one.
- (void)connectToServer:(NSDictionary *)resource done:(PXJSONBlock)done;
// Re-probe the saved server (its address may have changed).
- (void)reconnect:(PXJSONBlock)done;

// --- Servers of the account (PXServer.h). The primary server is the one
// chosen at link time (settings), used by the calls below without an item.
@property (nonatomic, readonly) NSArray *servers;          // PXServer, plex.tv order
@property (nonatomic, strong) PXServer *primaryServer;
@property (nonatomic, readonly) BOOL hasServerSelection;   // chosen at first launch
@property (nonatomic, copy) NSArray *selectedServers;      // shown on the home; default: primary
- (PXServer *)serverWithID:(NSString *)identifier;
- (PXServer *)serverFor:(NSDictionary *)metadata;          // server of an item, else primary

// --- PMS (primary server; item-based calls go to the item's server)
- (void)get:(NSString *)path done:(PXJSONBlock)done;        // json: MediaContainer dict
- (void)put:(NSString *)path;                               // fire and forget
- (void)put:(NSString *)path done:(PXJSONBlock)done;
- (NSURL *)imageURL:(NSString *)thumb width:(int)w height:(int)h;
// Background art, optionally blurred by the server (blur radius in px, 0 = none).
- (NSURL *)artURL:(NSString *)art width:(int)w height:(int)h blur:(int)blur;

// Playback
// Decides direct play vs server stream (asks the server for a decision) and
// returns {url, directPlay, session (server streams), mode (human readable)}.
- (void)preparePlayback:(NSDictionary *)metadata offset:(double)seconds done:(PXJSONBlock)done;
- (void)reportTimeline:(NSDictionary *)metadata state:(NSString *)state timeMs:(long long)t;
- (void)stopTranscode:(NSString *)session;
- (void)setWatched:(BOOL)watched item:(NSDictionary *)metadata;
// Persist the audio / subtitle choice on the server (applies to the next
// playback session). streamID -1 = unchanged, subtitle 0 = none.
- (void)selectStreamsForPart:(NSDictionary *)part audio:(NSInteger)audioID subtitle:(NSInteger)subtitleID done:(PXJSONBlock)done;
// Full metadata (Media/Part/Stream, chapters) for playback / detail.
- (void)metadata:(NSString *)ratingKey done:(PXJSONBlock)done;   // json: Metadata[0] dict

@end

NSString *PXEncode(NSString *s);
extern NSString *const PXSelectedServersDidChange;
