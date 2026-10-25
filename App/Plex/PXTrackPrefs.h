// Automatic audio / subtitle choice before playback.
//
// Preferences (app settings, default "account" = plex.tv profile):
//   audioLang  "account" | "orig" (never change) | ISO 639-1 code ("fr", "en")
//   subMode    "account" | "none" | "forced" | "always"
// A title whose tracks the user picked by hand in the app is never changed.

#import <Foundation/Foundation.h>
@class PXItem;

NSArray *PXAudioLangChoices(void);      // @[ @[value, label], ... ]
NSArray *PXSubModeChoices(void);
NSString *PXChoiceLabel(NSArray *choices, NSString *value);

void PXMarkTracksManual(NSString *ratingKey);
// Calls done(YES) after changing the server-side selection (refetch the
// metadata then), done(NO) when nothing had to change.
void PXApplyTrackPreferences(PXItem *item, void (^done)(BOOL changed));
