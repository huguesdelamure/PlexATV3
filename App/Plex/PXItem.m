#import "PXItem.h"
#import "PXSettings.h"
#import "PXServer.h"
#import "PXLocalize.h"

static NSString *str(id v) {
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    return nil;
}
static double num(id v) { return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0; }
static NSArray *arr(id v) { return [v isKindOfClass:[NSArray class]] ? v : @[]; }

static NSArray *tags(id list) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in arr(list)) if ([d isKindOfClass:[NSDictionary class]] && str(d[@"tag"])) [out addObject:str(d[@"tag"])];
    return out;
}

@implementation PXStream {
    NSDictionary *_d;
}
- (instancetype)initWithJSON:(NSDictionary *)d { if ((self = [super init])) _d = d; return self; }
- (NSInteger)streamID { return (NSInteger)num(_d[@"id"]); }
- (NSInteger)streamType { return (NSInteger)num(_d[@"streamType"]); }
- (NSString *)codec { return str(_d[@"codec"]); }
- (NSString *)language { return str(_d[@"language"]); }
- (NSString *)languageTag {
    NSString *t = str(_d[@"languageTag"]);
    if (t.length) return [[t componentsSeparatedByString:@"-"].firstObject lowercaseString];
    NSDictionary *iso3 = @{ @"fra": @"fr", @"fre": @"fr", @"eng": @"en", @"spa": @"es", @"ger": @"de", @"deu": @"de", @"ita": @"it", @"jpn": @"ja" };
    return iso3[str(_d[@"languageCode"]) ?: @""] ?: str(_d[@"languageCode"]);
}
- (NSString *)displayTitle { return str(_d[@"extendedDisplayTitle"]) ?: str(_d[@"displayTitle"]) ?: str(_d[@"language"]) ?: @"?"; }
- (BOOL)selected { return [_d[@"selected"] boolValue]; }
- (BOOL)isDefault { return [_d[@"default"] boolValue]; }
- (NSInteger)channels { return (NSInteger)num(_d[@"channels"]); }
- (BOOL)forced { return [_d[@"forced"] boolValue]; }
@end

@implementation PXItem

+ (instancetype)itemWithJSON:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    PXItem *it = [PXItem new];
    it->_raw = json;
    return it;
}

+ (NSArray *)itemsWithJSON:(NSArray *)array {
    NSMutableArray *out = [NSMutableArray array];
    for (id j in arr(array)) { PXItem *it = [PXItem itemWithJSON:j]; if (it) [out addObject:it]; }
    return out;
}

- (PXItemType)type {
    NSString *t = str(_raw[@"type"]);
    if ([t isEqualToString:@"movie"]) return PXItemMovie;
    if ([t isEqualToString:@"show"]) return PXItemShow;
    if ([t isEqualToString:@"season"]) return PXItemSeason;
    if ([t isEqualToString:@"episode"]) return PXItemEpisode;
    if ([t isEqualToString:@"collection"]) return PXItemCollection;
    if ([t isEqualToString:@"playlist"]) return PXItemPlaylist;
    if ([t isEqualToString:@"clip"]) return PXItemClip;
    if ([t isEqualToString:@"artist"]) return PXItemArtist;
    if ([t isEqualToString:@"album"]) return PXItemAlbum;
    if ([t isEqualToString:@"track"]) return PXItemTrack;
    if ([t isEqualToString:@"photoalbum"]) return PXItemPhotoAlbum;
    if ([t isEqualToString:@"photo"]) return _raw[@"Media"] ? PXItemPhoto : PXItemPhotoAlbum;   // albums: no Media
    return PXItemOther;
}

