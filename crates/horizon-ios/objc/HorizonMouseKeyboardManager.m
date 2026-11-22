// horizon-ios: native Apple GCMouse, GCKeyboard, UIPress fallback, and CoreMotion gyroscope manager.
#import "HorizonMouseKeyboardManager.h"
#import "HorizonSettings.h"
#import <CoreMotion/CoreMotion.h>
#include "horizon_bridge.h"
#include <math.h>

@interface HorizonMouseKeyboardManager ()
@property (nonatomic, strong) NSMutableSet<NSNumber *> *heldHidKeys;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *heldMouseButtons;
@property (nonatomic, strong, nullable) CMMotionManager *motionManager;
@property (nonatomic, assign) BOOL gyroRunning;
@property (nonatomic, assign) BOOL started;
@end

@implementation HorizonMouseKeyboardManager

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _heldHidKeys = [NSMutableSet set];
        _heldMouseButtons = [NSMutableSet set];
        _softwareCursorPoints = CGPointMake(200.0, 150.0);
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)hasConnectedMouse {
    return GCMouse.mice.count > 0 || GCMouse.current != nil;
}

- (BOOL)hasConnectedKeyboard {
    return GCKeyboard.coalescedKeyboard != nil;
}

- (void)start {
    if (self.started) return;
    self.started = YES;

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(handleMouseConnected:) name:GCMouseDidConnectNotification object:nil];
    [nc addObserver:self selector:@selector(handleMouseDisconnected:) name:GCMouseDidDisconnectNotification object:nil];
    [nc addObserver:self selector:@selector(handleKeyboardConnected:) name:GCKeyboardDidConnectNotification object:nil];
    [nc addObserver:self selector:@selector(handleKeyboardDisconnected:) name:GCKeyboardDidDisconnectNotification object:nil];
    [nc addObserver:self selector:@selector(handleAppWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];

    for (GCMouse *mouse in GCMouse.mice) {
        [self attachMouse:mouse];
    }
    if (GCKeyboard.coalescedKeyboard != nil) {
        [self attachKeyboard:GCKeyboard.coalescedKeyboard];
    }
    [self updateGyroSettings];
}

- (void)stop {
    if (!self.started) return;
    self.started = NO;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self releaseAllHeldKeys];
    [self stopGyro];
}

- (void)handleAppWillResignActive:(NSNotification *)note {
    [self releaseAllHeldKeys];
}

- (void)releaseAllHeldKeys {
    if (self.heldHidKeys.count > 0) {
        NSArray<NSNumber *> *keys = self.heldHidKeys.allObjects;
        [self.heldHidKeys removeAllObjects];
        for (NSNumber *code in keys) {
            horizon_ios_send_key((uint16_t)code.unsignedShortValue, false);
        }
        horizon_ios_send_modifiers(0);
    }
    if (self.heldMouseButtons.count > 0) {
        NSArray<NSNumber *> *btns = self.heldMouseButtons.allObjects;
        [self.heldMouseButtons removeAllObjects];
        for (NSNumber *btn in btns) {
            horizon_ios_send_mouse_button((uint8_t)btn.unsignedCharValue, false);
        }
    }
}

#pragma mark - Modifiers

- (void)syncModifiersFromHeldKeys {
    uint8_t mask = 0;
    if ([self.heldHidKeys containsObject:@(0xE1)] || [self.heldHidKeys containsObject:@(0xE5)]) {
        mask |= HORIZON_MOD_SHIFT;
    }
    if ([self.heldHidKeys containsObject:@(0xE0)] || [self.heldHidKeys containsObject:@(0xE4)]) {
        mask |= HORIZON_MOD_CTRL;
    }
    if ([self.heldHidKeys containsObject:@(0xE2)] || [self.heldHidKeys containsObject:@(0xE6)]) {
        mask |= HORIZON_MOD_ALT;
    }
    if ([self.heldHidKeys containsObject:@(0xE3)] || [self.heldHidKeys containsObject:@(0xE7)]) {
        mask |= HORIZON_MOD_SUPER;
    }
    horizon_ios_send_modifiers(mask);
}

#pragma mark - GCMouse

- (void)handleMouseConnected:(NSNotification *)note {
    GCMouse *mouse = note.object;
    if (![mouse isKindOfClass:GCMouse.class]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self attachMouse:mouse];
    });
}

- (void)handleMouseDisconnected:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self releaseAllHeldKeys];
    });
}

