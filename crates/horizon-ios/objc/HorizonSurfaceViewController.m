// horizon-ios: adapted from Amethyst-iOS (https://github.com/AngelAuraMC/Amethyst-iOS),
// Natives/SurfaceViewController.m (touch, gesture and on-screen button handling), with the virtual mouse
// tick of Natives/input/ControllerInput.m. Amethyst-iOS is free software under the GNU General Public
// License v3.0; this file is distributed under the same licence.
//
// Changes for horizon-ios:
// - an overlay over winit's view instead of the game's own surface: no GameSurfaceView, no JVM launch,
//   no log view, external display, navigation menu, jetsam or audio settings, no resolution scaling
//   (resolutionScale is 1) and no GCMouse/GCController handling;
// - SPECIALBTN_MENU sends an ESCAPE press and release instead of opening the navigation menu;
// - the grab state is polled on the display link (Amethyst got a call from the JVM);
// - points are converted with the game view's contentScaleFactor, the scale winit renders at;
// - layout follows viewDidLayoutSubviews rather than a rotation coordinator, as the parent is winit's.

#import <QuartzCore/QuartzCore.h>

#import "HorizonSurfaceViewController.h"

#import "customcontrols/ControlButton.h"
#import "customcontrols/ControlDrawer.h"
#import "customcontrols/ControlSubButton.h"
#import "customcontrols/CustomControlsUtils.h"

#import "input/GyroInput.h"
#import "input/KeyboardInput.h"

#import "LauncherPreferences.h"
#import "TrackedTextField.h"
#import "ios_uikit_bridge.h"

#include "glfw_keycodes.h"
#include "utils.h"

#include <math.h>
#include <stdlib.h>

// Read by ControlJoystick (declared extern there). In Amethyst they belonged to ControllerInput.
BOOL leftShiftHeld;
CGFloat lastXValue; // lastHorizontalValue
CGFloat lastYValue; // lastVerticalValue

#define MOUSE_MAX_ACCELERATION 2

static CGRect virtualMouseFrame;
static CGPoint lastVirtualMousePoint;
static int currentHotbarSlot = -1;
static HorizonSurfaceViewController *currentOverlay;

#pragma mark - Display link target

// CADisplayLink retains its target; this proxy keeps the controller from being retained by it.
@interface HorizonDisplayLinkProxy : NSObject
@property(nonatomic, weak) HorizonSurfaceViewController *owner;
- (void)tick:(CADisplayLink *)link;
@end

@interface HorizonSurfaceViewController ()<UITextFieldDelegate, UIGestureRecognizerDelegate>

@property(nonatomic, weak, readwrite) UIView *gameView;

@property(nonatomic) TrackedTextField *inputTextField;
@property(nonatomic) NSMutableArray* swipeableButtons;
@property(nonatomic) ControlButton* swipingButton;
@property(nonatomic) UITouch *primaryTouch, *hotbarTouch;

@property(nonatomic) UILongPressGestureRecognizer* longPressGesture, *longPressTwoGesture;
@property(nonatomic) UITapGestureRecognizer *tapGesture, *doubleTapGesture;

@property(nonatomic) CADisplayLink *displayLink;
@property(nonatomic) CFTimeInterval lastJoystickFrameTime;
@property(nonatomic) BOOL hasGrabState, lastGrabState;
@property(nonatomic) CGSize lastLayoutSize;

@property(nonatomic) CGFloat screenScale;
@property(nonatomic) CGFloat mouseSpeed;
@property(nonatomic) CGRect clickRange;
@property(nonatomic) BOOL shouldHideControlsFromRecording,
    shouldTriggerClick, shouldTriggerHaptic, slideableHotbar, toggleHidden;

@property(nonatomic) BOOL enableMouseGestures, enableHotbarGestures;

@property(nonatomic) UIImpactFeedbackGenerator *lightHaptic;
@property(nonatomic) UIImpactFeedbackGenerator *mediumHaptic;

- (void)tickInput;

@end

// horizon-ios: HangWatchdog.m, which writes every thread's stack to the log when these stop.
void horizon_ios_heartbeat(void);
void horizon_ios_start_watchdog(void);

@implementation HorizonDisplayLinkProxy

- (void)tick:(CADisplayLink *)link {
    horizon_ios_heartbeat();
    HorizonSurfaceViewController *owner = self.owner;
    if (owner == nil) {
        [link invalidate];
        return;
    }
    [owner tickInput];
}

@end

#pragma mark - Helpers

// Amethyst ships a "MousePointer" image asset; draw an arrow when the app has none.
static UIImage* horizon_mousePointerImage(void) {
    UIImage *asset = [UIImage imageNamed:@"MousePointer"];
    if (asset != nil) {
        return asset;
    }
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(18.0, 27.0)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:CGPointMake(1.0, 1.0)];
        [path addLineToPoint:CGPointMake(1.0, 22.0)];
        [path addLineToPoint:CGPointMake(6.0, 17.0)];
        [path addLineToPoint:CGPointMake(10.0, 26.0)];
        [path addLineToPoint:CGPointMake(13.5, 24.5)];
        [path addLineToPoint:CGPointMake(9.5, 16.0)];
        [path addLineToPoint:CGPointMake(16.0, 16.0)];
        [path closePath];
        path.lineWidth = 1.5;
        path.lineJoinStyle = kCGLineJoinRound;
        [UIColor.whiteColor setFill];
        [path fill];
        [UIColor.blackColor setStroke];
        [path stroke];
    }];
}

