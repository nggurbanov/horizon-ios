// horizon-ios: native UIKit Pre-Launcher app delegate and seamless handoff into winit.
#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface HorizonPreLauncherAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong, nullable) UIWindow *window;

/// Saves env vars (`HORIZON_PLAYER_NAME`, optional `HORIZON_IOS_QUICK_SERVER` /
/// `HORIZON_IOS_QUICK_WORLD`) and schedules the Rust game-start callback via an `NSTimer`
/// on `NSRunLoop.mainRunLoop` (outside GCD's main queue so nested `CFRunLoopRun` never deadlocks it).
+ (void)launchGameWithPlayerName:(nullable NSString *)playerName
                     quickServer:(nullable NSString *)quickServer
                      quickWorld:(nullable NSString *)quickWorld;

@end

NS_ASSUME_NONNULL_END
