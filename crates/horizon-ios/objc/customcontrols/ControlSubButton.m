// horizon-ios: adapted from Amethyst-iOS (https://github.com/AngelAuraMC/Amethyst-iOS), Natives/customcontrols/ControlSubButton.m.
// Amethyst-iOS is free software under the GNU General Public License v3.0; this file is distributed
// under the same licence. Changes for horizon-ios are marked "horizon-ios:".

#import "ControlSubButton.h"
#import "CustomControlsUtils.h"
#import "../LauncherPreferences.h"

#define INSERT_VALUE(KEY, VALUE) \
  string = [string stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"${%@}", @(KEY)] withString:VALUE];

@implementation ControlSubButton

// filterProperties
- (void)preProcessProperties {
    if (self.parentDrawer && ![self.parentDrawer.drawerData[@"orientation"] isEqualToString:@"FREE"]) {
        self.properties[@"width"] = self.parentDrawer.properties[@"width"];
        self.properties[@"height"] = self.parentDrawer.properties[@"height"];
    }
}

- (void)setParentDrawer:(ControlDrawer *)drawer {
    _parentDrawer = drawer;

    // Copy visibility properties
    self.displayInGame = drawer.displayInGame;
    self.displayInMenu = drawer.displayInMenu;

    [self preProcessProperties];
    //NSLog(@"DEBUG: SubButton properties %@", self.properties);
}

@end
