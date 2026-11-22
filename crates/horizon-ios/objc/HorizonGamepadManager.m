// horizon-ios: native Apple GCController + CoreHaptics controller manager.
// Polls GCExtendedGamepad every frame, tracks inter-frame stick peaks for Horizon's radial menu,
// detects Xbox / PlayStation / Nintendo glyph families, and drives CoreHaptics controller rumble.
#import "HorizonGamepadManager.h"
#import <CoreHaptics/CoreHaptics.h>
#include <math.h>

static uint8_t detectGlyphStyle(GCController *controller) {
    if (controller == nil) {
        return HORIZON_GLYPH_AUTO;
    }
    Class dualSenseClass = NSClassFromString(@"GCDualSenseGamepad");
    Class dualShockClass = NSClassFromString(@"GCDualShockGamepad");
    if ((dualSenseClass && [controller.extendedGamepad isKindOfClass:dualSenseClass]) ||
        (dualShockClass && [controller.extendedGamepad isKindOfClass:dualShockClass])) {
        return HORIZON_GLYPH_PLAYSTATION;
    }
    NSString *cat = (controller.productCategory ?: @"").lowercaseString;
    NSString *vendor = (controller.vendorName ?: @"").lowercaseString;
    if ([cat containsString:@"dualsense"] || [cat containsString:@"dualshock"] ||
        [cat containsString:@"playstation"] || [vendor containsString:@"sony"] ||
        [vendor containsString:@"dualsense"] || [vendor containsString:@"dualshock"]) {
        return HORIZON_GLYPH_PLAYSTATION;
    }
    if ([cat containsString:@"switch"] || [cat containsString:@"joy-con"] ||
        [cat containsString:@"nintendo"] || [vendor containsString:@"nintendo"]) {
        return HORIZON_GLYPH_NINTENDO;
    }
    return HORIZON_GLYPH_XBOX;
}

@interface HorizonGamepadManager ()
@property (nonatomic, strong, nullable) GCController *activeController;
@property (nonatomic, strong, nullable) CHHapticEngine *handlesEngine;
@property (nonatomic, strong, nullable) CHHapticEngine *leftTriggerEngine;
@property (nonatomic, strong, nullable) CHHapticEngine *rightTriggerEngine;
@property (nonatomic, assign) float peakLeftX;
@property (nonatomic, assign) float peakLeftY;
@property (nonatomic, assign) float peakRightX;
@property (nonatomic, assign) float peakRightY;
@property (nonatomic, assign) uint32_t lastButtons;
@property (nonatomic, assign) BOOL started;
@end

@implementation HorizonGamepadManager

- (void)dealloc {
    [self stop];
}

- (BOOL)hasConnectedController {
    for (GCController *c in [GCController controllers]) {
        if (c.extendedGamepad != nil) {
            return YES;
        }
    }
    return NO;
}

- (void)start {
    if (self.started) return;
    self.started = YES;

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self
           selector:@selector(handleControllerConnected:)
               name:GCControllerDidConnectNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(handleControllerDisconnected:)
               name:GCControllerDidDisconnectNotification
             object:nil];

    for (GCController *controller in [GCController controllers]) {
        [self attachController:controller notify:NO];
    }
    if (self.activeController == nil) {
        for (GCController *controller in [GCController controllers]) {
            if (controller.extendedGamepad != nil) {
                [self setActiveGamepad:controller];
                break;
            }
        }
    }
}

- (void)stop {
    if (!self.started) return;
    self.started = NO;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self teardownHaptics];
    self.activeController = nil;
}

- (void)handleControllerConnected:(NSNotification *)note {
    GCController *controller = note.object;
    if (![controller isKindOfClass:GCController.class]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self attachController:controller notify:YES];
    });
}

