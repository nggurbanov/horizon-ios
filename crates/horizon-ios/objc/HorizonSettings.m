// horizon-ios: persisted Bedrock touch control settings (NSUserDefaults).
#import "HorizonSettings.h"
#include "horizon_bridge.h"

static NSString * const kPrefScheme            = @"horizon.touch.scheme";
static NSString * const kPrefFloatingJoystick  = @"horizon.touch.floatingJoystick";
static NSString * const kPrefButtonScale       = @"horizon.touch.buttonScale";
static NSString * const kPrefButtonOpacity     = @"horizon.touch.buttonOpacity";
static NSString * const kPrefCameraSensitivity = @"horizon.touch.cameraSensitivity";
static NSString * const kPrefAutoJump          = @"horizon.touch.autoJump";
static NSString * const kPrefLeftHanded        = @"horizon.touch.leftHanded";
static NSString * const kPrefSwapJumpSneak     = @"horizon.touch.swapJumpSneak";
static NSString * const kPrefHapticsEnabled    = @"horizon.touch.hapticsEnabled";
static NSString * const kPrefGyroEnabled       = @"horizon.touch.gyroEnabled";
static NSString * const kPrefGyroSensitivity   = @"horizon.touch.gyroSensitivity";
static NSString * const kPrefSkipLauncher      = @"horizon.launcher.skipLauncher";
static NSString * const kPrefLastQuickServer   = @"horizon.launcher.lastQuickServer";
static NSString * const kPrefLauncherLanguage  = @"horizon.launcher.language";
static NSString * const kPrefOTAInstaller      = @"horizon.ota.installer";
static NSString * const kPrefOTAAutoCheck      = @"horizon.ota.autoCheckUpdates";
static NSString * const kPrefOTASourceURL      = @"horizon.ota.sourceURL";

static NSString * const kDefaultOTASourceURL =
    @"https://github.com/nggurbanov/horizon-ios/releases/download/ios-latest/source.json";

static CGFloat clampf_cg(CGFloat v, CGFloat lo, CGFloat hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

@implementation HorizonSettings

+ (NSString *)defaultOTASourceURL {
    return kDefaultOTASourceURL;
}

+ (instancetype)shared {
    static HorizonSettings *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[HorizonSettings alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults registerDefaults:@{
            kPrefScheme: @(HorizonTouchSchemeJoystickCrosshair),
            kPrefFloatingJoystick: @YES,
            kPrefButtonScale: @(1.0),
            kPrefButtonOpacity: @(0.72),
            kPrefCameraSensitivity: @(1.0),
            kPrefAutoJump: @YES,
            kPrefLeftHanded: @NO,
            kPrefSwapJumpSneak: @NO,
            kPrefHapticsEnabled: @YES,
            kPrefGyroEnabled: @NO,
            kPrefGyroSensitivity: @(1.0),
            kPrefSkipLauncher: @NO,
            kPrefLauncherLanguage: @(HorizonLauncherLanguageAuto),
            kPrefOTAInstaller: @(HorizonOTAInstallerAuto),
            kPrefOTAAutoCheck: @YES,
            kPrefOTASourceURL: kDefaultOTASourceURL,
        }];
        [self loadFromDefaults];
    }
    return self;
}