- (NSString *)ratingKey { return str(_raw[@"ratingKey"]); }
- (NSString *)key { return str(_raw[@"key"]); }
- (NSString *)title { return str(_raw[@"title"]) ?: @""; }
- (NSString *)summary { return str(_raw[@"summary"]) ?: @""; }
- (NSInteger)year { return (NSInteger)num(_raw[@"year"]); }
- (NSString *)contentRating { return str(_raw[@"contentRating"]); }
- (NSString *)studio { return str(_raw[@"studio"]); }
- (double)audienceRating { return num(_raw[@"audienceRating"]) ?: num(_raw[@"rating"]); }
// The server mixes languages ("Action, Adventure, Comédie") depending on the
// agent: translate the usual English genre names.
static NSString *frenchGenre(NSString *g) {
    static NSDictionary *map;
    if (!map) map = @{ @"Adventure": @"Aventure", @"Animation": @"Animation", @"Biography": @"Biographie",
                       @"Comedy": @"Comédie", @"Crime": @"Policier", @"Documentary": @"Documentaire",
                       @"Drama": @"Drame", @"Family": @"Familial", @"Fantasy": @"Fantastique",
                       @"History": @"Histoire", @"Horror": @"Horreur", @"Music": @"Musique",
                       @"Musical": @"Comédie musicale", @"Mystery": @"Mystère", @"Romance": @"Romance",
                       @"Science Fiction": @"Science-fiction", @"Sci-Fi": @"Science-fiction",
                       @"Science-Fiction": @"Science-fiction", @"Sport": @"Sport", @"Thriller": @"Thriller",
                       @"War": @"Guerre", @"Western": @"Western", @"Action & Adventure": @"Action et aventure",
                       @"Sci-Fi & Fantasy": @"Science-fiction et fantastique", @"War & Politics": @"Guerre et politique",
                       @"Kids": @"Enfants", @"Reality": @"Téléréalité", @"Talk": @"Talk-show", @"News": @"Actualités",
                       @"Soap": @"Feuilleton", @"Suspense": @"Suspense", @"TV Movie": @"Téléfilm" };
    return map[g] ?: g;
}

- (NSArray *)genres {
    NSMutableArray *out = [NSMutableArray array];
    BOOL french = [PXLanguage() isEqualToString:@"fr"];
    for (NSString *g in tags(_raw[@"Genre"])) {
        NSString *f = french ? frenchGenre(g) : g;
        if (![out containsObject:f]) [out addObject:f];
    }
    return out;
}
- (NSArray *)directors { return tags(_raw[@"Director"]); }
- (NSArray *)roles { return tags(_raw[@"Role"]); }
- (NSString *)thumb { return str(_raw[@"thumb"]) ?: str(_raw[@"composite"]); }   // playlists: composite only
- (PXServer *)server { return [[PXPlex shared] serverFor:_raw]; }
- (NSString *)uniqueKey { return [NSString stringWithFormat:@"%@/%@", self.server.identifier ?: @"", self.ratingKey ?: @""]; }
- (BOOL)hasPoster {
    if (self.type != PXItemMovie) return YES;
    NSString *g = str(_raw[@"guid"]) ?: @"";
    return !([g hasPrefix:@"local://"] || [g containsString:@"agents.none"]);
}
- (NSString *)art { return str(_raw[@"art"]) ?: str(_raw[@"grandparentArt"]); }
- (NSString *)grandparentTitle { return str(_raw[@"grandparentTitle"]); }
- (NSString *)grandparentRatingKey { return str(_raw[@"grandparentRatingKey"]); }
- (NSString *)parentRatingKey { return str(_raw[@"parentRatingKey"]); }
- (NSInteger)index { return (NSInteger)num(_raw[@"index"]); }
- (NSInteger)parentIndex { return (NSInteger)num(_raw[@"parentIndex"]); }
- (NSInteger)leafCount { return (NSInteger)num(_raw[@"leafCount"]); }
- (NSInteger)viewedLeafCount { return (NSInteger)num(_raw[@"viewedLeafCount"]); }
- (NSInteger)childCount { return (NSInteger)num(_raw[@"childCount"]); }

