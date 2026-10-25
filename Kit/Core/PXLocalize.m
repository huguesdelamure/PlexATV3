#import "PXLocalize.h"
#import "PXSettings.h"
#import "PXLog.h"

NSArray *PXSupportedLanguages(void) { return @[ @"fr", @"en" ]; }

NSString *PXLanguageName(NSString *code) {
    NSDictionary *names = @{ @"fr": @"Français", @"en": @"English", @"de": @"Deutsch", @"es": @"Español", @"it": @"Italiano" };
    return names[code] ?: code;
}

NSString *PXLanguage(void) {
    NSString *pref = PXSettingGet(@"uiLanguage");
    if (pref.length && ![pref isEqual:@"auto"] && [PXSupportedLanguages() containsObject:pref]) return pref;
    for (NSString *l in [NSLocale preferredLanguages]) {
        NSString *code = [[l componentsSeparatedByString:@"-"].firstObject componentsSeparatedByString:@"_"].firstObject;
        if ([PXSupportedLanguages() containsObject:code]) return code;
    }
    return @"en";
}

NSLocale *PXUILocale(void) {
    static NSLocale *cached;
    static NSString *cachedLang;
    NSString *lang = PXLanguage();
    if (![lang isEqual:cachedLang]) { cachedLang = lang; cached = [NSLocale localeWithLocaleIdentifier:lang]; }
    return cached;
}

static NSBundle *languageBundle(NSString *lang) {
    static NSMutableDictionary *bundles;
    if (!bundles) bundles = [NSMutableDictionary dictionary];
    id b = bundles[lang];
    if (!b) {
        NSString *path = [PXKitBundle() pathForResource:lang ofType:@"lproj"];
        b = path ? [NSBundle bundleWithPath:path] : nil;
        bundles[lang] = b ?: [NSNull null];
    }
    return [b isKindOfClass:[NSBundle class]] ? b : nil;
}

NSString *PXL(NSString *french) {
    if (!french.length) return french;
    NSString *lang = PXLanguage();
    if ([lang isEqual:@"fr"]) return french;
    NSBundle *b = languageBundle(lang);
    return b ? [b localizedStringForKey:french value:french table:@"Localizable"] : french;
}

NSString *PXLF(NSString *frenchFormat, ...) {
    va_list args;
    va_start(args, frenchFormat);
    NSString *s = [[NSString alloc] initWithFormat:PXL(frenchFormat) locale:PXUILocale() arguments:args];
    va_end(args);
    return s;
}
