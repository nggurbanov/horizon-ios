// horizon-ios: adapted from Amethyst-iOS (https://github.com/AngelAuraMC/Amethyst-iOS), Natives/customcontrols/ControlButton.h.
// Amethyst-iOS is free software under the GNU General Public License v3.0; this file is distributed
// under the same licence. Changes for horizon-ios are marked "horizon-ios:".

#import <UIKit/UIKit.h>

/**
 * Custom controls have similar format as Android.
 *
 * Android       - iOS:
 * ControlButton - same
 * ControlData   - NSDictionary
 */

@interface ControlButton : UIButton {
}

@property BOOL canBeHidden, displayInGame, displayInMenu, isToggleOn;
@property(nonatomic) NSMutableDictionary* properties;
@property(nonatomic) UIColor* savedBackgroundColor;

+ (id)buttonWithProperties:(NSMutableDictionary *)propArray;

- (CGFloat)calculateDynamicPos:(NSString *)string;
- (BOOL)canSnap:(ControlButton *)button;
- (NSString *)generateDynamicX:(CGFloat)x;
- (NSString *)generateDynamicY:(CGFloat)y;
- (void)snapAndAlignX:(CGFloat)x Y:(CGFloat)y;
- (void)preProcessProperties;
- (void)update;

@end
