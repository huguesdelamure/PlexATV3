#import "PXTrackPrefs.h"
#import "PXServer.h"
#import "PXItem.h"
#import "PXPlex.h"
#import "PXSettings.h"
#import "PXLog.h"
#import "PXLocalize.h"

NSArray *PXAudioLangChoices(void) {
    return @[ @[ @"account", PXL(@"Comme mon compte Plex") ], @[ @"fr", PXL(@"Français") ], @[ @"en", PXL(@"Anglais") ], @[ @"orig", PXL(@"Version originale") ] ];
}

NSArray *PXSubModeChoices(void) {
    return @[ @[ @"account", PXL(@"Comme mon compte Plex") ], @[ @"none", PXL(@"Aucun") ], @[ @"forced", PXL(@"Forcés seulement") ], @[ @"always", PXL(@"Toujours") ] ];
}

NSString *PXChoiceLabel(NSArray *choices, NSString *value) {
    for (NSArray *c in choices) if ([c[0] isEqual:value]) return c[1];
    return [choices.firstObject lastObject];
}

void PXMarkTracksManual(NSString *ratingKey) {
    if (!ratingKey) return;
    NSMutableArray *list = [PXSettingGet(@"manualTracks") mutableCopy] ?: [NSMutableArray array];
    if (![list containsObject:ratingKey]) [list addObject:ratingKey];
    while (list.count > 500) [list removeObjectAtIndex:0];
    PXSettingSet(@"manualTracks", list);
}

static NSString *wantedAudioLang(void) {
    NSString *pref = PXSettingGet(@"audioLang") ?: @"account";
    if ([pref isEqual:@"orig"]) return nil;
    if ([pref isEqual:@"account"]) return [PXPlex shared].accountProfile[@"defaultAudioLanguage"];
    return pref;
}

// "none" | "forced" | "always"
static NSString *wantedSubMode(NSString **lang) {
    NSDictionary *profile = [PXPlex shared].accountProfile;
    *lang = profile[@"defaultSubtitleLanguage"] ?: wantedAudioLang() ?: @"fr";
    NSString *pref = PXSettingGet(@"subMode") ?: @"account";
    if (![pref isEqual:@"account"]) return pref;
    // plex.tv: autoSelectSubtitle 0 manual, 1 with foreign audio, 2 always;
    // defaultSubtitleForced 2 = prefer forced subtitles.
    NSInteger autoSel = [profile[@"autoSelectSubtitle"] integerValue];
    if (autoSel == 2) return @"always";
    if ([profile[@"defaultSubtitleForced"] integerValue] >= 1) return @"forced";
    return @"none";
}

static PXStream *bestAudio(NSArray *streams, NSString *lang) {
    PXStream *best = nil;
    for (PXStream *s in streams) {
        if (![s.languageTag isEqualToString:lang]) continue;
        if (!best || (s.isDefault && !best.isDefault) || (s.isDefault == best.isDefault && s.channels > best.channels)) best = s;
    }
    return best;
}

void PXApplyTrackPreferences(PXItem *item, void (^done)(BOOL changed)) {
    if (!item.part || [PXSettingGet(@"manualTracks") containsObject:item.ratingKey ?: @""]) { done(NO); return; }
    NSInteger audioID = -1, subID = -1;

    PXStream *audio = item.selectedAudio;
    NSString *lang = wantedAudioLang();
    if (lang.length && ![audio.languageTag isEqualToString:lang]) {
        PXStream *want = bestAudio(item.audioStreams, lang);
        if (want) { audioID = want.streamID; audio = want; }
    }

    NSString *subLang = nil;
    NSString *mode = wantedSubMode(&subLang);
    PXStream *current = item.selectedSubtitle, *wantSub = nil;
    if ([mode isEqual:@"forced"]) {
        // Forced subtitles in the language being listened to.
        NSString *l = audio.languageTag ?: subLang;
        for (PXStream *s in item.subtitleStreams) if (s.forced && [s.languageTag isEqualToString:l]) { wantSub = s; break; }
    } else if ([mode isEqual:@"always"]) {
        for (PXStream *s in item.subtitleStreams) if (!s.forced && [s.languageTag isEqualToString:subLang]) { wantSub = s; break; }
    }
    if (wantSub && wantSub.streamID != current.streamID) subID = wantSub.streamID;
    else if (!wantSub && current && [mode isEqual:@"none"]) subID = 0;

    if (audioID < 0 && subID < 0) { done(NO); return; }
    PXLog(@"tracks: auto audio=%ld subtitle=%ld for '%@' (lang %@, subtitles %@)", (long)audioID, (long)subID, item.title, lang, mode);
    [item.server selectStreamsForPart:item.part audio:audioID subtitle:subID done:^(id json, NSError *err) {
        done(err == nil);
    }];
}