- (void)handleControllerDisconnected:(NSNotification *)note {
    GCController *controller = note.object;
    if (![controller isKindOfClass:GCController.class]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        uint8_t style = detectGlyphStyle(controller);
        NSLog(@"horizon-ios: GCController disconnected: %@", controller.vendorName ?: controller.productCategory);
        horizon_ios_gamepad_connection(false, style);
        if (self.activeController == controller) {
            [self teardownHaptics];
            self.activeController = nil;
            self.lastButtons = 0;
            // Fall back to another connected controller if one exists.
            for (GCController *other in [GCController controllers]) {
                if (other != controller && other.extendedGamepad != nil) {
                    [self setActiveGamepad:other];
                    break;
                }
            }
            if (self.activeController == nil) {
                HorizonGamepadState empty = {0};
                empty.connected = false;
                horizon_ios_gamepad_update(&empty);
            }
        }
    });
}

- (void)attachController:(GCController *)controller notify:(BOOL)notify {
    if (controller.extendedGamepad == nil) return;
    controller.handlerQueue = dispatch_get_main_queue();

    uint8_t style = detectGlyphStyle(controller);
    NSLog(@"horizon-ios: GCController connected: %@ (category: %@, style: %u)",
          controller.vendorName, controller.productCategory, style);
    if (notify) {
        horizon_ios_gamepad_connection(true, style);
    }
    if (self.activeController == nil) {
        [self setActiveGamepad:controller];
    }

    __weak typeof(self) weakSelf = self;
    __weak GCController *weakController = controller;
    controller.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
        __strong typeof(self) strongSelf = weakSelf;
        __strong GCController *strongCtrl = weakController;
        if (strongSelf == nil || strongCtrl == nil) return;

        // Track peak stick deflections for Horizon's radial menu flick detection.
        float lx = gamepad.leftThumbstick.xAxis.value;
        float ly = gamepad.leftThumbstick.yAxis.value;
        float rx = gamepad.rightThumbstick.xAxis.value;
        float ry = gamepad.rightThumbstick.yAxis.value;
        if (strongSelf.activeController == strongCtrl) {
            if (hypotf(lx, ly) > hypotf(strongSelf.peakLeftX, strongSelf.peakLeftY)) {
                strongSelf.peakLeftX = lx;
                strongSelf.peakLeftY = ly;
            }
            if (hypotf(rx, ry) > hypotf(strongSelf.peakRightX, strongSelf.peakRightY)) {
                strongSelf.peakRightX = rx;
                strongSelf.peakRightY = ry;
            }
        }

        BOOL intentional = NO;
        if ([element isKindOfClass:GCControllerButtonInput.class]) {
            GCControllerButtonInput *btn = (GCControllerButtonInput *)element;
            intentional = btn.isPressed || btn.value > 0.20f;
        } else if (element == gamepad.leftThumbstick) {
            intentional = hypotf(lx, ly) > 0.22f;
        } else if (element == gamepad.rightThumbstick) {
            intentional = hypotf(rx, ry) > 0.22f;
        } else if (element == gamepad.dpad) {
            intentional = gamepad.dpad.up.isPressed || gamepad.dpad.down.isPressed ||
                          gamepad.dpad.left.isPressed || gamepad.dpad.right.isPressed;
        }

        if (intentional) {
            if (strongSelf.activeController != strongCtrl) {
                [strongSelf setActiveGamepad:strongCtrl];
            }
            [strongSelf.delegate gamepadManagerDidDetectActivity:strongCtrl];
        }
    };
}

- (void)setActiveGamepad:(GCController *)controller {
    if (self.activeController == controller) return;
    [self teardownHaptics];
    self.activeController = controller;
    self.peakLeftX = self.peakLeftY = 0.0f;
    self.peakRightX = self.peakRightY = 0.0f;
    self.lastButtons = 0;
    [self setupHapticsForController:controller];
}

