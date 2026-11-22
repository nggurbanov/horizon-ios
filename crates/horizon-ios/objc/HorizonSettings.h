// horizon-ios: persisted Bedrock touch control settings (NSUserDefaults).
#pragma once

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(NSInteger, HorizonTouchScheme) {
    HorizonTouchSchemeJoystickCrosshair = 0, // Joystick & Aim Crosshair (Bedrock default)
    HorizonTouchSchemeJoystickTap = 1,       // Joystick & Tap to Interact
    HorizonTouchSchemeDpadTap = 2,           // Classic D-Pad & Tap to Interact
};

NS_ASSUME_NONNULL_BEGIN

@interface HorizonSettings : NSObject

+ (instancetype)shared;

@property (nonatomic, assign) HorizonTouchScheme scheme;
@property (nonatomic, assign) BOOL floatingJoystick;
@property (nonatomic, assign) CGFloat buttonScale;       // 0.70 .. 1.40 (default 1.0)
@property (nonatomic, assign) CGFloat buttonOpacity;     // 0.25 .. 1.00 (default 0.72)
@property (nonatomic, assign) CGFloat cameraSensitivity; // 0.30 .. 2.50 (default 1.0)
@property (nonatomic, assign) BOOL autoJump;             // default YES (Touch mode)
@property (nonatomic, assign) BOOL leftHanded;           // default NO
@property (nonatomic, assign) BOOL swapJumpSneak;        // default NO
@property (nonatomic, assign) BOOL hapticsEnabled;       // default YES
@property (nonatomic, assign) BOOL gyroEnabled;          // default NO
@property (nonatomic, assign) CGFloat gyroSensitivity;   // 0.20 .. 3.00 (default 1.0)
@property (nonatomic, assign) BOOL skipLauncher;         // default NO
@property (nonatomic, copy, nullable) NSString *lastQuickServerAddress;

- (BOOL)isTapToInteract;
- (void)resetToDefaults;
- (void)syncToBridge;

@end

NS_ASSUME_NONNULL_END
