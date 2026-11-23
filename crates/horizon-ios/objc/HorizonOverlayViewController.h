// horizon-ios: master native Bedrock Touch / Gamepad / Keyboard+Mouse overlay view controller.
#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface HorizonOverlayViewController : UIViewController

+ (nullable HorizonOverlayViewController *)current;
- (void)attachToGameView:(UIView *)gameView;
- (void)reassertFirstResponderIfNeeded;

@end

NS_ASSUME_NONNULL_END