- (void)setupHapticsForController:(GCController *)controller {
    GCDeviceHaptics *haptics = controller.haptics;
    if (haptics == nil) return;

    NSSet<GCHapticsLocality> *localities = haptics.supportedLocalities;
    GCHapticsLocality mainLoc = [localities containsObject:GCHapticsLocalityHandles]
        ? GCHapticsLocalityHandles
        : GCHapticsLocalityDefault;
    self.handlesEngine = [haptics createEngineWithLocality:mainLoc];
    if (self.handlesEngine != nil) {
        self.handlesEngine.playsHapticsOnly = YES;
        NSError *err = nil;
        [self.handlesEngine startAndReturnError:&err];
    }

    if ([localities containsObject:GCHapticsLocalityLeftTrigger]) {
        self.leftTriggerEngine = [haptics createEngineWithLocality:GCHapticsLocalityLeftTrigger];
        if (self.leftTriggerEngine != nil) {
            self.leftTriggerEngine.playsHapticsOnly = YES;
            NSError *err = nil;
            [self.leftTriggerEngine startAndReturnError:&err];
        }
    }
    if ([localities containsObject:GCHapticsLocalityRightTrigger]) {
        self.rightTriggerEngine = [haptics createEngineWithLocality:GCHapticsLocalityRightTrigger];
        if (self.rightTriggerEngine != nil) {
            self.rightTriggerEngine.playsHapticsOnly = YES;
            NSError *err = nil;
            [self.rightTriggerEngine startAndReturnError:&err];
        }
    }
}

- (void)teardownHaptics {
    [self.handlesEngine stopWithCompletionHandler:nil];
    [self.leftTriggerEngine stopWithCompletionHandler:nil];
    [self.rightTriggerEngine stopWithCompletionHandler:nil];
    self.handlesEngine = nil;
    self.leftTriggerEngine = nil;
    self.rightTriggerEngine = nil;
}

- (void)playPulseOnEngine:(CHHapticEngine *)engine
                intensity:(float)intensity
                sharpness:(float)sharpness
                 duration:(NSTimeInterval)duration {
    if (engine == nil || intensity <= 0.01f || duration <= 0.005) return;
    @try {
        NSError *err = nil;
        CHHapticEventParameter *pInt = [[CHHapticEventParameter alloc]
            initWithParameterID:CHHapticEventParameterIDHapticIntensity
                          value:fminf(fmaxf(intensity, 0.0f), 1.0f)];
        CHHapticEventParameter *pSharp = [[CHHapticEventParameter alloc]
            initWithParameterID:CHHapticEventParameterIDHapticSharpness
                          value:fminf(fmaxf(sharpness, 0.0f), 1.0f)];
        CHHapticEvent *event = [[CHHapticEvent alloc]
            initWithEventType:CHHapticEventTypeHapticContinuous
                   parameters:@[pInt, pSharp]
                 relativeTime:0.0
                     duration:duration];
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&err];
        if (err != nil || pattern == nil) return;
        [engine startAndReturnError:&err];
        id<CHHapticPatternPlayer> player = [engine createPlayerWithPattern:pattern error:&err];
        if (err == nil && player != nil) {
            [player startAtTime:CHHapticTimeImmediate error:&err];
        }
    } @catch (NSException *ex) {
        (void)ex;
    }
}

- (void)playRumble:(HorizonRumbleEvent)rumble {
    if (self.activeController == nil) return;
    NSTimeInterval duration = fmax((double)rumble.millis / 1000.0, 0.02);
    float mainIntensity = fmaxf(rumble.strong, rumble.weak);
    float sharpness = (rumble.weak > rumble.strong) ? 0.75f : 0.30f;
    [self playPulseOnEngine:self.handlesEngine intensity:mainIntensity sharpness:sharpness duration:duration];
    if (rumble.left_trigger > 0.02f) {
        [self playPulseOnEngine:self.leftTriggerEngine intensity:rumble.left_trigger sharpness:0.6f duration:duration];
    }
    if (rumble.right_trigger > 0.02f) {
        [self playPulseOnEngine:self.rightTriggerEngine intensity:rumble.right_trigger sharpness:0.6f duration:duration];
    }
}

