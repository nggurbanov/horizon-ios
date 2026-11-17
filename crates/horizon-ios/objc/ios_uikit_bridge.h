// horizon-ios: adapted from Amethyst-iOS (https://github.com/AngelAuraMC/Amethyst-iOS),
// Natives/ios_uikit_bridge.h. Amethyst-iOS is free software under the GNU General Public License v3.0;
// this file is distributed under the same licence.
//
// A shim: only showDialog. The clipboard (JNI), launcher and AWT parts are gone.
#pragma once
#import <UIKit/UIKit.h>

// Shows an alert with an OK button over the overlay, on the main thread.
void showDialog(NSString* title, NSString* message);
