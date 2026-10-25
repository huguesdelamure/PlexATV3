// Typed view over a PMS "Metadata" JSON object (movie, show, season, episode).

#import <Foundation/Foundation.h>
@class PXServer;

typedef NS_ENUM(NSInteger, PXItemType) { PXItemOther, PXItemMovie, PXItemShow, PXItemSeason, PXItemEpisode };

@interface PXStream : NSObject
@property (nonatomic, readonly) NSInteger streamID;
@property (nonatomic, readonly) NSInteger streamType;    // 1 video, 2 audio, 3 subtitle
@property (nonatomic, readonly) NSString *codec;
@property (nonatomic, readonly) NSString *language;
@property (nonatomic, readonly) NSString *languageTag;   // "fr", "en" (ISO 639-1 when known)
@property (nonatomic, readonly) NSString *displayTitle;  // "Français (AC3 5.1)"
@property (nonatomic, readonly) BOOL selected;
@property (nonatomic, readonly) BOOL isDefault;
@property (nonatomic, readonly) NSInteger channels;
@property (nonatomic, readonly) BOOL forced;
@end

@interface PXItem : NSObject

@property (nonatomic, readonly) NSDictionary *raw;
@property (nonatomic, readonly) PXServer *server;        // server it comes from (else the primary one)
@property (nonatomic, readonly) NSString *uniqueKey;     // "server/ratingKey" (ratingKeys repeat across servers)
+ (instancetype)itemWithJSON:(NSDictionary *)json;
+ (NSArray *)itemsWithJSON:(NSArray *)array;   // skips non-dictionaries

@property (nonatomic, readonly) PXItemType type;
@property (nonatomic, readonly) NSString *ratingKey;
@property (nonatomic, readonly) NSString *key;            // children path for containers
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) NSString *summary;
@property (nonatomic, readonly) NSInteger year;
@property (nonatomic, readonly) NSString *contentRating;
@property (nonatomic, readonly) NSString *studio;
@property (nonatomic, readonly) double audienceRating;    // 0-10, 0 if unknown
@property (nonatomic, readonly) NSArray *genres;          // NSString
@property (nonatomic, readonly) NSArray *directors;
@property (nonatomic, readonly) NSArray *roles;           // NSString "Actor"

@property (nonatomic, readonly) NSString *thumb;
// NO for files the server could not match (local:// or "none" agent): their
// thumb is a 16:9 video frame, not a poster.
@property (nonatomic, readonly) BOOL hasPoster;
@property (nonatomic, readonly) NSString *art;
@property (nonatomic, readonly) NSString *posterPath;     // best 2:3 artwork for shelves
@property (nonatomic, readonly) NSString *landscapePath;  // 16:9: episode still, else backdrop
@property (nonatomic, readonly) NSString *tagline;
@property (nonatomic, readonly) NSArray *ratings;         // {image, value, type}
@property (nonatomic, readonly) NSArray *cast;            // {name, role, thumb}
@property (nonatomic, readonly) NSArray *markers;         // {type, start, end} seconds
@property (nonatomic, readonly) NSString *grandparentTitle;
@property (nonatomic, readonly) NSString *grandparentRatingKey;
@property (nonatomic, readonly) NSString *parentRatingKey;
@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, readonly) NSInteger parentIndex;
@property (nonatomic, readonly) NSInteger leafCount;
@property (nonatomic, readonly) NSInteger viewedLeafCount;
@property (nonatomic, readonly) NSInteger childCount;

@property (nonatomic, readonly) double duration;          // seconds
@property (nonatomic, readonly) double viewOffset;        // seconds
@property (nonatomic, readonly) BOOL watched;
@property (nonatomic, readonly) double progress;          // 0..1, 0 if not started
@property (nonatomic, readonly) NSInteger unwatchedLeaves;

// Media of the first version.
@property (nonatomic, readonly) NSDictionary *media;
@property (nonatomic, readonly) NSDictionary *part;
@property (nonatomic, readonly) NSArray *audioStreams;     // PXStream
@property (nonatomic, readonly) NSArray *subtitleStreams;  // PXStream
@property (nonatomic, readonly) NSArray *chapters;         // {title, start(s)}
- (PXStream *)selectedAudio;
- (PXStream *)selectedSubtitle;
- (NSString *)mediaSummary;      // "4K · HEVC · TrueHD 7.1"
// Versions (Media entries) of the title; -media is the chosen one (remembered
// per title), else the first.
@property (nonatomic, readonly) NSArray *mediaList;
@property (nonatomic, readonly) NSInteger mediaIndex;
@property (nonatomic, readonly) NSString *guid;          // plex://movie/… (same title on other servers)
+ (NSString *)labelForMedia:(NSDictionary *)media;       // "4K · HEVC · 58 Mb/s"
- (void)chooseMediaAtIndex:(NSInteger)index;

// Display helpers.
- (NSString *)episodeCode;       // "S01 E03"
- (NSString *)shelfTitle;        // show title for episodes, title otherwise
- (NSString *)shelfSubtitle;     // "S01 E03" / year / "3 saisons"
- (NSString *)remainingText;     // "reste 32 min" when in progress
- (NSArray *)techBadges;         // ["4K", "HDR", "TrueHD 7.1", "VF"]

@end

// YES when at least a third of the items have no poster: show them as 16:9 cards.
BOOL PXItemsPreferLandscape(NSArray *items);