- (NSString *)posterPath {
    if (self.type == PXItemEpisode) return str(_raw[@"grandparentThumb"]) ?: str(_raw[@"parentThumb"]) ?: self.thumb;
    if (self.type == PXItemSeason) return self.thumb ?: str(_raw[@"parentThumb"]);
    return self.thumb;
}

- (NSString *)landscapePath {
    if (self.type == PXItemEpisode) return self.thumb ?: str(_raw[@"grandparentArt"]) ?: self.art;
    return self.art ?: self.thumb;
}

- (NSString *)tagline { return str(_raw[@"tagline"]); }

- (NSArray *)ratings {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *r in arr(_raw[@"Rating"]))
        if ([r isKindOfClass:[NSDictionary class]] && str(r[@"image"])) [out addObject:@{ @"image": str(r[@"image"]), @"value": @(num(r[@"value"])), @"type": str(r[@"type"]) ?: @"" }];
    return out;
}

- (NSArray *)cast {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *r in arr(_raw[@"Role"])) {
        if (![r isKindOfClass:[NSDictionary class]] || !str(r[@"tag"])) continue;
        [out addObject:@{ @"name": str(r[@"tag"]), @"role": str(r[@"role"]) ?: @"", @"thumb": str(r[@"thumb"]) ?: @"",
                          @"id": [r[@"id"] description] ?: @"" }];
    }
    return out;
}

- (NSArray *)extras {
    NSDictionary *e = _raw[@"Extras"];
    if (![e isKindOfClass:[NSDictionary class]]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (PXItem *it in [PXItem itemsWithJSON:e[@"Metadata"]]) {
        // Tag them with our server: extras come nested, without "_server".
        if (_raw[@"_server"] && [it.raw isKindOfClass:[NSMutableDictionary class]]) ((NSMutableDictionary *)it.raw)[@"_server"] = _raw[@"_server"];
        [out addObject:it];
    }
    return out;
}

- (NSString *)librarySectionID { return [_raw[@"librarySectionID"] description]; }

- (NSArray *)markers {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *m in arr(_raw[@"Marker"])) {
        if (![m isKindOfClass:[NSDictionary class]]) continue;
        [out addObject:@{ @"type": str(m[@"type"]) ?: @"", @"start": @(num(m[@"startTimeOffset"]) / 1000.0), @"end": @(num(m[@"endTimeOffset"]) / 1000.0) }];
    }
    return out;
}

- (NSString *)remainingText {
    if (self.progress <= 0) return nil;
    return PXLF(@"reste %ld min", MAX(1L, (long)((self.duration - self.viewOffset) / 60)));
}

- (NSArray *)techBadges {
    NSDictionary *m = self.media;
    if (!m) return @[];
    NSMutableArray *b = [NSMutableArray array];
    NSString *res = [str(m[@"videoResolution"]) lowercaseString];
    if ([res isEqualToString:@"4k"]) [b addObject:@"4K"];
    else if ([res isEqualToString:@"1080"] || [res isEqualToString:@"720"]) [b addObject:@"HD"];
    else if (res.length) [b addObject:@"SD"];
    NSString *vt = [[self streamsOfType:1].firstObject displayTitle];
    if ([vt containsString:@"DoVi"]) [b addObject:@"Dolby Vision"];
    else if ([vt containsString:@"HDR"]) [b addObject:@"HDR"];
    PXStream *a = self.selectedAudio;
    NSString *codec = [a.codec lowercaseString] ?: [str(m[@"audioCodec"]) lowercaseString];
    NSDictionary *names = @{ @"truehd": @"TrueHD", @"eac3": @"Dolby Digital+", @"ac3": @"Dolby Digital", @"dca": @"DTS", @"dca-ma": @"DTS-HD MA", @"aac": @"AAC", @"flac": @"FLAC" };
    NSString *an = names[codec ?: @""] ?: [codec uppercaseString];
    NSInteger ch = a.channels ?: (NSInteger)num(m[@"audioChannels"]);
    if (an) [b addObject:ch >= 6 ? [NSString stringWithFormat:@"%@ %@", an, ch >= 8 ? @"7.1" : @"5.1"] : an];
    if (self.subtitleStreams.count) [b addObject:PXL(@"ST")];
    return b;
}

