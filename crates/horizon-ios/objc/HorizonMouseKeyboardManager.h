// horizon-ios: native Apple GCMouse, GCKeyboard, UIPress fallback, and CoreMotion gyroscope manager.
#pragma once

#import <UIKit/UIKit.h>
#import <GameController/GameController.h>

NS_ASSUME_NONNULL_BEGIN

@protocol HorizonMouseKeyboardDelegate <NSObject>
- (void)hardwareInputDidActivateKeyboardMouse;
- (BOOL)hardwareInputIsGrabbing;
- (BOOL)hardwareInputIsTextFieldEditing;
- (CGSize)hardwareInputViewSizePoints;
- (CGFloat)hardwareInputScreenScale;
@end

@interface HorizonMouseKeyboardManager : NSObject

@property (nonatomic, weak, nullable) id<HorizonMouseKeyboardDelegate> delegate;
@property (nonatomic, readonly) BOOL hasConnectedMouse;
@property (nonatomic, readonly) BOOL hasConnectedKeyboard;
@property (nonatomic, assign) CGPoint softwareCursorPoints;

- (void)start;
- (void)stop;
- (void)releaseAllHeldKeys;

// UIPress fallback & character input for hardware keyboards.
- (BOOL)handlePressesBegan:(NSSet<UIPress *> *)presses;
- (BOOL)handlePressesEndedOrCancelled:(NSSet<UIPress *> *)presses;

// CoreMotion gyroscope aiming (optional, controlled by HorizonSettings).
- (void)updateGyroSettings;
- (void)tickGyro;

@end

NS_ASSUME_NONNULL_END