- (void)loadFromDefaults {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger s = [d integerForKey:kPrefScheme];
    if (s < HorizonTouchSchemeJoystickCrosshair || s > HorizonTouchSchemeDpadTap) {
        s = HorizonTouchSchemeJoystickCrosshair;
    }
    _scheme = (HorizonTouchScheme)s;
    _floatingJoystick = [d boolForKey:kPrefFloatingJoystick];
    _buttonScale = clampf_cg([d doubleForKey:kPrefButtonScale], 0.70, 1.40);
    _buttonOpacity = clampf_cg([d doubleForKey:kPrefButtonOpacity], 0.25, 1.00);
    _cameraSensitivity = clampf_cg([d doubleForKey:kPrefCameraSensitivity], 0.30, 2.50);
    _autoJump = [d boolForKey:kPrefAutoJump];
    _leftHanded = [d boolForKey:kPrefLeftHanded];
    _swapJumpSneak = [d boolForKey:kPrefSwapJumpSneak];
    _hapticsEnabled = [d boolForKey:kPrefHapticsEnabled];
    _gyroEnabled = [d boolForKey:kPrefGyroEnabled];
    _gyroSensitivity = clampf_cg([d doubleForKey:kPrefGyroSensitivity], 0.20, 3.00);
    _skipLauncher = [d boolForKey:kPrefSkipLauncher];
    _lastQuickServerAddress = [[d stringForKey:kPrefLastQuickServer] copy];

    NSInteger lang = [d integerForKey:kPrefLauncherLanguage];
    if (lang < HorizonLauncherLanguageAuto || lang > HorizonLauncherLanguageRussian) {
        lang = HorizonLauncherLanguageAuto;
    }
    _launcherLanguage = (HorizonLauncherLanguage)lang;

    NSInteger inst = [d integerForKey:kPrefOTAInstaller];
    if (inst < HorizonOTAInstallerAuto || inst > HorizonOTAInstallerDirect) {
        inst = HorizonOTAInstallerAuto;
    }
    _otaInstaller = (HorizonOTAInstaller)inst;
    _autoCheckUpdates = [d boolForKey:kPrefOTAAutoCheck];
    NSString *src = [[d stringForKey:kPrefOTASourceURL]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    _otaSourceURL = (src.length > 0) ? [src copy] : [kDefaultOTASourceURL copy];
    [self syncToBridge];
}

- (void)setScheme:(HorizonTouchScheme)scheme {
    _scheme = scheme;
    [NSUserDefaults.standardUserDefaults setInteger:scheme forKey:kPrefScheme];
    [self syncToBridge];
}

- (void)setFloatingJoystick:(BOOL)floatingJoystick {
    _floatingJoystick = floatingJoystick;
    [NSUserDefaults.standardUserDefaults setBool:floatingJoystick forKey:kPrefFloatingJoystick];
}

- (void)setButtonScale:(CGFloat)buttonScale {
    _buttonScale = clampf_cg(buttonScale, 0.70, 1.40);
    [NSUserDefaults.standardUserDefaults setDouble:_buttonScale forKey:kPrefButtonScale];
}

- (void)setButtonOpacity:(CGFloat)buttonOpacity {
    _buttonOpacity = clampf_cg(buttonOpacity, 0.25, 1.00);
    [NSUserDefaults.standardUserDefaults setDouble:_buttonOpacity forKey:kPrefButtonOpacity];
}

- (void)setCameraSensitivity:(CGFloat)cameraSensitivity {
    _cameraSensitivity = clampf_cg(cameraSensitivity, 0.30, 2.50);
    [NSUserDefaults.standardUserDefaults setDouble:_cameraSensitivity forKey:kPrefCameraSensitivity];
}

- (void)setAutoJump:(BOOL)autoJump {
    _autoJump = autoJump;
    [NSUserDefaults.standardUserDefaults setBool:autoJump forKey:kPrefAutoJump];
    [self syncToBridge];
}

- (void)setLeftHanded:(BOOL)leftHanded {
    _leftHanded = leftHanded;
    [NSUserDefaults.standardUserDefaults setBool:leftHanded forKey:kPrefLeftHanded];
}

- (void)setSwapJumpSneak:(BOOL)swapJumpSneak {
    _swapJumpSneak = swapJumpSneak;
    [NSUserDefaults.standardUserDefaults setBool:swapJumpSneak forKey:kPrefSwapJumpSneak];
}

- (void)setHapticsEnabled:(BOOL)hapticsEnabled {
    _hapticsEnabled = hapticsEnabled;
    [NSUserDefaults.standardUserDefaults setBool:hapticsEnabled forKey:kPrefHapticsEnabled];
}

- (void)setGyroEnabled:(BOOL)gyroEnabled {
    _gyroEnabled = gyroEnabled;
    [NSUserDefaults.standardUserDefaults setBool:gyroEnabled forKey:kPrefGyroEnabled];
}

- (void)setGyroSensitivity:(CGFloat)gyroSensitivity {
    _gyroSensitivity = clampf_cg(gyroSensitivity, 0.20, 3.00);
    [NSUserDefaults.standardUserDefaults setDouble:_gyroSensitivity forKey:kPrefGyroSensitivity];
}

- (void)setSkipLauncher:(BOOL)skipLauncher {
    _skipLauncher = skipLauncher;
    [NSUserDefaults.standardUserDefaults setBool:skipLauncher forKey:kPrefSkipLauncher];
}

- (void)setLastQuickServerAddress:(NSString *)lastQuickServerAddress {
    _lastQuickServerAddress = [lastQuickServerAddress copy];
    if (_lastQuickServerAddress.length > 0) {
        [NSUserDefaults.standardUserDefaults setObject:_lastQuickServerAddress forKey:kPrefLastQuickServer];
    } else {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kPrefLastQuickServer];
    }
}