- (void)attachMouse:(GCMouse *)mouse {
    GCMouseInput *input = mouse.mouseInput;
    if (input == nil) return;
    mouse.handlerQueue = dispatch_get_main_queue();

    NSLog(@"horizon-ios: GCMouse attached: %@", mouse.vendorName ?: @"Mouse");
    __weak typeof(self) weakSelf = self;

    input.mouseMovedHandler = ^(GCMouseInput *m, float deltaX, float deltaY) {
        (void)m;
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        if (deltaX == 0.0f && deltaY == 0.0f) return;

        [strongSelf.delegate hardwareInputDidActivateKeyboardMouse];
        // Apple GCMouseInput uses +deltaY UP; Minecraft / UIKit uses +Y DOWN.
        double dx = (double)deltaX;
        double dy = (double)(-deltaY);
        if ([strongSelf.delegate hardwareInputIsGrabbing]) {
            horizon_ios_send_look(dx, dy);
        } else {
            CGSize sz = [strongSelf.delegate hardwareInputViewSizePoints];
            CGFloat scale = [strongSelf.delegate hardwareInputScreenScale];
            if (sz.width > 0.0 && sz.height > 0.0) {
                CGPoint p = strongSelf.softwareCursorPoints;
                p.x = fmin(fmax(p.x + dx, 0.0), sz.width);
                p.y = fmin(fmax(p.y + dy, 0.0), sz.height);
                strongSelf.softwareCursorPoints = p;
                horizon_ios_send_cursor(p.x * scale, p.y * scale);
            }
        }
    };

    void (^bindButton)(GCDeviceButtonInput *, uint8_t) = ^(GCDeviceButtonInput *btn, uint8_t idx) {
        if (btn == nil) return;
        btn.pressedChangedHandler = ^(GCControllerButtonInput *b, float value, BOOL pressed) {
            (void)b;
            (void)value;
            __strong typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) return;
            [strongSelf.delegate hardwareInputDidActivateKeyboardMouse];
            if (pressed) {
                [strongSelf.heldMouseButtons addObject:@(idx)];
            } else {
                [strongSelf.heldMouseButtons removeObject:@(idx)];
            }
            horizon_ios_send_mouse_button(idx, pressed);
        };
    };

    bindButton(input.leftButton, 0);
    bindButton(input.rightButton, 1);
    bindButton(input.middleButton, 2);
    NSArray<GCDeviceButtonInput *> *aux = input.auxiliaryButtons;
    for (NSUInteger i = 0; i < aux.count && i < 5; i++) {
        bindButton(aux[i], (uint8_t)(3 + i));
    }

    input.scroll.valueChangedHandler = ^(GCControllerDirectionPad *dpad, float xValue, float yValue) {
        (void)dpad;
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        if (fabsf(xValue) < 0.01f && fabsf(yValue) < 0.01f) return;
        [strongSelf.delegate hardwareInputDidActivateKeyboardMouse];
        horizon_ios_send_scroll(xValue, yValue);
    };
}

#pragma mark - GCKeyboard

- (void)handleKeyboardConnected:(NSNotification *)note {
    GCKeyboard *kb = note.object;
    if (![kb isKindOfClass:GCKeyboard.class]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self attachKeyboard:kb];
    });
}

- (void)handleKeyboardDisconnected:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self releaseAllHeldKeys];
    });
}

- (void)attachKeyboard:(GCKeyboard *)keyboard {
    GCKeyboardInput *input = keyboard.keyboardInput;
    if (input == nil) return;
    keyboard.handlerQueue = dispatch_get_main_queue();

    NSLog(@"horizon-ios: GCKeyboard attached");
    __weak typeof(self) weakSelf = self;
    input.keyChangedHandler = ^(GCKeyboardInput *kb, GCDeviceButtonInput *key, GCKeyCode keyCode, BOOL pressed) {
        (void)kb;
        (void)key;
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        uint16_t hid = (uint16_t)keyCode;
        if (hid == 0) return;

        // While the user is typing directly inside our native UIKit UITextField (chat bar),
        // let UIKit handle character input cleanly and only watch Escape / Tab / Enter / Arrows.
        if ([strongSelf.delegate hardwareInputIsTextFieldEditing]) {
            BOOL isControl = (hid == HORIZON_HID_ESCAPE || hid == HORIZON_HID_TAB ||
                              hid == HORIZON_HID_UP_ARROW || hid == HORIZON_HID_DOWN_ARROW);
            if (!isControl) {
                return;
            }
        }

        [strongSelf.delegate hardwareInputDidActivateKeyboardMouse];
        if (pressed) {
            [strongSelf.heldHidKeys addObject:@(hid)];
        } else {
            [strongSelf.heldHidKeys removeObject:@(hid)];
        }
        [strongSelf syncModifiersFromHeldKeys];
        horizon_ios_send_key(hid, pressed);
    };
}

