// On-screen keyboard layouts (search). Four rows of ten keys: three letter
// rows (with the accented letters of the language) and the digits. The
// layout follows the UI language unless chosen in Réglages (setting
// "keyboard"). To add one: a new entry in PXKeyboardLayouts().

#import <Foundation/Foundation.h>
#import "PXLocalize.h"
#import "PXSettings.h"

// identifier -> {name, rows}
static inline NSDictionary *PXKeyboardLayouts(void) {
    return @{
        @"azerty": @{ @"name": @"AZERTY", @"rows": @[ @"azertyuiop", @"qsdfghjklm", @"wxcvbnéèàç", @"1234567890" ] },
        @"qwerty": @{ @"name": @"QWERTY", @"rows": @[ @"qwertyuiop", @"asdfghjkl'", @"zxcvbnm-.&", @"1234567890" ] },
        @"qwertz": @{ @"name": @"QWERTZ", @"rows": @[ @"qwertzuiop", @"asdfghjklü", @"yxcvbnmöäß", @"1234567890" ] },
    };
}

static inline NSArray *PXKeyboardLayoutOrder(void) { return @[ @"auto", @"azerty", @"qwerty", @"qwertz" ]; }

// Layout in use: setting, else the usual one for the UI language.
static inline NSString *PXKeyboardLayout(void) {
    NSString *pref = PXSettingGet(@"keyboard");
    if (pref.length && PXKeyboardLayouts()[pref]) return pref;
    NSDictionary *byLanguage = @{ @"fr": @"azerty", @"de": @"qwertz" };
    return byLanguage[PXLanguage()] ?: @"qwerty";
}

static inline NSArray *PXKeyboardRows(void) { return PXKeyboardLayouts()[PXKeyboardLayout()][@"rows"]; }