- (void)tick {
    GCController *ctrl = self.activeController;
    GCExtendedGamepad *gp = ctrl.extendedGamepad;
    if (ctrl == nil || gp == nil) {
        return;
    }

    uint32_t buttons = 0;
    if (gp.buttonA.isPressed) buttons |= HORIZON_PAD_SOUTH;
    if (gp.buttonB.isPressed) buttons |= HORIZON_PAD_EAST;
    if (gp.buttonX.isPressed) buttons |= HORIZON_PAD_WEST;
    if (gp.buttonY.isPressed) buttons |= HORIZON_PAD_NORTH;
    if (gp.leftShoulder.isPressed) buttons |= HORIZON_PAD_LEFT_BUMPER;
    if (gp.rightShoulder.isPressed) buttons |= HORIZON_PAD_RIGHT_BUMPER;
    if (gp.buttonOptions.isPressed) buttons |= HORIZON_PAD_SELECT;
    if (gp.buttonMenu.isPressed) buttons |= HORIZON_PAD_START;
    if (gp.leftThumbstickButton.isPressed) buttons |= HORIZON_PAD_LEFT_STICK;
    if (gp.rightThumbstickButton.isPressed) buttons |= HORIZON_PAD_RIGHT_STICK;
    if (gp.dpad.up.isPressed) buttons |= HORIZON_PAD_DPAD_UP;
    if (gp.dpad.down.isPressed) buttons |= HORIZON_PAD_DPAD_DOWN;
    if (gp.dpad.left.isPressed) buttons |= HORIZON_PAD_DPAD_LEFT;
    if (gp.dpad.right.isPressed) buttons |= HORIZON_PAD_DPAD_RIGHT;

    float lx = gp.leftThumbstick.xAxis.value;
    float ly = gp.leftThumbstick.yAxis.value;
    float rx = gp.rightThumbstick.xAxis.value;
    float ry = gp.rightThumbstick.yAxis.value;
    float lt = gp.leftTrigger.value;
    float rt = gp.rightTrigger.value;

    // Also catch sustained activity in case valueChangedHandler was skipped.
    uint32_t newlyPressed = buttons & ~self.lastButtons;
    self.lastButtons = buttons;
    if (newlyPressed != 0 || hypotf(lx, ly) > 0.25f || hypotf(rx, ry) > 0.25f || lt > 0.25f || rt > 0.25f) {
        [self.delegate gamepadManagerDidDetectActivity:ctrl];
    }

    float plx = (hypotf(self.peakLeftX, self.peakLeftY) > hypotf(lx, ly)) ? self.peakLeftX : lx;
    float ply = (hypotf(self.peakLeftX, self.peakLeftY) > hypotf(lx, ly)) ? self.peakLeftY : ly;
    float prx = (hypotf(self.peakRightX, self.peakRightY) > hypotf(rx, ry)) ? self.peakRightX : rx;
    float pry = (hypotf(self.peakRightX, self.peakRightY) > hypotf(rx, ry)) ? self.peakRightY : ry;
    self.peakLeftX = lx;
    self.peakLeftY = ly;
    self.peakRightX = rx;
    self.peakRightY = ry;

    NSString *name = ctrl.vendorName ?: (ctrl.productCategory ?: @"Controller");
    HorizonGamepadState st = {0};
    st.connected = true;
    st.glyph_style = detectGlyphStyle(ctrl);
    st.buttons = buttons;
    st.left_x = lx;
    st.left_y = ly;
    st.right_x = rx;
    st.right_y = ry;
    st.left_trigger = lt;
    st.right_trigger = rt;
    st.peak_left_x = plx;
    st.peak_left_y = ply;
    st.peak_right_x = prx;
    st.peak_right_y = pry;
    st.name = name.UTF8String;
    horizon_ios_gamepad_update(&st);
}

@end
