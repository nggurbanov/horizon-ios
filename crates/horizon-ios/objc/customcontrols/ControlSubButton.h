// horizon-ios: adapted from Amethyst-iOS (https://github.com/AngelAuraMC/Amethyst-iOS), Natives/customcontrols/ControlSubButton.h.
// Amethyst-iOS is free software under the GNU General Public License v3.0; this file is distributed
// under the same licence. Changes for horizon-ios are marked "horizon-ios:".

#import <UIKit/UIKit.h>
#import "ControlDrawer.h"

@class ControlDrawer;

@interface ControlSubButton : ControlButton {
}

@property(nonatomic, weak) ControlDrawer* parentDrawer;

@end
