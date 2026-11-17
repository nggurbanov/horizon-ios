// horizon-ios: adapted from Amethyst-iOS (https://github.com/AngelAuraMC/Amethyst-iOS), Natives/UIKit+hook.h.
// Amethyst-iOS is free software under the GNU General Public License v3.0; this file is distributed under
// the same licence.
//
// A shim: the ported controls need nothing from Amethyst's UIKit hooks (private-API swizzles and the
// UIWindow.mainWindow category are not ported), so only the idiom macro remains.
#pragma once
#import <UIKit/UIKit.h>

#define realUIIdiom UIDevice.currentDevice.userInterfaceIdiom