// The host sets AME_HOME to the app's Documents folder; fall back to it if the host did not.
static void horizon_ensureAmeHome(void) {
    if (getenv("AME_HOME") != NULL) {
        return;
    }
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (documents != nil) {
        setenv("AME_HOME", documents.fileSystemRepresentation, 0);
    }
}

static int keycodeAt(ControlButton *button, int i) {
    NSArray *keycodes = button.properties[@"keycodes"];
    if (![keycodes isKindOfClass:NSArray.class] || i >= (int)keycodes.count) {
        return 0;
    }
    return [keycodes[i] intValue];
}

@implementation HorizonSurfaceViewController

+ (HorizonSurfaceViewController *)current {
    return currentOverlay;
}

- (void)dealloc {
    [_displayLink invalidate];
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    isControlModifiable = NO;

    self.view.backgroundColor = UIColor.clearColor;
    self.view.opaque = NO;
    self.view.multipleTouchEnabled = YES;

    self.lightHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:(UIImpactFeedbackStyleLight)];
    self.mediumHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:(UIImpactFeedbackStyleMedium)];

    UIApplication.sharedApplication.idleTimerDisabled = YES;

    // Tick the gyroscope, the virtual mouse joystick and the grab state with the display.
    HorizonDisplayLinkProxy *proxy = [HorizonDisplayLinkProxy new];
    proxy.owner = self;
    self.displayLink = [CADisplayLink displayLinkWithTarget:proxy selector:@selector(tick:)];
    if (getPrefBool(@"video.max_framerate")) {
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 120);
    } else {
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
    }
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    CGRect bounds = self.view.bounds;

    self.touchView = [[UIView alloc] initWithFrame:bounds];
    self.touchView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.touchView.backgroundColor = UIColor.clearColor;
    self.touchView.opaque = NO;
    self.touchView.multipleTouchEnabled = YES;
    [self.view addSubview:self.touchView];

    self.ctrlView = [[ControlLayout alloc] initWithFrame:getSafeArea(bounds)];
    self.ctrlView.backgroundColor = UIColor.clearColor;
    self.ctrlView.multipleTouchEnabled = YES;
    [self.view addSubview:self.ctrlView];

    UIHoverGestureRecognizer *hoverGesture = [[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(surfaceOnHover:)];
    [self.touchView addGestureRecognizer:hoverGesture];

    self.tapGesture = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(surfaceOnClick:)];
    self.tapGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.tapGesture.delegate = self;
    self.tapGesture.numberOfTapsRequired = 1;
    self.tapGesture.numberOfTouchesRequired = 1;
    self.tapGesture.cancelsTouchesInView = NO;
    [self.touchView addGestureRecognizer:self.tapGesture];

    self.doubleTapGesture = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(surfaceOnDoubleClick:)];
    self.doubleTapGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.doubleTapGesture.delegate = self;
    self.doubleTapGesture.numberOfTapsRequired = 2;
    self.doubleTapGesture.numberOfTouchesRequired = 1;
    self.doubleTapGesture.cancelsTouchesInView = NO;
    [self.touchView addGestureRecognizer:self.doubleTapGesture];

    self.longPressGesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(surfaceOnLongpress:)];
    self.longPressGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.longPressGesture.cancelsTouchesInView = NO;
    self.longPressGesture.delegate = self;
    [self.touchView addGestureRecognizer:self.longPressGesture];

    self.longPressTwoGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(keyboardGesture:)];
    self.longPressTwoGesture.numberOfTouchesRequired = 2;
    self.longPressTwoGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.longPressTwoGesture.cancelsTouchesInView = NO;
    self.longPressTwoGesture.delegate = self;
    [self.touchView addGestureRecognizer:self.longPressTwoGesture];

    self.scrollPanGesture = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(surfaceOnTouchesScroll:)];
    self.scrollPanGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.scrollPanGesture.delegate = self;
    self.scrollPanGesture.minimumNumberOfTouches = 2;
    self.scrollPanGesture.maximumNumberOfTouches = 2;
    [self.touchView addGestureRecognizer:self.scrollPanGesture];

    // Virtual mouse
    virtualMouseEnabled = getPrefBool(@"control.virtmouse_enable");
    virtualMouseFrame = CGRectMake(bounds.size.width / 2, bounds.size.height / 2, 18, 27);
    self.mousePointerView = [[UIImageView alloc] initWithFrame:virtualMouseFrame];
    self.mousePointerView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin |UIViewAutoresizingFlexibleBottomMargin;
    self.mousePointerView.hidden = !virtualMouseEnabled;
    self.mousePointerView.image = horizon_mousePointerImage();
    self.mousePointerView.userInteractionEnabled = NO;
    [self.touchView addSubview:self.mousePointerView];

    // The on-screen keyboard's text field, kept just above the top edge.
    self.inputTextField = [[TrackedTextField alloc] initWithFrame:CGRectMake(0, -32.0, bounds.size.width, 30.0)];
    self.inputTextField.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.inputTextField.delegate = self;
    self.inputTextField.font = [UIFont fontWithName:@"Menlo-Regular" size:20];
    self.inputTextField.clearsOnBeginEditing = YES;
    self.inputTextField.textAlignment = NSTextAlignmentCenter;
    self.inputTextField.sendChar = ^(uint32_t keychar){
        CallbackBridge_nativeSendChar(keychar);
    };
    self.inputTextField.sendCharMods = ^(uint32_t keychar, int mods){
        CallbackBridge_nativeSendCharMods(keychar, mods);
    };
    self.inputTextField.sendKey = ^(int key, int scancode, int action, int mods) {
        CallbackBridge_nativeSendKey(key, scancode, action, mods);
    };
    [self.view addSubview:self.inputTextField];

    self.swipeableButtons = [[NSMutableArray alloc] init];

    [KeyboardInput initKeycodeTable];

    [self updatePreferenceChanges];
    [self loadCustomControls];
}