- (double)duration { return num(_raw[@"duration"]) / 1000.0; }
- (double)viewOffset { return num(_raw[@"viewOffset"]) / 1000.0; }
- (BOOL)watched {
    if (self.type == PXItemShow || self.type == PXItemSeason) return self.leafCount > 0 && self.viewedLeafCount >= self.leafCount;
    return num(_raw[@"viewCount"]) > 0;
}
- (double)progress { return (self.duration > 0 && self.viewOffset > 0) ? MIN(1.0, self.viewOffset / self.duration) : 0; }
- (NSInteger)unwatchedLeaves { return MAX(0, self.leafCount - self.viewedLeafCount); }

- (NSArray *)mediaList { return arr(_raw[@"Media"]); }
- (NSString *)guid { return str(_raw[@"guid"]); }

static NSString *mediaChoiceKey(PXItem *it) {
    return [NSString stringWithFormat:@"%@/%@", it.raw[@"_server"] ?: @"", it.ratingKey];
}

- (NSInteger)mediaIndex {
    NSArray *list = self.mediaList;
    id chosen = [PXSettingGet(@"mediaChoices") objectForKey:mediaChoiceKey(self)];
    if (chosen) for (NSUInteger i = 0; i < list.count; i++) if ([[list[i][@"id"] description] isEqual:chosen]) return (NSInteger)i;
    return 0;
}

- (void)chooseMediaAtIndex:(NSInteger)index {
    NSArray *list = self.mediaList;
    if (index < 0 || index >= (NSInteger)list.count) return;
    NSMutableDictionary *choices = [PXSettingGet(@"mediaChoices") mutableCopy] ?: [NSMutableDictionary dictionary];
    choices[mediaChoiceKey(self)] = [list[index][@"id"] description] ?: @"";
    PXSettingSet(@"mediaChoices", choices);
}

+ (NSString *)labelForMedia:(NSDictionary *)m {
    NSMutableArray *p = [NSMutableArray array];
    NSString *res = str(m[@"videoResolution"]);
    if (res) [p addObject:[res isEqualToString:@"4k"] ? @"4K" : ([res rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location == NSNotFound ? [res stringByAppendingString:@"p"] : res.uppercaseString)];
    if (str(m[@"videoCodec"])) [p addObject:[str(m[@"videoCodec"]) uppercaseString]];
    if (str(m[@"audioCodec"])) [p addObject:[str(m[@"audioCodec"]) uppercaseString]];
    double br = num(m[@"bitrate"]);
    if (br > 0) [p addObject:br >= 1000 ? [NSString stringWithFormat:@"%.0f Mb/s", br / 1000] : [NSString stringWithFormat:@"%.0f kb/s", br]];
    return p.count ? [p componentsJoinedByString:@" · "] : PXL(@"Version");
}

- (NSDictionary *)media {
    NSArray *list = self.mediaList;
    NSInteger i = self.mediaIndex;
    id m = i < (NSInteger)list.count ? list[i] : nil;
    return [m isKindOfClass:[NSDictionary class]] ? m : nil;
}
- (NSDictionary *)part { id p = arr(self.media[@"Part"]).firstObject; return [p isKindOfClass:[NSDictionary class]] ? p : nil; }

- (NSArray *)streamsOfType:(NSInteger)type {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in arr(self.part[@"Stream"])) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        PXStream *s = [[PXStream alloc] initWithJSON:d];
        if (s.streamType == type) [out addObject:s];
    }
    return out;
}
- (NSArray *)audioStreams { return [self streamsOfType:2]; }
- (NSArray *)subtitleStreams { return [self streamsOfType:3]; }
- (PXStream *)selectedAudio {
    NSArray *a = self.audioStreams;
    for (PXStream *s in a) if (s.selected) return s;
    return a.firstObject;
}
- (PXStream *)selectedSubtitle {
    for (PXStream *s in self.subtitleStreams) if (s.selected) return s;
    return nil;
}