#pragma mark - UIPress fallback (and character text for hardware keyboards)

- (BOOL)handlePressesBegan:(NSSet<UIPress *> *)presses {
    BOOL handled = NO;
    BOOL gcHandlesPhysical = self.hasConnectedKeyboard;
    BOOL editingNativeField = [self.delegate hardwareInputIsTextFieldEditing];

    for (UIPress *press in presses) {
        UIKey *key = press.key;
        if (key == nil) continue;
        uint16_t hid = (uint16_t)key.keyCode;
        if (hid == 0) continue;

        if (editingNativeField) {
            // Native UITextField handles regular typing; intercept Escape/Tab/Arrows cleanly.
            if (hid == HORIZON_HID_ESCAPE || hid == HORIZON_HID_TAB ||
                hid == HORIZON_HID_UP_ARROW || hid == HORIZON_HID_DOWN_ARROW) {
                if (!gcHandlesPhysical) {
                    horizon_ios_send_key(hid, true);
                }
                handled = YES;
            }
            continue;
        }

        [self.delegate hardwareInputDidActivateKeyboardMouse];
        handled = YES;

        if (!gcHandlesPhysical) {
            [self.heldHidKeys addObject:@(hid)];
            [self syncModifiersFromHeldKeys];
            horizon_ios_send_key(hid, true);
        }

        // Hardware keyboards typing into in-game non-native fields (signs, books, search boxes):
        // GCKeyboard only provides raw HID codes, so UIPress supplies the layout-aware text!
        NSString *chars = key.characters;
        if (chars.length > 0 && !(key.modifierFlags & (UIKeyModifierControl | UIKeyModifierCommand))) {
            unichar first = [chars characterAtIndex:0];
            if (first >= 0x20 && first != 0x7F &&
                !(first >= 0xF700 && first <= 0xF8FF)) {
                horizon_ios_send_text(chars.UTF8String);
            }
        }
    }
    return handled;
}

- (BOOL)handlePressesEndedOrCancelled:(NSSet<UIPress *> *)presses {
    BOOL handled = NO;
    BOOL gcHandlesPhysical = self.hasConnectedKeyboard;
    for (UIPress *press in presses) {
        UIKey *key = press.key;
        if (key == nil) continue;
        uint16_t hid = (uint16_t)key.keyCode;
        if (hid == 0) continue;
        handled = YES;
        if (!gcHandlesPhysical && [self.heldHidKeys containsObject:@(hid)]) {
            [self.heldHidKeys removeObject:@(hid)];
            [self syncModifiersFromHeldKeys];
            horizon_ios_send_key(hid, false);
        }
    }
    return handled;
}

#pragma mark - Optional CoreMotion Gyroscope Aiming

- (void)updateGyroSettings {
    if (HorizonSettings.shared.gyroEnabled) {
        [self startGyro];
    } else {
        [self stopGyro];
    }
}

- (void)startGyro {
    if (self.gyroRunning) return;
    if (self.motionManager == nil) {
        self.motionManager = [[CMMotionManager alloc] init];
    }
    if (!self.motionManager.isDeviceMotionAvailable) return;
    self.motionManager.deviceMotionUpdateInterval = 1.0 / 60.0;
    [self.motionManager startDeviceMotionUpdates];
    self.gyroRunning = YES;
}

- (void)stopGyro {
    if (!self.gyroRunning) return;
    [self.motionManager stopDeviceMotionUpdates];
    self.gyroRunning = NO;
}

- (void)tickGyro {
    if (!self.gyroRunning || ![self.delegate hardwareInputIsGrabbing]) return;
    CMDeviceMotion *motion = self.motionManager.deviceMotion;
    if (motion == nil) return;
    CMRotationRate rate = motion.rotationRate;
    double sens = (double)HorizonSettings.shared.gyroSensitivity * 6.5;
    UIInterfaceOrientation orient = UIInterfaceOrientationLandscapeRight;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState == UISceneActivationStateForegroundActive) {
                orient = ws.interfaceOrientation;
                break;
            }
        }
    }
    double sign = (orient == UIInterfaceOrientationLandscapeLeft) ? -1.0 : 1.0;
    double dx = -rate.x * sens * sign;
    double dy = -rate.y * sens * sign;
    if (fabs(dx) > 0.02 || fabs(dy) > 0.02) {
        horizon_ios_send_look(dx, dy);
    }
}

@end