- (void)attachToGameView:(UIView *)gameView {
    UIViewController *parent = gameView.window.rootViewController;

    if (self.gameView == gameView && self.isViewLoaded && self.view.superview == gameView &&
        self.parentViewController == parent) {
        // Already over this view: keep it on top.
        [gameView bringSubviewToFront:self.view];
        [self becomeFirstResponder];
        return;
    }

    // Leave the previous game view, if any.
    if (self.parentViewController != nil) {
        [self willMoveToParentViewController:nil];
        [self.viewIfLoaded removeFromSuperview];
        [self removeFromParentViewController];
    } else {
        [self.viewIfLoaded removeFromSuperview];
    }

    self.gameView = gameView;
    self.lastLayoutSize = CGSizeZero;

    if (parent != nil && parent != self) {
        [parent addChildViewController:self];
    }
    UIView *overlay = self.view; // loads the view (viewDidLoad) on the first attach
    overlay.frame = gameView.bounds;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [gameView addSubview:overlay];
    // horizon-ios: wgpu adds its CAMetalLayer to the game view's layer after this, as a sibling
    // of the overlay's: without a higher z it drew over the controls (which still took touches).
    overlay.layer.zPosition = 1000;
    if (parent != nil && parent != self) {
        [self didMoveToParentViewController:parent];
    }

    [self layoutForCurrentSize];
    self.hasGrabState = NO;
    [self tickInput];
    BOOL responder = [self becomeFirstResponder];
    // horizon-ios: how the overlay sits, for a report from a device (Documents/horizon-log.txt).
    NSLog(@"horizon-ios: overlay attached to %@ %@ in window %@ (root %@, parent %@), %lu controls, first responder %d, interaction %d",
        NSStringFromClass(gameView.class), NSStringFromCGRect(gameView.frame), gameView.window,
        gameView.window.rootViewController, self.parentViewController,
        (unsigned long)self.ctrlView.subviews.count, responder, gameView.userInteractionEnabled);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!CGSizeEqualToSize(self.view.bounds.size, self.lastLayoutSize)) {
        [self layoutForCurrentSize];
    }
}

// Amethyst did this in -viewWillTransitionToSize:withTransitionCoordinator:.
- (void)layoutForCurrentSize {
    CGRect bounds = self.view.bounds;
    self.lastLayoutSize = bounds.size;

    self.touchView.frame = bounds;
    self.inputTextField.frame = CGRectMake(0, -32.0, bounds.size.width, 30.0);

    // Update custom controls button position (ControlLayout's -setFrame: updates every button)
    self.ctrlView.frame = getSafeArea(bounds);

    virtualMouseFrame.origin.x = clamp(virtualMouseFrame.origin.x, 0, bounds.size.width);
    virtualMouseFrame.origin.y = clamp(virtualMouseFrame.origin.y, 0, bounds.size.height);
    self.mousePointerView.frame = virtualMouseFrame;

    // Update game resolution
    [self updateSavedResolution];
    [GyroInput updateOrientation];
}