- (NSArray *)chapters {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *c in arr(_raw[@"Chapter"])) {
        if (![c isKindOfClass:[NSDictionary class]]) continue;
        [out addObject:@{ @"title": str(c[@"tag"]) ?: @"", @"start": @(num(c[@"startTimeOffset"]) / 1000.0) }];
    }
    return out;
}

- (NSString *)mediaSummary {
    NSDictionary *m = self.media;
    if (!m) return @"";
    NSMutableArray *p = [NSMutableArray array];
    NSString *res = str(m[@"videoResolution"]);
    if (res) [p addObject:[res isEqualToString:@"4k"] ? @"4K" : ([res rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location == NSNotFound ? [res stringByAppendingString:@"p"] : res.uppercaseString)];
    if (str(m[@"videoCodec"])) [p addObject:[str(m[@"videoCodec"]) uppercaseString]];
    // HDR flavour from the video stream title, e.g. "4K DoVi/HDR10 (HEVC Main 10)".
    NSString *vt = [[self streamsOfType:1].firstObject displayTitle];
    if ([vt containsString:@"DoVi"]) [p addObject:@"Dolby Vision"];
    else if ([vt containsString:@"HDR"]) [p addObject:@"HDR"];
    PXStream *a = self.selectedAudio;
    NSString *ac = [str(m[@"audioCodec"]) uppercaseString];
    if (ac) {
        NSInteger ch = a.channels ?: (NSInteger)num(m[@"audioChannels"]);
        [p addObject:ch ? [NSString stringWithFormat:@"%@ %@", ac, ch == 6 ? @"5.1" : ch == 8 ? @"7.1" : ch == 2 ? PXL(@"Stéréo") : [@(ch) stringValue]] : ac];
    }
    return [p componentsJoinedByString:@" · "];
}

- (NSString *)episodeCode {
    if (self.type != PXItemEpisode) return @"";
    return [NSString stringWithFormat:@"S%02ld E%02ld", (long)self.parentIndex, (long)self.index];
}

- (NSString *)shelfTitle {
    if (self.type == PXItemEpisode) return self.grandparentTitle ?: self.title;
    if (self.type == PXItemSeason) return str(_raw[@"parentTitle"]) ?: self.title;   // "Saison 10" alone says nothing
    return self.title;
}

- (NSString *)shelfSubtitle {
    switch (self.type) {
        case PXItemEpisode: return self.episodeCode;
        case PXItemShow: {
            NSInteger n = self.childCount;
            return n ? (n > 1 ? PXLF(@"%ld saisons", (long)n) : PXLF(@"%ld saison", (long)n)) : (self.year ? [@(self.year) stringValue] : @"");
        }
        case PXItemSeason: {
            NSInteger n = self.leafCount;
            NSString *eps = n > 1 ? PXLF(@"%ld épisodes", (long)n) : PXLF(@"%ld épisode", (long)n);
            return str(_raw[@"parentTitle"]) ? [NSString stringWithFormat:@"%@ · %@", self.title, eps] : eps;
        }
        default: return self.year ? [@(self.year) stringValue] : @"";
    }
}

@end

BOOL PXItemsPreferLandscape(NSArray *items) {
    NSUInteger n = 0, missing = 0;
    for (PXItem *it in items) {
        if (![it isKindOfClass:[PXItem class]]) continue;
        n++;
        if (!it.hasPoster) missing++;
    }
    return n && missing * 3 >= n;
}
