// horizon-ios: persisted Bedrock touch control settings (NSUserDefaults).
#pragma once

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(NSInteger, HorizonTouchScheme) {
    HorizonTouchSchemeJoystickCrosshair = 0, // Joystick & Aim Crosshair (Bedrock default)
    HorizonTouchSchemeJoystickTap = 1,       // Joystick & Tap to Interact
    HorizonTouchSchemeDpadTap = 2,           // Classic D-Pad & Tap to Interact
};

typedef NS_ENUM(NSInteger, HorizonOTAInstaller) {
    HorizonOTAInstallerAuto = 0,      // Auto-detect installed sideloader or present chooser
    HorizonOTAInstallerFeather = 1,   // feather://install/<raw-https-url>
    HorizonOTAInstallerSideStore = 2, // sidestore://install?url=<percent-encoded-https-url>
    HorizonOTAInstallerAltStore = 3,  // altstore://install?url=<percent-encoded-https-url>
    HorizonOTAInstallerDirect = 4,    // Open raw .ipa URL in Safari
};

typedef NS_ENUM(NSInteger, HorizonLauncherLanguage) {
    HorizonLauncherLanguageAuto = 0,    // System preferred language (Russian if ru*, else English)
    HorizonLauncherLanguageEnglish = 1, // English
    HorizonLauncherLanguageRussian = 2, // Russian
};

NS_ASSUME_NONNULL_BEGIN

@interface HorizonSettings : NSObject

+ (instancetype)shared;
+ (NSString *)defaultOTASourceURL;

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
@property (nonatomic, assign) HorizonLauncherLanguage launcherLanguage; // default Auto (0)

// OTA update settings
@property (nonatomic, assign) HorizonOTAInstaller otaInstaller; // default Auto
@property (nonatomic, assign) BOOL autoCheckUpdates;            // default YES
@property (nonatomic, copy) NSString *otaSourceURL;             // default GitHub ios-latest source.json

- (BOOL)isTapToInteract;
- (void)resetToDefaults;
- (void)resetOTASourceURL;
- (void)syncToBridge;

@end

NS_ASSUME_NONNULL_END
