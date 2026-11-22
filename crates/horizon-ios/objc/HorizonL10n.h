// horizon-ios: lightweight automatic EN/RU localization for all native UIKit UI.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns YES when the active UI language resolves to Russian:
/// - `HorizonLauncherLanguageRussian` -> YES
/// - `HorizonLauncherLanguageEnglish` -> NO
/// - `HorizonLauncherLanguageAuto`    -> YES iff `[NSLocale preferredLanguages].firstObject`
///   starts with `"ru"` (case-insensitive); otherwise NO (English default).
BOOL HorizonIsRussian(void);

/// Returns the localized string for the active UI language (English default, Russian when active).
NSString *HorizonLocalized(NSString *en, NSString *ru);

/// Returns an `NSLocale` matching the active UI language (`en_US` or `ru_RU`).
NSLocale *HorizonCurrentLocale(void);

#ifndef HL
#define HL(en, ru) HorizonLocalized((en), (ru))
#endif

NS_ASSUME_NONNULL_END
