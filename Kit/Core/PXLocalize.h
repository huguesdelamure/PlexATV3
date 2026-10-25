// UI languages. Source strings are written in French in the code and are the
// keys of the translations: <lang>.lproj/Localizable.strings next to the
// bundle ("Continuer à regarder" = "Continue watching";). A missing
// translation shows the French text. To add a language: copy
// App/Resources/en.lproj/Localizable.strings, translate, add it to
// PXSupportedLanguages().

#import <Foundation/Foundation.h>

NSString *PXL(NSString *french);
// Same, as a format string: PXLF(@"Reprendre à %@", time).
NSString *PXLF(NSString *frenchFormat, ...) NS_FORMAT_FUNCTION(1, 2);

NSArray *PXSupportedLanguages(void);      // ISO codes: @[ @"fr", @"en", ... ]
NSString *PXLanguageName(NSString *code); // in that language: "Français", "English"
// Current UI language: setting "uiLanguage" ("auto" or a code), "auto" =
// the Apple TV language when supported, else English.
NSString *PXLanguage(void);
NSLocale *PXUILocale(void);