- (void)updatePreferenceChanges {
    // Update UITextField auto correction
    if (getPrefBool(@"debug.debug_auto_correction")) {
        self.inputTextField.autocorrectionType = UITextAutocorrectionTypeDefault;
    } else {
        self.inputTextField.autocorrectionType = UITextAutocorrectionTypeNo;
    }

    BOOL gyroEnabled = getPrefBool(@"control.gyroscope_enable");
    BOOL gyroInvertX = getPrefBool(@"control.gyroscope_invert_x_axis");
    int gyroSensitivity = (int)getPrefInt(@"control.gyroscope_sensitivity");
    [GyroInput updateSensitivity:gyroEnabled?gyroSensitivity:0 invertXAxis:gyroInvertX];

    self.mouseSpeed = getPrefFloat(@"control.mouse_speed") / 100.0;

    virtualMouseEnabled = getPrefBool(@"control.virtmouse_enable");
    self.mousePointerView.hidden = isGrabbing || !virtualMouseEnabled;

    // Update virtual mouse scale
    CGFloat mouseScale = getPrefFloat(@"control.mouse_scale") / 100.0;
    virtualMouseFrame = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 18.0 * mouseScale, 27 * mouseScale);
    self.mousePointerView.frame = virtualMouseFrame;

    self.shouldHideControlsFromRecording = getPrefBool(@"control.recording_hide");
    [self.ctrlView hideViewFromCapture:self.shouldHideControlsFromRecording];
    self.ctrlView.frame = getSafeArea(self.view.bounds);

    // Update gestures state
    self.slideableHotbar = getPrefBool(@"control.slideable_hotbar");
    self.enableMouseGestures = getPrefBool(@"control.gesture_mouse");
    self.enableHotbarGestures = getPrefBool(@"control.gesture_hotbar");
    self.shouldTriggerHaptic = !getPrefBool(@"control.disable_haptics");

    self.scrollPanGesture.enabled = self.enableMouseGestures && !isGrabbing;
    self.doubleTapGesture.enabled = self.enableHotbarGestures;
    self.longPressGesture.minimumPressDuration = getPrefFloat(@"control.press_duration") / 1000.0;

    // Update resolution
    [self updateSavedResolution];
}

- (void)updateSavedResolution {
    UIView *gameView = self.gameView;
    CGFloat scale = gameView.contentScaleFactor;
    if (scale <= 0) {
        scale = gameView.window.screen.scale;
    }
    if (scale <= 0) {
        scale = UIScreen.mainScreen.scale;
    }
    self.screenScale = scale;

    CGSize size = self.isViewLoaded ? self.view.bounds.size : gameView.bounds.size;
    physicalWidth = (int)round(size.width * self.screenScale);
    physicalHeight = (int)round(size.height * self.screenScale);
    // resolutionScale is always 1 here: the game renders at the view's own scale.
    windowWidth = physicalWidth;
    windowHeight = physicalHeight;
    if (windowWidth > 0 && windowHeight > 0) {
        CallbackBridge_nativeSendScreenSize(windowWidth, windowHeight);
    }
}

- (void)updateControlHiddenState:(BOOL)hide {
    for (UIView *view in self.ctrlView.subviews) {
        if (![view isKindOfClass:ControlButton.class]) continue;
        ControlButton *button = (ControlButton *)view;
        if (!button.canBeHidden) continue;
        BOOL hidden = hide || !(
            (isGrabbing && [button.properties[@"displayInGame"] boolValue]) ||
            (!isGrabbing && [button.properties[@"displayInMenu"] boolValue]));
        if (!hidden && ![button isKindOfClass:ControlSubButton.class]) {
            button.hidden = hidden;
            if ([button isKindOfClass:ControlDrawer.class]) {
                [(ControlDrawer *)button restoreButtonVisibility];
            }
        } else if (hidden) {
            button.hidden = hidden;
        }
    }
}

- (void)updateGrabState {
    // Update cursor position
    if (isGrabbing == JNI_TRUE) {
        CGFloat screenScale = self.screenScale;
        CallbackBridge_nativeSendCursorPos(ACTION_DOWN, lastVirtualMousePoint.x * screenScale, lastVirtualMousePoint.y * screenScale);
        virtualMouseFrame.origin.x = self.view.bounds.size.width / 2;
        virtualMouseFrame.origin.y = self.view.bounds.size.height / 2;
        self.mousePointerView.frame = virtualMouseFrame;
    }
    // horizon-ios: also honour the control.gesture_mouse pref here.
    self.scrollPanGesture.enabled = !isGrabbing && self.enableMouseGestures;
    self.mousePointerView.hidden = isGrabbing || !virtualMouseEnabled;

    // Update buttons visibility (horizon-ios: keeps the "Hide GUI" toggle, Amethyst passed NO)
    [self updateControlHiddenState:self.toggleHidden];
}

- (void)tickInput {
    if (self.viewIfLoaded.window == nil) {
        return;
    }

    // Amethyst's JVM told the controller when the grab changed; poll it instead.
    BOOL grabbing = isGrabbing;
    if (!self.hasGrabState || grabbing != self.lastGrabState) {
        self.hasGrabState = YES;
        self.lastGrabState = grabbing;
        [self updateGrabState];
    }

    [GyroInput tick];

    // From ControllerInput's tick: the joystick moves the virtual mouse while not grabbing.
    CFTimeInterval frameTime = CACurrentMediaTime();
    if (!grabbing && self.lastJoystickFrameTime != 0 && (lastXValue != 0 || lastYValue != 0)) {
        CGFloat acceleration = pow(MathUtils_dist(0, 0, lastXValue, lastYValue), MOUSE_MAX_ACCELERATION); // magnitude
        if (acceleration > 1) acceleration = 1;

        // Compute delta since last tick time
        CGFloat deltaX = lastXValue * acceleration * 18;
        CGFloat deltaY = -lastYValue * acceleration * 18;
        CGFloat deltaTimeScale = (frameTime - self.lastJoystickFrameTime) / (1.0/60.0); // Scale of 1 = 60Hz
        deltaX *= deltaTimeScale;
        deltaY *= deltaTimeScale;

        [self sendTouchPoint:CGPointMake(deltaX, deltaY) withEvent:ACTION_MOVE_MOTION];
    }
    self.lastJoystickFrameTime = frameTime;
}