- (void)setLauncherLanguage:(HorizonLauncherLanguage)launcherLanguage {
    if (launcherLanguage < HorizonLauncherLanguageAuto || launcherLanguage > HorizonLauncherLanguageRussian) {
        launcherLanguage = HorizonLauncherLanguageAuto;
    }
    _launcherLanguage = launcherLanguage;
    [NSUserDefaults.standardUserDefaults setInteger:launcherLanguage forKey:kPrefLauncherLanguage];
}

- (void)setOtaInstaller:(HorizonOTAInstaller)otaInstaller {
    if (otaInstaller < HorizonOTAInstallerAuto || otaInstaller > HorizonOTAInstallerDirect) {
        otaInstaller = HorizonOTAInstallerAuto;
    }
    _otaInstaller = otaInstaller;
    [NSUserDefaults.standardUserDefaults setInteger:otaInstaller forKey:kPrefOTAInstaller];
}

- (void)setAutoCheckUpdates:(BOOL)autoCheckUpdates {
    _autoCheckUpdates = autoCheckUpdates;
    [NSUserDefaults.standardUserDefaults setBool:autoCheckUpdates forKey:kPrefOTAAutoCheck];
}

- (void)setOtaSourceURL:(NSString *)otaSourceURL {
    NSString *trimmed = [otaSourceURL stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        _otaSourceURL = [kDefaultOTASourceURL copy];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kPrefOTASourceURL];
    } else {
        _otaSourceURL = [trimmed copy];
        [NSUserDefaults.standardUserDefaults setObject:_otaSourceURL forKey:kPrefOTASourceURL];
    }
}

- (void)resetOTASourceURL {
    self.otaSourceURL = kDefaultOTASourceURL;
}

- (BOOL)isTapToInteract {
    return self.scheme == HorizonTouchSchemeJoystickTap || self.scheme == HorizonTouchSchemeDpadTap;
}

- (void)resetToDefaults {
    self.scheme = HorizonTouchSchemeJoystickCrosshair;
    self.floatingJoystick = YES;
    self.buttonScale = 1.0;
    self.buttonOpacity = 0.72;
    self.cameraSensitivity = 1.0;
    self.autoJump = YES;
    self.leftHanded = NO;
    self.swapJumpSneak = NO;
    self.hapticsEnabled = YES;
    self.gyroEnabled = NO;
    self.gyroSensitivity = 1.0;
}

- (void)syncToBridge {
    horizon_ios_set_hide_crosshair([self isTapToInteract]);
    horizon_ios_set_touch_auto_jump(self.autoJump);
}

@end
