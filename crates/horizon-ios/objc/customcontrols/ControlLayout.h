// horizon-ios: adapted from Amethyst-iOS (https://github.com/AngelAuraMC/Amethyst-iOS), Natives/customcontrols/ControlLayout.h.
// Amethyst-iOS is free software under the GNU General Public License v3.0; this file is distributed
// under the same licence. Changes for horizon-ios are marked "horizon-ios:".

#import <UIKit/UIKit.h>

@interface CALayer(private)
@property(atomic, assign) NSUInteger disableUpdateMask;
@end

@interface ControlLayout : UIView

@property(nonatomic) NSMutableDictionary *layoutDictionary;

- (void)loadControlLayout:(NSMutableDictionary *)layoutDictionary;
- (void)loadControlFile:(NSString *)path;
- (void)removeAllButtons;
- (void)hideViewFromCapture:(BOOL)hide;

@end