- (void)loadCustomControls {
    [self.swipeableButtons removeAllObjects];
    generateAndSaveDefaultControl();
    NSString *controlFile = getPrefObject(@"control.default_ctrl");
    if (![controlFile isKindOfClass:NSString.class] || controlFile.length == 0) {
        controlFile = @"default.json";
    }
    [self.ctrlView loadControlFile:controlFile];

    for (UIView *view in self.ctrlView.subviews) {
        if (![view isKindOfClass:ControlButton.class]) continue;
        ControlButton *button = (ControlButton *)view;
        BOOL isSwipeable = [button.properties[@"isSwipeable"] boolValue];

        button.canBeHidden = YES;
        for (int i = 0; i < 4; i++) {
            int keycodeInt = keycodeAt(button, i);
            button.canBeHidden &= keycodeInt != SPECIALBTN_TOGGLECTRL && keycodeInt != SPECIALBTN_VIRTUALMOUSE;
        }

        [button addTarget:self action:@selector(executebtn_down:) forControlEvents:UIControlEventTouchDown];
        [button addTarget:self action:@selector(executebtn_up_inside:) forControlEvents:UIControlEventTouchUpInside];
        [button addTarget:self action:@selector(executebtn_up_outside:) forControlEvents:UIControlEventTouchUpOutside];

        if (isSwipeable) {
            UIPanGestureRecognizer *panRecognizerButton = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(executebtn_swipe:)];
            panRecognizerButton.delegate = self;
            [button addGestureRecognizer:panRecognizerButton];
            [self.swipeableButtons addObject:button];
        }
    }

    [self updateControlHiddenState:self.toggleHidden];
}

#pragma mark - Input: send touch utilities

- (BOOL)isTouchInactive:(UITouch *)touch {
    return touch == nil || touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled;
}

- (void)sendTouchPoint:(CGPoint)location withEvent:(int)event
{
    CGFloat screenScale = self.screenScale;
    if (!isGrabbing) {
        screenScale *= resolutionScale;
        if (virtualMouseEnabled) {
            if (event == ACTION_MOVE) {
                virtualMouseFrame.origin.x += (location.x - lastVirtualMousePoint.x) * self.mouseSpeed;
                virtualMouseFrame.origin.y += (location.y - lastVirtualMousePoint.y) * self.mouseSpeed;
            } else if (event == ACTION_MOVE_MOTION) {
                event = ACTION_MOVE;
                virtualMouseFrame.origin.x += location.x * self.mouseSpeed;
                virtualMouseFrame.origin.y += location.y * self.mouseSpeed;
            }
            virtualMouseFrame.origin.x = clamp(virtualMouseFrame.origin.x, 0, self.view.bounds.size.width);
            virtualMouseFrame.origin.y = clamp(virtualMouseFrame.origin.y, 0, self.view.bounds.size.height);
            lastVirtualMousePoint = location;
            self.mousePointerView.frame = virtualMouseFrame;
            CallbackBridge_nativeSendCursorPos(event, virtualMouseFrame.origin.x * screenScale, virtualMouseFrame.origin.y * screenScale);
            return;
        }
        lastVirtualMousePoint = location;
    }
    CallbackBridge_nativeSendCursorPos(event, location.x * screenScale, location.y * screenScale);
}

#pragma mark - Input: on-surface functions

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)toggleKeyboard {
    if (self.inputTextField.isFirstResponder) {
        [self.inputTextField resignFirstResponder];
        self.inputTextField.alpha = 1.0f;
        // horizon-ios: take the hardware keyboard's presses back.
        [self becomeFirstResponder];
    } else {
        [self.inputTextField becomeFirstResponder];
        // Insert an undeletable space
        self.inputTextField.text = @" ";
    }
}

- (void)keyboardGesture:(UIGestureRecognizer*)gestureRecognizer {
    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        [self toggleKeyboard];
    }
}

