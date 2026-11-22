// horizon-ios: lightweight automatic EN/RU localization for all native UIKit UI.
#import "HorizonL10n.h"
#import "HorizonSettings.h"

BOOL HorizonIsRussian(void) {
    HorizonLauncherLanguage pref = HorizonSettings.shared.launcherLanguage;
    if (pref == HorizonLauncherLanguageRussian) {
        return YES;
    }
    if (pref == HorizonLauncherLanguageEnglish) {
        return NO;
    }
    NSString *first = NSLocale.preferredLanguages.firstObject;
    if (first.length == 0) {
        return NO;
    }
    return [first.lowercaseString hasPrefix:@"ru"];
}

NSString *HorizonLocalized(NSString *en, NSString *ru) {
    return HorizonIsRussian() ? ru : en;
}

NSLocale *HorizonCurrentLocale(void) {
    return [NSLocale localeWithLocaleIdentifier:(HorizonIsRussian() ? @"ru_RU" : @"en_US")];
}
