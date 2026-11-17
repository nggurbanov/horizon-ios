// horizon-ios: adapted from Amethyst-iOS (https://github.com/AngelAuraMC/Amethyst-iOS),
// Natives/LauncherPreferences.h. Amethyst-iOS is free software under the GNU General Public License v3.0;
// this file is distributed under the same licence.
//
// A shim backed by NSUserDefaults (keys such as "control.button_scale"), with Amethyst's defaults
// registered for every key the overlay reads. The Java, renderer, profile and warning prefs are gone.
#pragma once

#import <UIKit/UIKit.h>

// Registers the defaults (done lazily by every getter too). `reset` removes the stored values first.
void loadPreferences(BOOL reset);

id getPrefObject(NSString *key);
BOOL getPrefBool(NSString *key);
float getPrefFloat(NSString *key);
NSInteger getPrefInt(NSString *key);

void setPrefObject(NSString *key, id value);
void setPrefBool(NSString *key, BOOL value);
void setPrefFloat(NSString *key, float value);
void setPrefInt(NSString *key, NSInteger value);

UIEdgeInsets getDefaultSafeArea(void);
CGRect getSafeArea(CGRect screenBounds);
void setSafeArea(CGSize screenSize, CGRect safeArea);