- (void)sendTouchEvent:(UITouch *)touchEvent withUIEvent:(UIEvent *)uievent withEvent:(int)event
{
    CGPoint locationInView = [touchEvent locationInView:self.view];

    switch (event) {
        case ACTION_DOWN:
            self.clickRange = CGRectMake(locationInView.x - 2, locationInView.y - 2, 5, 5);
            self.shouldTriggerClick = YES;
            break;

        case ACTION_MOVE:
            if (self.shouldTriggerClick && !CGRectContainsPoint(self.clickRange, locationInView)) {
                self.shouldTriggerClick = NO;
            }
            break;
    }

    if (touchEvent == self.hotbarTouch && self.slideableHotbar && ![self isTouchInactive:self.hotbarTouch]) {
        CGFloat screenScale = self.screenScale;
        int slot = self.enableHotbarGestures ?
        callback_SurfaceViewController_touchHotbar(locationInView.x * screenScale, locationInView.y * screenScale) : -1;
        if (slot != -1 && currentHotbarSlot != slot && (event == ACTION_DOWN || currentHotbarSlot != -1)) {
            currentHotbarSlot = slot;
            CallbackBridge_nativeSendKey(slot, 0, 1, 0);
            CallbackBridge_nativeSendKey(slot, 0, 0, 0);
            return;
        }

        if (event == ACTION_DOWN && slot == -1) {
            currentHotbarSlot = -1;
        }
        return;
    }

    if (touchEvent == self.primaryTouch) {
        if ([self isTouchInactive:self.primaryTouch]) return; // FIXME: should be? ACTION_UP will never be sent
        if (event == ACTION_MOVE && isGrabbing) {
            event = ACTION_MOVE_MOTION;
            CGPoint prevLocationInView = [touchEvent previousLocationInView:self.view];
            locationInView.x -= prevLocationInView.x;
            locationInView.y -= prevLocationInView.y;
        }
        [self sendTouchPoint:locationInView withEvent:event];
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;

    for (UIPress *press in presses) {
        if (press.key != nil && [KeyboardInput sendKeyEvent:press.key down:YES]) {
            handled = YES;
        }
    }

    if (!handled) {
        [super pressesBegan:presses withEvent:event];
    }
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;

    for (UIPress *press in presses) {
        if (press.key != nil && [KeyboardInput sendKeyEvent:press.key down:NO]) {
            handled = YES;
        }
    }

    if (!handled) {
        [super pressesEnded:presses withEvent:event];
    }
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    // horizon-ios: release keys whose press was cancelled (e.g. the app lost focus), so none stay held.
    BOOL handled = NO;

    for (UIPress *press in presses) {
        if (press.key != nil && [KeyboardInput sendKeyEvent:press.key down:NO]) {
            handled = YES;
        }
    }

    if (!handled) {
        [super pressesCancelled:presses withEvent:event];
    }
}

- (void)surfaceOnClick:(UITapGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.lightHaptic impactOccurred];
        }
    }

    static int logged = 0;
    if (logged < 10 && sender.state == UIGestureRecognizerStateRecognized) {
        logged++;
        NSLog(@"horizon-ios: tap (click %d, hotbar slot %d, mouse gestures %d)",
            self.shouldTriggerClick, currentHotbarSlot, self.enableMouseGestures);
    }
    if (!self.shouldTriggerClick) return;

    if (sender.state == UIGestureRecognizerStateRecognized) {
        if (currentHotbarSlot == -1) {
            if (!self.enableMouseGestures) return;
            CallbackBridge_nativeSendMouseButton(isGrabbing == JNI_TRUE ?
                GLFW_MOUSE_BUTTON_RIGHT : GLFW_MOUSE_BUTTON_LEFT, 1, 0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 33 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                CallbackBridge_nativeSendMouseButton(isGrabbing == JNI_TRUE ?
                    GLFW_MOUSE_BUTTON_RIGHT : GLFW_MOUSE_BUTTON_LEFT, 0, 0);
            });
        } else {
            CallbackBridge_nativeSendKey(currentHotbarSlot, 0, 1, 0);
            CallbackBridge_nativeSendKey(currentHotbarSlot, 0, 0, 0);
        }
    }
}

- (void)surfaceOnDoubleClick:(UITapGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.lightHaptic impactOccurred];
        }
    }

    if (sender.state == UIGestureRecognizerStateRecognized && isGrabbing) {
        CGFloat screenScale = self.screenScale;
        CGPoint point = [sender locationInView:self.view];
        int hotbarSlot = self.enableHotbarGestures ?
            callback_SurfaceViewController_touchHotbar(point.x * screenScale, point.y * screenScale) : -1;
        if (hotbarSlot != -1 && currentHotbarSlot == hotbarSlot) {
            CallbackBridge_nativeSendKey(GLFW_KEY_F, 0, 1, 0);
            CallbackBridge_nativeSendKey(GLFW_KEY_F, 0, 0, 0);
        }
    }
}

- (void)surfaceOnHover:(UIGestureRecognizer *)sender {
    if (isGrabbing) return;

    CGPoint point = [sender locationInView:self.view];
    switch (sender.state) {
        case UIGestureRecognizerStateBegan:
            [self sendTouchPoint:point withEvent:ACTION_DOWN];
            break;
        case UIGestureRecognizerStateChanged:
            [self sendTouchPoint:point withEvent:ACTION_MOVE];
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
            [self sendTouchPoint:point withEvent:ACTION_UP];
            break;
        default:
            break;
    }
}

