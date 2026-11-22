// horizon-ios: native compact Bedrock touch settings sheet presented over the game.
#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface HorizonTouchSettingsViewController : UIViewController
@property (nonatomic, copy, nullable) void (^onSettingsChanged)(void);
@property (nonatomic, copy, nullable) void (^onDismiss)(void);
@end

NS_ASSUME_NONNULL_END
