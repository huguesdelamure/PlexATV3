// Rows for the audio / subtitle pickers (detail screen and player).

#import "PXListLayer.h"
#import "PXItem.h"
#import "PXLocalize.h"
#import "PXSettings.h"

static inline NSString *PXTrackLabel(PXStream *s) {
    if (!s) return PXL(@"Aucun");
    NSString *t = s.displayTitle;
    return s.forced && s.streamType == 3 ? [t stringByAppendingString:PXL(@" (forcés)")] : t;
}

// Compact label for buttons: language, or the start of the title.
static inline NSString *PXShortTrack(PXStream *s) {
    if (!s) return PXL(@"Aucun");
    NSString *lang = s.language.length ? [s.language capitalizedString] : nil;
    NSString *t = lang ?: s.displayTitle;
    // "Forced" only means something for subtitles (some files flag audio too).
    return s.forced && s.streamType == 3 ? [t stringByAppendingString:PXL(@" (forcés)")] : t;
}

static inline NSArray *PXAudioRows(PXItem *item, void (^pick)(NSInteger streamID)) {
    NSMutableArray *rows = [NSMutableArray array];
    NSInteger current = item.selectedAudio.streamID;
    for (PXStream *s in item.audioStreams) {
        NSInteger sid = s.streamID;
        PXListRow *r = [PXListRow title:PXTrackLabel(s) value:@"" action:^{ pick(sid); }];
        r.checked = sid == current;
        [rows addObject:r];
    }
    return rows;
}

static inline NSArray *PXSubtitleRows(PXItem *item, void (^pick)(NSInteger streamID)) {
    NSMutableArray *rows = [NSMutableArray array];
    PXStream *cur = item.selectedSubtitle;
    PXListRow *none = [PXListRow title:PXL(@"Aucun") value:@"" action:^{ pick(0); }];
    none.checked = cur == nil;
    [rows addObject:none];
    for (PXStream *s in item.subtitleStreams) {
        NSInteger sid = s.streamID;
        PXListRow *r = [PXListRow title:PXTrackLabel(s) value:[s.codec uppercaseString] action:^{ pick(sid); }];
        r.checked = cur && sid == cur.streamID;
        [rows addObject:r];
    }
    return rows;
}

// Réglages > Taille des sous-titres, burned in by the server transcoder
// (also changed from the player options).
static inline NSString *PXSubtitleSizeLabel(void) {
    switch ([PXSettingGet(@"subtitleSize") intValue] ?: 100) {
        case 80: return PXL(@"Petite");
        case 125: return PXL(@"Grande");
        case 150: return PXL(@"Très grande");
        default: return PXL(@"Normale");
    }
}

static inline void PXNextSubtitleSize(void) {
    NSArray *steps = @[ @80, @100, @125, @150 ];
    NSUInteger i = [steps indexOfObject:@([PXSettingGet(@"subtitleSize") intValue] ?: 100)];
    PXSettingSet(@"subtitleSize", steps[(i == NSNotFound ? 1 : i + 1) % steps.count]);
}
