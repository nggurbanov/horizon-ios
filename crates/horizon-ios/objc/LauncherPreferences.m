// horizon-ios: adapted from Amethyst-iOS (https://github.com/AngelAuraMC/Amethyst-iOS),
// Natives/LauncherPreferences.m and the defaults in Natives/PLPreferences.m. Amethyst-iOS is free software
// under the GNU General Public License v3.0; this file is distributed under the same licence.
//
// Changes for horizon-ios: NSUserDefaults instead of PLPreferences' plist files (no per-instance
// isolation); only the control.*, video.* and debug.* keys the overlay reads.

#import "LauncherPreferences.h"
#import "utils.h"

static NSDictionary<NSString *, id> *defaultPreferences(void) {
    return @{
        // video (Video & Audio)
        @"video.max_framerate": @YES,
        // control
        @"control.default_ctrl": @"default.json",
        @"control.control_safe_area": NSStringFromUIEdgeInsets(getDefaultSafeArea()),
        @"control.recording_hide": @YES,
        @"control.gesture_mouse": @YES,
        @"control.gesture_hotbar": @YES,
        @"control.disable_haptics": @NO,
        @"control.slideable_hotbar": @NO,
        @"control.press_duration": @(400),
        @"control.button_scale": @(100),
        @"control.mouse_scale": @(100),
        @"control.mouse_speed": @(100),
        @"control.virtmouse_enable": @NO,
        @"control.gyroscope_enable": @NO,
        @"control.gyroscope_invert_x_axis": @NO,
        @"control.gyroscope_sensitivity": @(100),
        // debug
        @"debug.debug_auto_correction": @YES,
    };
}

static void registerDefaultsOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSUserDefaults.standardUserDefaults registerDefaults:defaultPreferences()];
    });
}

void loadPreferences(BOOL reset) {
    registerDefaultsOnce();
    if (reset) {
        for (NSString *key in defaultPreferences()) {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        }
    }
}

id getPrefObject(NSString *key) {
    registerDefaultsOnce();
    return [NSUserDefaults.standardUserDefaults objectForKey:key];
}
BOOL getPrefBool(NSString *key) {
    return [getPrefObject(key) boolValue];
}
float getPrefFloat(NSString *key) {
    return [getPrefObject(key) floatValue];
}
NSInteger getPrefInt(NSString *key) {
    return [getPrefObject(key) intValue];
}

void setPrefObject(NSString *key, id value) {
    registerDefaultsOnce();
    [NSUserDefaults.standardUserDefaults setObject:value forKey:key];
}
void setPrefBool(NSString *key, BOOL value) {
    setPrefObject(key, @(value));
}
void setPrefFloat(NSString *key, float value) {
    setPrefObject(key, @(value));
}
void setPrefInt(NSString *key, NSInteger value) {
    setPrefObject(key, @(value));
}

#pragma mark Safe area

CGRect getSafeArea(CGRect screenBounds) {
    UIEdgeInsets safeArea = UIEdgeInsetsFromString(getPrefObject(@"control.control_safe_area"));
    if (screenBounds.size.width < screenBounds.size.height) {
        safeArea = UIEdgeInsetsMake(safeArea.right, safeArea.top, safeArea.left, safeArea.bottom);
    }
    return UIEdgeInsetsInsetRect(screenBounds, safeArea);
}

void setSafeArea(CGSize screenSize, CGRect frame) {
    UIEdgeInsets safeArea;
    // TODO: make safe area consistent across opposite orientations?
    if (screenSize.width < screenSize.height) {
        safeArea = UIEdgeInsetsMake(
            frame.origin.x,
            screenSize.height - CGRectGetMaxY(frame),
            screenSize.width - CGRectGetMaxX(frame),
            frame.origin.y);
    } else {
        safeArea = UIEdgeInsetsMake(
            frame.origin.y,
            frame.origin.x,
            screenSize.height - CGRectGetMaxY(frame),
            screenSize.width - CGRectGetMaxX(frame));
    }
    setPrefObject(@"control.control_safe_area", NSStringFromUIEdgeInsets(safeArea));
}

UIEdgeInsets getDefaultSafeArea(void) {
    // horizon-ios: the overlay's window instead of UIApplication.windows (deprecated in iOS 15).
    UIWindow *window = horizon_keyWindow();
    UIEdgeInsets safeArea = window.safeAreaInsets;
    CGSize screenSize = window != nil ? window.bounds.size : UIScreen.mainScreen.bounds.size;
    if (screenSize.width < screenSize.height) {
        safeArea.left = safeArea.top;
        safeArea.right = safeArea.bottom;
    }
    safeArea.top = safeArea.bottom = 0;
    return safeArea;
}
