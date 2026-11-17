// horizon-ios: adapted from Amethyst-iOS (https://github.com/AngelAuraMC/Amethyst-iOS), Natives/customcontrols/ControlDrawer.h.
// Amethyst-iOS is free software under the GNU General Public License v3.0; this file is distributed
// under the same licence. Changes for horizon-ios are marked "horizon-ios:".

#import <UIKit/UIKit.h>
#import "ControlButton.h"
#import "ControlSubButton.h"

@class ControlSubButton;

@interface ControlDrawer : ControlButton {
}

@property(nonatomic, strong) NSMutableDictionary* drawerData;
@property(nonatomic, strong) NSMutableArray* buttons;
@property(nonatomic, assign) BOOL areButtonsVisible;

+ (id)buttonWithData:(NSMutableDictionary *)drawerData;
- (ControlSubButton *)addButton:(ControlSubButton *)button;
- (void)restoreButtonVisibility;
- (void)syncButtons;

@end