-(void)surfaceOnLongpress:(UILongPressGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.mediumHaptic impactOccurred];
        }
    }

    if (!self.slideableHotbar) {
        CGPoint location = [sender locationInView:self.view];
        CGFloat screenScale = self.screenScale;
        currentHotbarSlot = self.enableHotbarGestures ?
            callback_SurfaceViewController_touchHotbar(location.x * screenScale, location.y * screenScale) : -1;
    }
    if (sender.state == UIGestureRecognizerStateBegan) {
        self.shouldTriggerClick = NO;
        if (currentHotbarSlot == -1) {
            if (self.enableMouseGestures)
                CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, 1, 0);
        } else {
            CallbackBridge_nativeSendKey(GLFW_KEY_Q, 0, 1, 0);
        }
    } else if (sender.state == UIGestureRecognizerStateChanged) {
        // Nothing to do here, already handled in touchesMoved
    } else if (sender.state == UIGestureRecognizerStateCancelled
        || sender.state == UIGestureRecognizerStateFailed
            || sender.state == UIGestureRecognizerStateEnded)
    {
        if (currentHotbarSlot == -1) {
            if (self.enableMouseGestures)
                CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, 0, 0);
        } else {
            CallbackBridge_nativeSendKey(GLFW_KEY_Q, 0, 0, 0);
        }
    }
}

- (void)surfaceOnTouchesScroll:(UIPanGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.lightHaptic impactOccurred];
        }
    }

    if (isGrabbing) return;
    if (sender.state == UIGestureRecognizerStateBegan ||
        sender.state == UIGestureRecognizerStateChanged ||
        sender.state == UIGestureRecognizerStateEnded) {
        CGPoint velocity = [sender velocityInView:self.view];
        CGSize size = self.view.bounds.size;
        if ((velocity.x != 0.0f || velocity.y != 0.0f) && size.width > 0 && size.height > 0) {
            CallbackBridge_nativeSendScroll(velocity.x/size.width, velocity.y/size.height);
        }
    }
}

#pragma mark - Input view stuff

-(BOOL)textFieldShouldReturn:(UITextField *)textField {
    CallbackBridge_nativeSendKey(GLFW_KEY_ENTER, 0, 1, 0);
    CallbackBridge_nativeSendKey(GLFW_KEY_ENTER, 0, 0, 0);
    textField.text = @" ";
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    // horizon-ios: the keyboard was dismissed (perhaps by the system); take the presses back.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.viewIfLoaded.window != nil && !self.inputTextField.isFirstResponder) {
            [self becomeFirstResponder];
        }
    });
}

#pragma mark - On-screen button functions

- (void)executebtn:(ControlButton *)sender withAction:(int)action {
    if (sender == nil) return;
    int held = action == ACTION_DOWN;
    for (int i = 0; i < 4; i++) {
        int keycode = keycodeAt(sender, i);
        if (keycode < 0) {
            switch (keycode) {
                case SPECIALBTN_KEYBOARD:
                    if (held == 0) {
                        [self toggleKeyboard];
                    }
                    break;

                case SPECIALBTN_MOUSEPRI:
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, held, 0);
                    break;

                case SPECIALBTN_MOUSESEC:
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_RIGHT, held, 0);
                    break;

                case SPECIALBTN_MOUSEMID:
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_MIDDLE, held, 0);
                    break;

                case SPECIALBTN_TOGGLECTRL:
                    [self executebtn_special_togglebtn:held];
                    break;

                case SPECIALBTN_SCROLLDOWN:
                    if (!held) {
                        CallbackBridge_nativeSendScroll(0.0, 1.0);
                    }
                    break;

                case SPECIALBTN_SCROLLUP:
                    if (!held) {
                        CallbackBridge_nativeSendScroll(0.0, -1.0);
                    }
                    break;

                case SPECIALBTN_VIRTUALMOUSE:
                    if (!isGrabbing && !held) {
                        virtualMouseEnabled = !virtualMouseEnabled;
                        self.mousePointerView.hidden = !virtualMouseEnabled;
                        setPrefBool(@"control.virtmouse_enable", virtualMouseEnabled);
                    }
                    break;

                case SPECIALBTN_MENU:
                    // horizon-ios: no navigation menu; the button is the game's Escape key.
                    if (!held) {
                        CallbackBridge_nativeSendKey(GLFW_KEY_ESCAPE, 0, 1, 0);
                        CallbackBridge_nativeSendKey(GLFW_KEY_ESCAPE, 0, 0, 0);
                    }
                    break;

                default:
                    NSLog(@"Warning: button %@ sent unknown special keycode: %d", sender.titleLabel.text, keycode);
                    break;
            }
        } else if (keycode > 0) {
            // there's no key id 0, but we accidentally used -1 as a special key id, so we had to do that
            // at the moment, send unknown keycode does nothing, may even cause performance issue, so ignore it
            CallbackBridge_nativeSendKey(keycode, 0, held, 0);
        }
    }
}

- (void)executebtn_down:(ControlButton *)sender
{
    if(self.shouldTriggerHaptic) {
        [self.lightHaptic impactOccurred];
    }

    if (sender.savedBackgroundColor == nil) {
        [self executebtn:sender withAction:ACTION_DOWN];
    }
    if ([self.swipeableButtons containsObject:sender]) {
        self.swipingButton = sender;
    }
}

- (void)executebtn_swipe:(UIPanGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateCancelled || sender.state == UIGestureRecognizerStateEnded) {
        [self executebtn_up:self.swipingButton isOutside:NO];
        return;
    }
    CGPoint location = [sender locationInView:self.ctrlView];
    for (ControlButton *button in self.swipeableButtons) {
        if (CGRectContainsPoint(button.frame, location) && self.swipingButton != button) {
            [self executebtn_up:self.swipingButton isOutside:NO];
            self.swipingButton = button;
            [self executebtn:self.swipingButton withAction:ACTION_DOWN];
            break;
        }
    }
}

- (void)executebtn_up:(ControlButton *)sender isOutside:(BOOL)isOutside
{
    if (sender == nil) return;
    if (self.swipingButton == sender) {
        [self executebtn:self.swipingButton withAction:ACTION_UP];
        self.swipingButton = nil;
    } else if (sender.savedBackgroundColor == nil) {
        [self executebtn:sender withAction:ACTION_UP];
        return;
    }

    if (isOutside || sender.savedBackgroundColor == nil) {
        return;
    }

    sender.isToggleOn = !sender.isToggleOn;
    if (sender.isToggleOn) {
        sender.backgroundColor = [self.view.tintColor colorWithAlphaComponent:CGColorGetAlpha(sender.savedBackgroundColor.CGColor)];
        [self executebtn:sender withAction:ACTION_DOWN];
    } else {
        sender.backgroundColor = sender.savedBackgroundColor;
        [self executebtn:sender withAction:ACTION_UP];
    }

    if(self.shouldTriggerHaptic) {
        [self.lightHaptic impactOccurred];
    }
}

- (void)executebtn_up_inside:(ControlButton *)sender {
    [self executebtn_up:sender isOutside:NO];
}

- (void)executebtn_up_outside:(ControlButton *)sender {
    [self executebtn_up:sender isOutside:YES];
}

- (void)executebtn_special_togglebtn:(int)held {
    if (held) return;
    self.toggleHidden = !self.toggleHidden;
    [self updateControlHiddenState:self.toggleHidden];
}

#pragma mark - Input: On-screen touch events
// horizon-ios: none of these call super. A UIViewController passes touches up the responder chain,
// which here leads to winit's view; the overlay keeps every touch to itself.

// Equals to Android ACTION_DOWN
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    static int logged = 0;
    if (logged < 10) {
        logged++;
        UITouch *first = touches.anyObject;
        NSLog(@"horizon-ios: touch began at %@ (type %ld), grabbing %d",
            NSStringFromCGPoint([first locationInView:self.view]), (long)first.type, isGrabbing);
    }
    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeIndirectPointer) {
            continue; // handle this in a different place
        }
        CGPoint locationInView = [touch locationInView:self.view];
        CGFloat screenScale = self.screenScale;
        currentHotbarSlot = self.enableHotbarGestures ?
            callback_SurfaceViewController_touchHotbar(locationInView.x * screenScale, locationInView.y * screenScale) : -1;
        if ([self isTouchInactive:self.hotbarTouch] && currentHotbarSlot != -1) {
            self.hotbarTouch = touch;
        }
        if ([self isTouchInactive:self.primaryTouch] && currentHotbarSlot == -1) {
            self.primaryTouch = touch;
        }
        [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_DOWN];
        break;
    }
}

// Equals to Android ACTION_MOVE
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeIndirectPointer) {
            if (!isGrabbing && !virtualMouseEnabled) {
                CGPoint point = [touch locationInView:self.view];
                [self sendTouchPoint:point withEvent:ACTION_MOVE];
            }
            continue; // handle this in a different place
        }
        if (self.hotbarTouch != touch && [self isTouchInactive:self.primaryTouch]) {
            // Replace the inactive touch with the current active touch
            self.primaryTouch = touch;
            [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_DOWN];
        }
        [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_MOVE];
    }
}

// For ACTION_UP and ACTION_CANCEL
- (void)touchesEndedGlobal:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeIndirectPointer) {
            continue; // handle this in a different place
        }
        [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_UP];
    }
}

// Equals to Android ACTION_UP
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self touchesEndedGlobal:touches withEvent:event];
}

// Equals to Android ACTION_CANCEL
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self touchesEndedGlobal:touches withEvent:event];
}

@end

#pragma mark - Bridge entry point

void horizon_ios_attach_overlay(void *ui_view) {
    NSLog(@"horizon-ios: attaching the overlay (main thread %d)", NSThread.isMainThread);
    horizon_ios_start_watchdog();
    if (ui_view == NULL) {
        return;
    }
    UIView *gameView = (__bridge UIView *)ui_view;
    void (^attach)(void) = ^{
        horizon_ensureAmeHome();
        if (currentOverlay == nil) {
            currentOverlay = [[HorizonSurfaceViewController alloc] init];
        }
        [currentOverlay attachToGameView:gameView];
    };
    if (NSThread.isMainThread) {
        attach();
    } else {
        // The contract says main thread; stay safe if it is broken.
        dispatch_async(dispatch_get_main_queue(), attach);
    }
}
