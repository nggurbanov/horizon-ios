// horizon-ios: master native Bedrock Touch / Gamepad / Keyboard+Mouse overlay view controller.
//
// Features:
// - Seamless 3-mode auto-switching: Touch <-> Gamepad (GCController) <-> Keyboard+Mouse (GCMouse/GCKeyboard)
// - Real iOS pointer lock via childViewControllerForPointerLock + prefersPointerLocked
// - Per-finger multitouch with zero gesture-recognizer delay on the gameplay surface
// - All 3 official Bedrock schemes (Joystick+Crosshair, Joystick+Tap, Classic D-Pad+Tap)
// - Contextual gameplay buttons (Fly Up/Down hold-only, Swim Up/Down, Dismount, Elytra, Sword/Pickaxe, Verbs)
// - Exact game-driven hotbar tap/swipe/hold-drop + flush `⋯` Inventory button
// - Bedrock Inventory UX (top-right `✕`, Quick Move Shift toggle, Drop toggle, hold-to-split-stack green bar)
// - Auto-keyboard on every text field + Bedrock Top Chat Bar synced bidirectionally above the keyboard
// - Native UIImpactFeedbackGenerator + CoreHaptics controller rumble + HangWatchdog heartbeat
#import "HorizonOverlayViewController.h"
#import "HorizonGamepadManager.h"
#import "HorizonIcons.h"
#import "HorizonL10n.h"
#import "HorizonMouseKeyboardManager.h"
#import "HorizonSettings.h"
#import "HorizonTouchSettingsViewController.h"
#import "HorizonTouchViews.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include "horizon_bridge.h"
#include <math.h>

static HorizonOverlayViewController *sCurrentOverlay = nil;

#pragma mark - Pointer Lock forwarding on parent/root ViewController

static void horizon_installPointerLockForwarding(UIViewController *vc) {
    if (vc == nil || [vc isKindOfClass:HorizonOverlayViewController.class]) return;
    Class cls = object_getClass(vc);
    static NSMutableSet<NSString *> *patchedClasses = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        patchedClasses = [NSMutableSet set];
    });
    NSString *className = NSStringFromClass(cls);
    if ([patchedClasses containsObject:className]) return;
    [patchedClasses addObject:className];

    SEL sel = @selector(childViewControllerForPointerLock);
    Method origMethod = class_getInstanceMethod(cls, sel);
    IMP origIMP = origMethod ? method_getImplementation(origMethod) : NULL;

    UIViewController * (^block)(id) = ^UIViewController *(id selfObj) {
        HorizonOverlayViewController *overlay = sCurrentOverlay;
        if (overlay != nil) {
            UIViewController *p = overlay.parentViewController;
            while (p != nil) {
                if (p == selfObj) {
                    return overlay;
                }
                p = p.parentViewController;
            }
        }
        if (origIMP != NULL) {
            return ((UIViewController *(*)(id, SEL))origIMP)(selfObj, sel);
        }
        return nil;
    };
    IMP newIMP = imp_implementationWithBlock(block);
    const char *types = origMethod ? method_getTypeEncoding(origMethod) : "@@:";
    if (!class_addMethod(cls, sel, newIMP, types)) {
        method_setImplementation(origMethod, newIMP);
    }
}

#pragma mark - DisplayLink proxy (avoids retain cycle)

@interface HorizonOverlayDisplayLinkProxy : NSObject
@property (nonatomic, weak) HorizonOverlayViewController *owner;
- (void)onTick:(CADisplayLink *)link;
@end

#pragma mark - Per-finger touch state

typedef NS_ENUM(NSInteger, HorizonFingerRole) {
    HorizonFingerRoleNone = 0,
    HorizonFingerRoleTopBar,
    HorizonFingerRoleJoystick,
    HorizonFingerRoleDpad,
    HorizonFingerRoleButton,
    HorizonFingerRoleHotbar,
    HorizonFingerRoleCameraOrWorld,
    HorizonFingerRoleInventory,
    HorizonFingerRoleMenu,
};

typedef NS_ENUM(NSInteger, HorizonActionTag) {
    HorizonActionTagNone = 0,
    HorizonActionTagJump,
    HorizonActionTagSneak,
    HorizonActionTagAttack,
    HorizonActionTagUse,
    HorizonActionTagContextPill,
    HorizonActionTagPause,
    HorizonActionTagChat,
    HorizonActionTagPerspective,
    HorizonActionTagSettings,
    HorizonActionTagInventory,
    HorizonActionTagMenuClose,
    HorizonActionTagMenuBack,
    HorizonActionTagInvQuickMove,
    HorizonActionTagInvDrop,
};

@interface HorizonFingerRecord : NSObject
@property (nonatomic, assign) HorizonFingerRole role;
@property (nonatomic, assign) HorizonActionTag actionTag;
@property (nonatomic, assign) CGPoint startPoint;
@property (nonatomic, assign) CGPoint currentPoint;
@property (nonatomic, assign) CGPoint lastPoint;
@property (nonatomic, assign) CFTimeInterval startTime;
@property (nonatomic, assign) BOOL dragged;
@property (nonatomic, assign) BOOL worldHoldActive;
@property (nonatomic, assign) int hotbarSlot;
@property (nonatomic, assign) CFTimeInterval hotbarSlotSince;
@property (nonatomic, assign) BOOL hotbarSingleDropped;
@property (nonatomic, assign) BOOL hotbarStackDropped;
@property (nonatomic, assign) CFTimeInterval hotbarLastRepeatDrop;
@property (nonatomic, assign) BOOL invSplitStarted;
@property (nonatomic, assign) BOOL invSplitTriggered;
@property (nonatomic, assign) BOOL invMouseDown;
@property (nonatomic, assign) BOOL invQuickMoveModSent;
@property (nonatomic, assign) uint8_t dpadMask;
@property (nonatomic, assign) BOOL dpadCenterIsJump;
@end

@implementation HorizonFingerRecord
@end

#pragma mark - Proxy hidden text field for non-chat in-game fields

@interface HorizonProxyTextField : UITextField
@property (nonatomic, copy, nullable) void (^onDeleteBackward)(void);
@end

@implementation HorizonProxyTextField
- (void)deleteBackward {
    [super deleteBackward];
    if (self.onDeleteBackward) {
        self.onDeleteBackward();
    }
}
@end

#pragma mark - HorizonOverlayViewController

@interface HorizonOverlayViewController () <
    HorizonGamepadManagerDelegate,
    HorizonMouseKeyboardDelegate,
    HorizonChatBarDelegate,
    UITextFieldDelegate
>

@property (nonatomic, weak) UIView *gameView;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) HorizonGamepadManager *gamepadManager;
@property (nonatomic, strong) HorizonMouseKeyboardManager *hwManager;

@property (nonatomic, strong) UIImpactFeedbackGenerator *lightHaptic;
@property (nonatomic, strong) UIImpactFeedbackGenerator *mediumHaptic;
@property (nonatomic, strong) UIImpactFeedbackGenerator *heavyHaptic;
@property (nonatomic, strong) UINotificationFeedbackGenerator *notifHaptic;

// Active input mode & latest Rust state
@property (nonatomic, assign) uint8_t inputMode;
@property (nonatomic, assign) HorizonOverlayState gameState;
@property (nonatomic, assign) BOOL hasGameState;
@property (nonatomic, assign) BOOL lastFlying;
@property (nonatomic, assign) BOOL lastRiding;
@property (nonatomic, assign) BOOL lastTextFieldFocused;
@property (nonatomic, assign) BOOL lastChatOpen;
@property (nonatomic, assign) uint64_t lastChatRevision;
@property (nonatomic, assign) BOOL keyboardDismissedForCurrentField;
@property (nonatomic, assign) BOOL lastPointerLockedWanted;
@property (nonatomic, assign) CGFloat screenScale;
@property (nonatomic, assign) CGSize lastLayoutSize;
@property (nonatomic, assign) CGFloat keyboardInsetPoints;

// Containers
@property (nonatomic, strong) UIView *gameplayHudView;
@property (nonatomic, strong) UIView *inventoryHudView;
@property (nonatomic, strong) UIView *menuHudView;

// Gameplay HUD elements
@property (nonatomic, strong) HorizonBedrockButton *pauseButton;
@property (nonatomic, strong) HorizonBedrockButton *chatButton;
@property (nonatomic, strong) HorizonBedrockButton *perspectiveButton;
@property (nonatomic, strong) HorizonBedrockButton *settingsButton;

@property (nonatomic, strong) HorizonJoystickView *joystickView;
@property (nonatomic, strong) HorizonDpadView *dpadView;

@property (nonatomic, strong) HorizonBedrockButton *jumpButton;
@property (nonatomic, strong) HorizonBedrockButton *sneakButton;
@property (nonatomic, strong) HorizonBedrockButton *attackButton;
@property (nonatomic, strong) HorizonBedrockButton *useButton;
@property (nonatomic, strong) HorizonContextPillView *contextPill;

@property (nonatomic, strong) HorizonBedrockButton *inventoryDotsButton;
@property (nonatomic, strong) HorizonBreakRingView *breakRingView;
@property (nonatomic, strong) HorizonGreenProgressBar *hotbarDropBar;

// Inventory / Container HUD elements
@property (nonatomic, strong) HorizonBedrockButton *invCloseButton;
@property (nonatomic, strong) HorizonBedrockButton *invQuickMoveButton;
@property (nonatomic, strong) HorizonBedrockButton *invDropButton;
@property (nonatomic, strong) HorizonGreenProgressBar *invSplitBar;
@property (nonatomic, assign) BOOL invQuickMoveEnabled;
@property (nonatomic, assign) BOOL invDropEnabled;

// Menu HUD elements
@property (nonatomic, strong) HorizonBedrockButton *menuBackButton;

// Chat & text input
@property (nonatomic, strong) HorizonChatBarView *chatBar;
@property (nonatomic, strong) HorizonProxyTextField *proxyTextField;

// Touch tracking state
@property (nonatomic, strong) NSMapTable<UITouch *, HorizonFingerRecord *> *activeTouches;
@property (nonatomic, assign) BOOL sneakToggled;
@property (nonatomic, assign) BOOL sneakHeldByTouch;
@property (nonatomic, assign) BOOL sprintHeldByTouch;
@property (nonatomic, assign) BOOL sprintLocked;
@property (nonatomic, assign) BOOL dpadSprinting;
@property (nonatomic, assign) CFTimeInterval lastDpadForwardTapTime;
@property (nonatomic, assign) CGRect hotbarPointsRect;
@property (nonatomic, assign) CGPoint lastTwoFingerMidpoint;
@property (nonatomic, assign) BOOL twoFingerScrolling;
@property (nonatomic, assign) NSUInteger jumpReleaseToken;
@property (nonatomic, assign) BOOL jumpPhysicallyDown;

- (void)tickFrame;

@end

@implementation HorizonOverlayDisplayLinkProxy
- (void)onTick:(CADisplayLink *)link {
    horizon_ios_heartbeat();
    HorizonOverlayViewController *owner = self.owner;
    if (owner == nil) {
        [link invalidate];
        return;
    }
    [owner tickFrame];
}
@end

@implementation HorizonOverlayViewController

+ (HorizonOverlayViewController *)current {
    return sCurrentOverlay;
}

- (void)dealloc {
    [self.displayLink invalidate];
    [self.gamepadManager stop];
    [self.hwManager stop];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeAll;
}

- (BOOL)prefersPointerLocked {
    return self.inputMode == HORIZON_INPUT_MODE_KEYBOARD_MOUSE
        && self.gameState.grabbing
        && self.presentedViewController == nil
        && self.hwManager.hasConnectedMouse;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.opaque = NO;
    self.view.multipleTouchEnabled = YES;

    self.inputMode = HORIZON_INPUT_MODE_TOUCH;
    self.activeTouches = [NSMapTable strongToStrongObjectsMapTable];
    self.screenScale = MAX(UIScreen.mainScreen.scale, 1.0);

    self.lightHaptic  = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    self.mediumHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    self.heavyHaptic  = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
    self.notifHaptic  = [[UINotificationFeedbackGenerator alloc] init];

    UIApplication.sharedApplication.idleTimerDisabled = YES;

    [HorizonSettings.shared syncToBridge];
    horizon_ios_set_input_mode(HORIZON_INPUT_MODE_TOUCH);

    [self buildSubviews];

    // Indirect mouse / iPad trackpad hover when pointer is unlocked (menus & inventories).
    UIHoverGestureRecognizer *hover = [[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(handlePointerHover:)];
    [self.view addGestureRecognizer:hover];

    // Hardware input managers
    self.gamepadManager = [[HorizonGamepadManager alloc] init];
    self.gamepadManager.delegate = self;
    [self.gamepadManager start];

    self.hwManager = [[HorizonMouseKeyboardManager alloc] init];
    self.hwManager.delegate = self;
    [self.hwManager start];

    // Keyboard & app lifecycle observers
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(handleKeyboardWillChangeFrame:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [nc addObserver:self selector:@selector(handleKeyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    [nc addObserver:self selector:@selector(handleAppWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];

    // DisplayLink (60-120Hz) for state polling, watchdog heartbeat, gamepad polling, gyro, timers
    HorizonOverlayDisplayLinkProxy *proxy = [[HorizonOverlayDisplayLinkProxy alloc] init];
    proxy.owner = self;
    self.displayLink = [CADisplayLink displayLinkWithTarget:proxy selector:@selector(onTick:)];
    if (@available(iOS 15.0, *)) {
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    }
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)buildSubviews {
    CGRect bounds = self.view.bounds;

    // 1. Gameplay HUD container
    self.gameplayHudView = [[UIView alloc] initWithFrame:bounds];
    self.gameplayHudView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.gameplayHudView.backgroundColor = UIColor.clearColor;
    self.gameplayHudView.userInteractionEnabled = NO;
    [self.view addSubview:self.gameplayHudView];

    self.pauseButton       = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconPause circular:NO];
    self.chatButton        = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconChat circular:NO];
    self.perspectiveButton = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconPerspective circular:NO];
    self.settingsButton    = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconSettings circular:NO];

    self.joystickView = [[HorizonJoystickView alloc] init];
    self.dpadView     = [[HorizonDpadView alloc] init];

    self.jumpButton   = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconJump circular:YES];
    self.sneakButton  = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconSneak circular:YES];
    self.attackButton = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconPickaxe circular:YES];
    self.useButton    = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconHand circular:YES];
    self.contextPill  = [[HorizonContextPillView alloc] init];
    self.contextPill.hidden = YES;

    self.inventoryDotsButton = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconInventoryDots circular:NO];
    self.inventoryDotsButton.hidden = YES;

    self.breakRingView = [[HorizonBreakRingView alloc] initWithFrame:CGRectMake(0, 0, 72, 72)];
    self.breakRingView.hidden = YES;

    self.hotbarDropBar = [[HorizonGreenProgressBar alloc] initWithFrame:CGRectMake(0, 0, 32, 6)];
    self.hotbarDropBar.hidden = YES;

    for (UIView *v in @[
        self.pauseButton, self.chatButton, self.perspectiveButton, self.settingsButton,
        self.joystickView, self.dpadView,
        self.jumpButton, self.sneakButton, self.attackButton, self.useButton,
        self.contextPill, self.inventoryDotsButton, self.breakRingView, self.hotbarDropBar
    ]) {
        [self.gameplayHudView addSubview:v];
    }

    // 2. Inventory / Container HUD container
    self.inventoryHudView = [[UIView alloc] initWithFrame:bounds];
    self.inventoryHudView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.inventoryHudView.backgroundColor = UIColor.clearColor;
    self.inventoryHudView.userInteractionEnabled = NO;
    self.inventoryHudView.hidden = YES;
    [self.view addSubview:self.inventoryHudView];

    self.invCloseButton = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconClose circular:NO];
    self.invQuickMoveButton = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconQuickMove circular:NO];
    self.invQuickMoveButton.caption = @"Shift";
    self.invDropButton = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconDrop circular:NO];
    self.invDropButton.caption = HL(@"Drop", @"Сброс");
    self.invSplitBar = [[HorizonGreenProgressBar alloc] initWithFrame:CGRectMake(0, 0, 44, 7)];
    self.invSplitBar.hidden = YES;

    for (UIView *v in @[self.invCloseButton, self.invQuickMoveButton, self.invDropButton, self.invSplitBar]) {
        [self.inventoryHudView addSubview:v];
    }

    // 3. Regular Menu HUD container
    self.menuHudView = [[UIView alloc] initWithFrame:bounds];
    self.menuHudView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.menuHudView.backgroundColor = UIColor.clearColor;
    self.menuHudView.userInteractionEnabled = NO;
    self.menuHudView.hidden = YES;
    [self.view addSubview:self.menuHudView];

    self.menuBackButton = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconBack circular:NO];
    [self.menuHudView addSubview:self.menuBackButton];

    // 4. Native Bedrock Top Chat Bar (receives direct UIKit touches!)
    self.chatBar = [[HorizonChatBarView alloc] initWithFrame:CGRectZero];
    self.chatBar.delegate = self;
    self.chatBar.hidden = YES;
    [self.view addSubview:self.chatBar];

    // 5. Hidden proxy text field for non-chat in-game text boxes (signs, books, search, anvil, world name)
    self.proxyTextField = [[HorizonProxyTextField alloc] initWithFrame:CGRectMake(0, -40, 200, 32)];
    self.proxyTextField.delegate = self;
    self.proxyTextField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.proxyTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.proxyTextField.spellCheckingType = UITextSpellCheckingTypeNo;
    self.proxyTextField.returnKeyType = UIReturnKeyDone;
    self.proxyTextField.text = @" ";
    __weak typeof(self) weakSelf = self;
    self.proxyTextField.onDeleteBackward = ^{
        horizon_ios_send_key(HORIZON_HID_BACKSPACE, true);
        horizon_ios_send_key(HORIZON_HID_BACKSPACE, false);
        weakSelf.proxyTextField.text = @" ";
    };
    [self.view addSubview:self.proxyTextField];
}

#pragma mark - Attachment & Layout

- (void)attachToGameView:(UIView *)gameView {
    UIViewController *parent = gameView.window.rootViewController;

    if (self.gameView == gameView && self.isViewLoaded && self.view.superview == gameView &&
        self.parentViewController == parent) {
        [gameView bringSubviewToFront:self.view];
        self.view.layer.zPosition = 1000;
        [self becomeFirstResponder];
        return;
    }

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
    UIView *overlay = self.view;
    overlay.frame = gameView.bounds;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [gameView addSubview:overlay];
    // CRITICAL INVARIANT: wgpu adds its CAMetalLayer to gameView.layer AFTER attachment;
    // zPosition = 1000 keeps the overlay cleanly above the rendered Metal layer.
    overlay.layer.zPosition = 1000;

    if (parent != nil && parent != self) {
        [self didMoveToParentViewController:parent];
    }

    // Install pointer-lock forwarding on parent and any ancestor VCs so prefersPointerLocked works.
    UIViewController *walk = parent;
    while (walk != nil) {
        horizon_installPointerLockForwarding(walk);
        walk = walk.parentViewController;
    }

    [self updateScreenScale];
    [self layoutControls];
    [self applySettingsToViews];
    [self becomeFirstResponder];

    NSLog(@"horizon-ios: native Bedrock overlay attached to %@ %@ (scale %.1f)",
          NSStringFromClass(gameView.class), NSStringFromCGRect(gameView.frame), self.screenScale);
}

- (void)updateScreenScale {
    CGFloat scale = self.gameView.contentScaleFactor;
    if (scale <= 0.0) scale = self.gameView.window.screen.scale;
    if (scale <= 0.0) scale = UIScreen.mainScreen.scale;
    self.screenScale = MAX(scale, 1.0);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateScreenScale];
    if (!CGSizeEqualToSize(self.view.bounds.size, self.lastLayoutSize)) {
        self.lastLayoutSize = self.view.bounds.size;
        [self layoutControls];
    }
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self layoutControls];
}

- (void)applySettingsToViews {
    HorizonSettings *s = HorizonSettings.shared;
    [s syncToBridge];
    [self.hwManager updateGyroSettings];

    CGFloat op = s.buttonOpacity;
    for (HorizonBedrockButton *btn in @[
        self.pauseButton, self.chatButton, self.perspectiveButton, self.settingsButton,
        self.jumpButton, self.sneakButton, self.attackButton, self.useButton,
        self.inventoryDotsButton, self.invCloseButton, self.invQuickMoveButton,
        self.invDropButton, self.menuBackButton
    ]) {
        btn.hudOpacity = op;
    }
    self.joystickView.hudOpacity = op;
    self.joystickView.floatingMode = s.floatingJoystick;
    self.dpadView.hudOpacity = op;
    self.contextPill.hudOpacity = op;

    [self layoutControls];
    [self updateHudVisibility];
}

- (void)layoutControls {
    CGRect bounds = self.view.bounds;
    if (bounds.size.width < 10.0 || bounds.size.height < 10.0) return;

    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat safeL = MAX(safe.left, 14.0);
    CGFloat safeR = MAX(safe.right, 14.0);
    CGFloat safeT = MAX(safe.top, 6.0);
    CGFloat safeB = MAX(safe.bottom, 12.0);

    HorizonSettings *s = HorizonSettings.shared;
    CGFloat scale = s.buttonScale;
    BOOL leftHanded = s.leftHanded;

    // 1. Top center Bedrock mini-bar: Pause, Chat, Perspective, Touch Settings
    CGFloat topW = 36.0;
    CGFloat topH = 30.0;
    CGFloat topGap = 6.0;
    CGFloat totalTopW = topW * 4.0 + topGap * 3.0;
    CGFloat topX = (bounds.size.width - totalTopW) * 0.5;
    self.pauseButton.frame       = CGRectMake(topX, safeT, topW, topH);
    self.chatButton.frame        = CGRectMake(topX + (topW + topGap) * 1.0, safeT, topW, topH);
    self.perspectiveButton.frame = CGRectMake(topX + (topW + topGap) * 2.0, safeT, topW, topH);
    self.settingsButton.frame    = CGRectMake(topX + (topW + topGap) * 3.0, safeT, topW, topH);

    // 2. Movement control (Joystick or Classic D-Pad)
    CGFloat joyD = 122.0 * scale;
    CGFloat joyX = leftHanded ? (bounds.size.width - safeR - joyD - 18.0) : (safeL + 18.0);
    CGFloat joyY = bounds.size.height - safeB - joyD - 12.0;
    if (!self.joystickView.active) {
        self.joystickView.frame = CGRectMake(joyX, joyY, joyD, joyD);
    }

    CGFloat dpadD = 148.0 * scale;
    CGFloat dpadX = leftHanded ? (bounds.size.width - safeR - dpadD - 10.0) : (safeL + 10.0);
    CGFloat dpadY = bounds.size.height - safeB - dpadD - 8.0;
    self.dpadView.frame = CGRectMake(dpadX, dpadY, dpadD, dpadD);

    // 3. Action buttons arc on the opposite side (Bedrock ergonomics)
    BOOL flying  = (self.gameState.facts_flags & HORIZON_FACT_FLYING) != 0;
    BOOL inWater = (self.gameState.facts_flags & HORIZON_FACT_IN_WATER) != 0;
    BOOL verticalPair = flying || inWater;
    BOOL crosshairMode = (s.scheme == HorizonTouchSchemeJoystickCrosshair);
    BOOL dpadMode      = (s.scheme == HorizonTouchSchemeDpadTap);

    CGFloat primaryD   = 62.0 * scale;
    CGFloat secondaryD = 52.0 * scale;
    CGFloat actionD    = 58.0 * scale;

    CGFloat sideAnchorX = leftHanded ? (safeL + 12.0) : (bounds.size.width - safeR - 12.0);

    CGFloat cornerY = bounds.size.height - safeB - primaryD - 10.0;
    CGRect jumpFrame, sneakFrame;

    if (verticalPair) {
        // Bedrock vertical pair: Up (Jump/FlyUp/SwimUp) stacked cleanly above Down (FlyDown/SwimDown)
        CGFloat x = leftHanded ? sideAnchorX : (sideAnchorX - primaryD);
        CGFloat downY = bounds.size.height - safeB - primaryD - 10.0;
        CGFloat upY   = downY - primaryD - 12.0 * scale;
        jumpFrame  = CGRectMake(x, upY, primaryD, primaryD);
        sneakFrame = CGRectMake(x, downY, primaryD, primaryD);
    } else if (dpadMode) {
        // Classic D-Pad: single Jump (or Sneak if swapped) on right; center of D-Pad is the other
        CGFloat x = leftHanded ? sideAnchorX : (sideAnchorX - primaryD);
        jumpFrame  = CGRectMake(x, cornerY - 8.0, primaryD, primaryD);
        sneakFrame = jumpFrame;
    } else {
        // Ground Bedrock arc: large Jump in lower corner, Sneak nestled slightly inward-down
        CGFloat jx = leftHanded ? sideAnchorX : (sideAnchorX - primaryD);
        CGFloat sx = leftHanded
            ? (jx + primaryD + 12.0 * scale)
            : (jx - secondaryD - 12.0 * scale);
        CGFloat sy = cornerY + (primaryD - secondaryD) * 0.65;
        jumpFrame  = CGRectMake(jx, cornerY, primaryD, primaryD);
        sneakFrame = CGRectMake(sx, sy, secondaryD, secondaryD);
        if (s.swapJumpSneak) {
            CGRect tmp = jumpFrame;
            jumpFrame = sneakFrame;
            sneakFrame = tmp;
        }
    }
    self.jumpButton.frame  = jumpFrame;
    self.sneakButton.frame = sneakFrame;

    if (crosshairMode) {
        // Bedrock Crosshair arc: Attack (inner-upper) and Interact/Place (outer-upper)
        CGFloat useX = leftHanded ? sideAnchorX : (sideAnchorX - actionD);
        CGFloat useY = verticalPair
            ? (CGRectGetMinY(jumpFrame) - actionD - 14.0 * scale)
            : (cornerY - actionD - 16.0 * scale);
        CGFloat atkX = leftHanded ? (useX + actionD + 14.0 * scale) : (useX - actionD - 14.0 * scale);
        CGFloat atkY = useY + 14.0 * scale;
        self.useButton.frame    = CGRectMake(useX, useY, actionD, actionD);
        self.attackButton.frame = CGRectMake(atkX, atkY, actionD, actionD);
    }

    // 4. Hotbar & flush `⋯` Inventory button
    [self layoutHotbarAccessory];

    // 5. Contextual action pill (centered cleanly above the hotbar in Tap-to-Interact modes)
    if (!self.contextPill.hidden) {
        CGSize pillSz = [self.contextPill intrinsicSize];
        CGFloat pillY = (self.hotbarPointsRect.size.height > 1.0)
            ? (self.hotbarPointsRect.origin.y - pillSz.height - 14.0)
            : (bounds.size.height - safeB - 76.0);
        self.contextPill.frame = CGRectMake((bounds.size.width - pillSz.width) * 0.5, pillY, pillSz.width, pillSz.height);
    }

    // 6. Inventory / Container overlay controls
    CGFloat closeD = 44.0;
    self.invCloseButton.frame = CGRectMake(bounds.size.width - safeR - closeD, safeT + 4.0, closeD, closeD);
    CGFloat invSideW = 50.0;
    CGFloat invSideH = 52.0;
    CGFloat invSideX = safeL + 4.0;
    CGFloat invMidY  = bounds.size.height * 0.5;
    self.invQuickMoveButton.frame = CGRectMake(invSideX, invMidY - invSideH - 6.0, invSideW, invSideH);
    self.invDropButton.frame      = CGRectMake(invSideX, invMidY + 6.0, invSideW, invSideH);

    // 7. Regular Menu Back button (top-left)
    self.menuBackButton.frame = CGRectMake(safeL, safeT + 4.0, 42.0, 38.0);

    // 8. Native Bedrock Top Chat Bar
    CGFloat chatH = 42.0;
    CGFloat chatX = safeL;
    CGFloat chatW = MAX(200.0, bounds.size.width - safeL - safeR);
    self.chatBar.frame = CGRectMake(chatX, safeT + 2.0, chatW, chatH);
}

- (void)layoutHotbarAccessory {
    if (!self.gameState.has_hotbar || self.gameState.hotbar_w <= 1.0 || self.screenScale <= 0.0) {
        self.hotbarPointsRect = CGRectZero;
        self.inventoryDotsButton.hidden = YES;
        return;
    }
    CGFloat invScale = 1.0 / self.screenScale;
    CGRect hb = CGRectMake(
        self.gameState.hotbar_x * invScale,
        self.gameState.hotbar_y * invScale,
        self.gameState.hotbar_w * invScale,
        self.gameState.hotbar_h * invScale
    );
    self.hotbarPointsRect = hb;
    CGFloat btnH = hb.size.height;
    CGFloat btnW = MAX(btnH, 30.0);
    self.inventoryDotsButton.frame = CGRectMake(CGRectGetMaxX(hb) + 2.0, hb.origin.y, btnW, btnH);
    self.inventoryDotsButton.hidden = (self.inputMode != HORIZON_INPUT_MODE_TOUCH);
}

#pragma mark - Mode Switching (Touch <-> Gamepad <-> KeyboardMouse)

- (void)switchToInputMode:(uint8_t)newMode {
    if (self.inputMode == newMode) {
        [self refreshPointerLockIfNeeded];
        return;
    }
    uint8_t oldMode = self.inputMode;
    self.inputMode = newMode;
    horizon_ios_set_input_mode(newMode);

    if (oldMode == HORIZON_INPUT_MODE_TOUCH && newMode != HORIZON_INPUT_MODE_TOUCH) {
        // Leaving Touch: release all active touch controls & joystick immediately so nothing sticks!
        [self cancelAllTouchControls];
    }
    if (oldMode == HORIZON_INPUT_MODE_KEYBOARD_MOUSE && newMode != HORIZON_INPUT_MODE_KEYBOARD_MOUSE) {
        [self.hwManager releaseAllHeldKeys];
    }

    [self updateHudVisibility];
    [self refreshPointerLockIfNeeded];
}

- (void)refreshPointerLockIfNeeded {
    BOOL wantLock = [self prefersPointerLocked];
    if (wantLock != self.lastPointerLockedWanted) {
        self.lastPointerLockedWanted = wantLock;
        [self setNeedsUpdateOfPrefersPointerLocked];
        [self.parentViewController setNeedsUpdateOfPrefersPointerLocked];
        [self.view.window.rootViewController setNeedsUpdateOfPrefersPointerLocked];
    }
}

- (void)updateHudVisibility {
    BOOL touchMode = (self.inputMode == HORIZON_INPUT_MODE_TOUCH);
    uint8_t kind = self.gameState.screen_kind;

    BOOL showPlay = touchMode && self.gameState.grabbing && kind == HORIZON_SCREEN_PLAYING;
    BOOL showInv  = touchMode && (kind == HORIZON_SCREEN_INVENTORY || kind == HORIZON_SCREEN_CREATIVE || kind == HORIZON_SCREEN_CONTAINER);
    BOOL showChat = self.gameState.chat_open && (self.inputMode != HORIZON_INPUT_MODE_GAMEPAD);
    BOOL showMenu = touchMode && !showPlay && !showInv && !showChat && (kind == HORIZON_SCREEN_MENU);

    self.gameplayHudView.hidden  = !showPlay;
    self.inventoryHudView.hidden = !showInv;
    self.menuHudView.hidden      = !showMenu;
    self.chatBar.hidden          = !showChat;

    if (!showInv) {
        self.invSplitBar.hidden = YES;
        BOOL hadQuickMoveMod = NO;
        for (UITouch *t in [self.activeTouches.keyEnumerator allObjects]) {
            HorizonFingerRecord *r = [self.activeTouches objectForKey:t];
            if (r != nil && r.invQuickMoveModSent) {
                r.invQuickMoveModSent = NO;
                hadQuickMoveMod = YES;
            }
        }
        if (hadQuickMoveMod || self.invQuickMoveEnabled) {
            horizon_ios_send_modifiers(0);
        }
        self.invQuickMoveEnabled = NO;
        self.invDropEnabled = NO;
        self.invQuickMoveButton.activeHighlight = NO;
        self.invDropButton.activeHighlight = NO;
    }

    if (showPlay) {
        HorizonSettings *s = HorizonSettings.shared;
        BOOL isCrosshair = (s.scheme == HorizonTouchSchemeJoystickCrosshair);
        BOOL isDpad      = (s.scheme == HorizonTouchSchemeDpadTap);
        BOOL flying      = (self.gameState.facts_flags & HORIZON_FACT_FLYING) != 0;
        BOOL inWater     = (self.gameState.facts_flags & HORIZON_FACT_IN_WATER) != 0;
        BOOL riding      = (self.gameState.facts_flags & HORIZON_FACT_RIDING) != 0;
        BOOL vehJumps    = (self.gameState.facts_flags & HORIZON_FACT_VEHICLE_JUMPS) != 0;

        self.joystickView.hidden = isDpad;
        self.dpadView.hidden     = !isDpad;

        self.attackButton.hidden = !isCrosshair;
        self.useButton.hidden    = !isCrosshair;

        // Sneak & Jump button visibility:
        // - In D-Pad ground mode, the D-Pad center carries Sneak (or Jump when swapped) and the
        //   right-side button carries the opposite control.
        // - In Joystick modes and whenever flying/swimming vertical pair is active, both buttons
        //   appear on the right side (except Jump hides while riding a non-jumping mount).
        BOOL dpadGround  = isDpad && !flying && !inWater;
        BOOL dpadSwapped = dpadGround && s.swapJumpSneak;
        self.sneakButton.hidden = dpadGround && !dpadSwapped;
        self.jumpButton.hidden  = dpadSwapped || (riding && !vehJumps && !flying);
    }
}

#pragma mark - Per-Frame DisplayLink Tick

- (void)tickFrame {
    if (self.viewIfLoaded.window == nil) return;

    // If the game window gained its rootViewController after attach, complete VC parenting
    // and pointer-lock forwarding automatically.
    if (self.parentViewController == nil && self.gameView != nil &&
        self.gameView.window.rootViewController != nil &&
        self.gameView.window.rootViewController != self) {
        [self attachToGameView:self.gameView];
    }

    // 1. Poll native Apple GCController & optional Gyro
    [self.gamepadManager tick];
    [self.hwManager tickGyro];

    // 2. Poll game state snapshot from Rust
    HorizonOverlayState st = {0};
    char chatBuf[1024];
    chatBuf[0] = '\0';
    horizon_ios_poll_state(&st, chatBuf, sizeof(chatBuf));

    BOOL stateChanged = !self.hasGameState
        || st.grabbing != self.gameState.grabbing
        || st.screen_kind != self.gameState.screen_kind
        || st.chat_open != self.gameState.chat_open
        || st.text_field_focused != self.gameState.text_field_focused
        || st.has_hotbar != self.gameState.has_hotbar
        || fabsf(st.hotbar_x - self.gameState.hotbar_x) > 0.5f
        || fabsf(st.hotbar_w - self.gameState.hotbar_w) > 0.5f
        || st.facts_flags != self.gameState.facts_flags
        || st.attack_kind != self.gameState.attack_kind
        || st.use_verb != self.gameState.use_verb
        || st.active_use != self.gameState.active_use;

    BOOL wasFlying = self.lastFlying;
    BOOL nowFlying = (st.facts_flags & HORIZON_FACT_FLYING) != 0;
    BOOL wasRiding = self.lastRiding;
    BOOL nowRiding = (st.facts_flags & HORIZON_FACT_RIDING) != 0;
    BOOL nowHoldOnlySneak = nowFlying
        || ((st.facts_flags & HORIZON_FACT_IN_WATER) != 0)
        || nowRiding;
    BOOL wasGrabbing = self.gameState.grabbing;
    self.gameState = st;
    self.hasGameState = YES;
    self.lastFlying = nowFlying;
    self.lastRiding = nowRiding;

    // CRITICAL SAFETY:
    // - Landing from flight or finishing a dismount guarantees Shift is released so the player
    //   never lands stuck crouching.
    // - Entering flight, water, or mounting a vehicle while ground toggle-sneak is active cancels
    //   the toggle immediately so it never plunges the player downward or dismounts them.
    if ((wasFlying && !nowFlying) || (wasRiding && !nowRiding) || (self.sneakToggled && nowHoldOnlySneak)) {
        [self forceReleaseSneak];
    }
    if (wasGrabbing && !st.grabbing) {
        [self cancelAllTouchControls];
    }

    if (stateChanged) {
        [self updateContextualIcons];
        [self layoutControls];
        [self updateHudVisibility];
        [self refreshPointerLockIfNeeded];
    }

    // 3. Auto-keyboard & bidirectional Chat Bar sync
    NSString *liveChatText = [NSString stringWithUTF8String:chatBuf] ?: @"";
    [self syncKeyboardAndChatWithText:liveChatText];

    // 4. Update active touch timers (Tap-to-Interact hold, Hotbar hold-drop, Inventory hold-split)
    [self tickActiveTouches];

    // 5. Update Bedrock break progress ring if holding on a block (hide while eating/bow/shield)
    if (!self.breakRingView.hidden) {
        if (st.active_use != HORIZON_ACTIVE_NONE) {
            self.breakRingView.hidden = YES;
        } else {
            self.breakRingView.progress = (CGFloat)st.mining_progress;
        }
    }

    // 6. Drain controller rumble & touch gameplay haptics
    HorizonRumbleEvent rumble = {0};
    while (horizon_ios_poll_rumble(&rumble)) {
        [self.gamepadManager playRumble:rumble];
    }
    HorizonFeedbackEvent fb = {0};
    while (horizon_ios_poll_feedback(&fb)) {
        [self playFeedbackHaptic:fb];
    }
}

- (void)updateContextualIcons {
    uint32_t f = self.gameState.facts_flags;
    BOOL flying    = (f & HORIZON_FACT_FLYING) != 0;
    BOOL inWater   = (f & HORIZON_FACT_IN_WATER) != 0;
    BOOL riding    = (f & HORIZON_FACT_RIDING) != 0;
    BOOL gliding   = (f & HORIZON_FACT_GLIDING) != 0;
    BOOL canGlide  = (f & HORIZON_FACT_CAN_GLIDE) != 0;
    BOOL sneaking  = (f & HORIZON_FACT_SNEAKING) != 0;
    BOOL sprinting = (f & HORIZON_FACT_SPRINTING) != 0;

    // Jump button icon
    if (flying) {
        self.jumpButton.iconKind = HorizonIconFlyUp;
    } else if (inWater && !riding) {
        self.jumpButton.iconKind = HorizonIconSwimUp;
    } else if (canGlide || gliding) {
        self.jumpButton.iconKind = HorizonIconElytra;
    } else {
        self.jumpButton.iconKind = HorizonIconJump;
    }

    // Sneak button icon & highlight
    if (riding) {
        self.sneakButton.iconKind = HorizonIconDismount;
        self.sneakButton.activeHighlight = NO;
    } else if (flying) {
        self.sneakButton.iconKind = HorizonIconFlyDown;
        self.sneakButton.activeHighlight = NO;
    } else if (inWater) {
        self.sneakButton.iconKind = HorizonIconSwimDown;
        self.sneakButton.activeHighlight = NO;
    } else {
        self.sneakButton.iconKind = HorizonIconSneak;
        self.sneakButton.activeHighlight = sneaking || self.sneakToggled;
    }

    // D-Pad center icon (respecting swapJumpSneak and contextual hold-only states)
    if (HorizonSettings.shared.swapJumpSneak && !flying && !inWater) {
        self.dpadView.centerIcon = HorizonIconJump;
        self.dpadView.centerHighlighted = NO;
    } else if (riding) {
        self.dpadView.centerIcon = HorizonIconDismount;
        self.dpadView.centerHighlighted = NO;
    } else if (flying) {
        self.dpadView.centerIcon = HorizonIconFlyDown;
        self.dpadView.centerHighlighted = NO;
    } else if (inWater) {
        self.dpadView.centerIcon = HorizonIconSwimDown;
        self.dpadView.centerHighlighted = NO;
    } else {
        self.dpadView.centerIcon = HorizonIconSneak;
        self.dpadView.centerHighlighted = sneaking || self.sneakToggled;
    }

    // Attack button icon (Sword on entity, Pickaxe on block/default)
    self.attackButton.iconKind = (self.gameState.attack_kind == HORIZON_ATTACK_ENTITY)
        ? HorizonIconSword
        : HorizonIconPickaxe;

    // Interact / Use button icon (dynamic from gameplay_guide::Verb)
    HorizonIconKind useIcon = [HorizonIcons iconForUseVerb:self.gameState.use_verb
                                                 activeUse:self.gameState.active_use];
    self.useButton.iconKind = useIcon;

    // Tap-to-Interact contextual pill above hotbar
    BOOL tapMode = [HorizonSettings.shared isTapToInteract];
    NSString *pillLabel = tapMode
        ? [HorizonIcons labelForUseVerb:self.gameState.use_verb activeUse:self.gameState.active_use]
        : nil;
    if (pillLabel != nil && self.gameState.grabbing && self.inputMode == HORIZON_INPUT_MODE_TOUCH) {
        [self.contextPill configureWithIcon:useIcon label:pillLabel];
        self.contextPill.hidden = NO;
    } else {
        self.contextPill.hidden = YES;
    }

    self.joystickView.sprinting = sprinting || self.sprintHeldByTouch || self.sprintLocked;
}

#pragma mark - Haptics

- (void)playLightTick {
    if (!HorizonSettings.shared.hapticsEnabled) return;
    [self.lightHaptic impactOccurredWithIntensity:0.55];
}

- (void)playMediumTick {
    if (!HorizonSettings.shared.hapticsEnabled) return;
    [self.mediumHaptic impactOccurredWithIntensity:0.80];
}

- (void)playFeedbackHaptic:(HorizonFeedbackEvent)ev {
    if (!HorizonSettings.shared.hapticsEnabled) return;
    switch (ev.kind) {
        case HORIZON_FEEDBACK_BLOCK_BROKEN:
            [self.mediumHaptic impactOccurredWithIntensity:0.70];
            break;
        case HORIZON_FEEDBACK_EXPLOSION:
            [self.heavyHaptic impactOccurredWithIntensity:fmin(fmax(ev.intensity, 0.35), 1.0)];
            break;
        case HORIZON_FEEDBACK_TOTEM:
            [self.notifHaptic notificationOccurred:UINotificationFeedbackTypeSuccess];
            break;
        case HORIZON_FEEDBACK_ITEM_STACK_SPLIT:
            [self.lightHaptic impactOccurredWithIntensity:0.70];
            break;
        default:
            break;
    }
}

#pragma mark - Auto-Keyboard & Chat Synchronization

- (void)syncKeyboardAndChatWithText:(NSString *)liveChatText {
    BOOL focused  = self.gameState.text_field_focused;
    BOOL chatOpen = self.gameState.chat_open;

    if (chatOpen) {
        if (!self.lastChatOpen || self.gameState.chat_revision != self.lastChatRevision) {
            self.lastChatRevision = self.gameState.chat_revision;
            [self.chatBar setSyncedText:liveChatText];
        }
    }

    // Transition: focus lost -> automatically dismiss keyboard & reclaim first responder
    if (self.lastTextFieldFocused && !focused) {
        self.keyboardDismissedForCurrentField = NO;
        if (self.chatBar.textField.isFirstResponder) {
            [self.chatBar.textField resignFirstResponder];
        }
        if (self.proxyTextField.isFirstResponder) {
            [self.proxyTextField resignFirstResponder];
        }
        [self becomeFirstResponder];
    }

    // Transition: focus gained -> automatically open keyboard (chat bar or proxy field)
    BOOL shouldAutoShow = focused && !self.keyboardDismissedForCurrentField &&
                          self.presentedViewController == nil &&
                          self.inputMode != HORIZON_INPUT_MODE_GAMEPAD;
    if (shouldAutoShow) {
        if (chatOpen) {
            if (!self.chatBar.textField.isFirstResponder &&
                (!self.lastChatOpen || !self.lastTextFieldFocused)) {
                [self.chatBar.textField becomeFirstResponder];
            }
        } else if (self.inputMode == HORIZON_INPUT_MODE_TOUCH) {
            if (!self.proxyTextField.isFirstResponder && !self.lastTextFieldFocused) {
                self.proxyTextField.text = @" ";
                [self.proxyTextField becomeFirstResponder];
            }
        }
    }

    self.lastTextFieldFocused = focused;
    self.lastChatOpen = chatOpen;
}

- (void)handleKeyboardWillChangeFrame:(NSNotification *)note {
    CGRect endFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect inView = [self.view convertRect:endFrame fromView:nil];
    CGRect overlap = CGRectIntersection(self.view.bounds, inView);
    CGFloat insetPt = CGRectIsNull(overlap) ? 0.0 : overlap.size.height;
    self.keyboardInsetPoints = insetPt;
    horizon_ios_set_keyboard_inset_px((float)(insetPt * self.screenScale));
}

- (void)handleKeyboardWillHide:(NSNotification *)note {
    self.keyboardInsetPoints = 0.0;
    horizon_ios_set_keyboard_inset_px(0.0f);
    if (self.gameState.text_field_focused) {
        self.keyboardDismissedForCurrentField = YES;
    }
    [self becomeFirstResponder];
}

- (void)handleAppWillResignActive:(NSNotification *)note {
    [self cancelAllTouchControls];
    [self.hwManager releaseAllHeldKeys];
}

#pragma mark - HorizonChatBarDelegate

- (void)chatBarDidChangeText:(NSString *)text {
    horizon_ios_send_chat_text(text.UTF8String);
}

- (void)chatBarDidTapSend {
    horizon_ios_send_chat_text((self.chatBar.textField.text ?: @"").UTF8String);
    horizon_ios_send_key(HORIZON_HID_ENTER, true);
    horizon_ios_send_key(HORIZON_HID_ENTER, false);
    [self.chatBar.textField resignFirstResponder];
    [self becomeFirstResponder];
}

- (void)chatBarDidTapClose {
    horizon_ios_send_key(HORIZON_HID_ESCAPE, true);
    horizon_ios_send_key(HORIZON_HID_ESCAPE, false);
    [self.chatBar.textField resignFirstResponder];
    [self becomeFirstResponder];
}

- (void)chatBarDidTapTab {
    [self playLightTick];
    horizon_ios_send_key(HORIZON_HID_TAB, true);
    horizon_ios_send_key(HORIZON_HID_TAB, false);
}

- (void)chatBarDidTapHistoryUp {
    [self playLightTick];
    horizon_ios_send_key(HORIZON_HID_UP_ARROW, true);
    horizon_ios_send_key(HORIZON_HID_UP_ARROW, false);
}

- (void)chatBarDidTapHistoryDown {
    [self playLightTick];
    horizon_ios_send_key(HORIZON_HID_DOWN_ARROW, true);
    horizon_ios_send_key(HORIZON_HID_DOWN_ARROW, false);
}

#pragma mark - Proxy UITextFieldDelegate (non-chat in-game text fields)

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    if (textField != self.proxyTextField) {
        return YES;
    }
    if (string.length == 0 && range.length > 0) {
        horizon_ios_send_key(HORIZON_HID_BACKSPACE, true);
        horizon_ios_send_key(HORIZON_HID_BACKSPACE, false);
        textField.text = @" ";
        return NO;
    }
    if ([string isEqualToString:@"\n"]) {
        horizon_ios_send_key(HORIZON_HID_ENTER, true);
        horizon_ios_send_key(HORIZON_HID_ENTER, false);
        return NO;
    }
    if (string.length > 0) {
        horizon_ios_send_text(string.UTF8String);
    }
    textField.text = @" ";
    return NO;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.proxyTextField) {
        horizon_ios_send_key(HORIZON_HID_ENTER, true);
        horizon_ios_send_key(HORIZON_HID_ENTER, false);
        [textField resignFirstResponder];
        [self becomeFirstResponder];
        return NO;
    }
    return YES;
}

#pragma mark - Hardware Delegates & UIPress

- (void)gamepadManagerDidDetectActivity:(GCController *)controller {
    [self switchToInputMode:HORIZON_INPUT_MODE_GAMEPAD];
}

- (void)hardwareInputDidActivateKeyboardMouse {
    [self switchToInputMode:HORIZON_INPUT_MODE_KEYBOARD_MOUSE];
}

- (BOOL)hardwareInputIsGrabbing {
    return self.gameState.grabbing;
}

- (BOOL)hardwareInputIsTextFieldEditing {
    return self.chatBar.textField.isFirstResponder || self.proxyTextField.isFirstResponder;
}

- (CGSize)hardwareInputViewSizePoints {
    return self.view.bounds.size;
}

- (CGFloat)hardwareInputScreenScale {
    return self.screenScale;
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (![self.hwManager handlePressesBegan:presses]) {
        [super pressesBegan:presses withEvent:event];
    }
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (![self.hwManager handlePressesEndedOrCancelled:presses]) {
        [super pressesEnded:presses withEvent:event];
    }
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (![self.hwManager handlePressesEndedOrCancelled:presses]) {
        [super pressesCancelled:presses withEvent:event];
    }
}

- (void)handlePointerHover:(UIHoverGestureRecognizer *)recognizer {
    if (self.gameState.grabbing) return;
    CGPoint pt = [recognizer locationInView:self.view];
    [self switchToInputMode:HORIZON_INPUT_MODE_KEYBOARD_MOUSE];
    self.hwManager.softwareCursorPoints = pt;
    horizon_ios_send_cursor(pt.x * self.screenScale, pt.y * self.screenScale);
}

#pragma mark - Key & Movement Helpers

- (void)sendTapKey:(uint16_t)hid {
    horizon_ios_send_key(hid, true);
    // Keep momentary gameplay taps held across at least one 50ms Minecraft tick (65ms).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(65 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        horizon_ios_send_key(hid, false);
    });
}

- (void)sendJumpDown {
    self.jumpReleaseToken++;
    self.jumpPhysicallyDown = YES;
    horizon_ios_send_key(HORIZON_HID_SPACE, true);
}

- (void)sendJumpUpWithMinHoldFrom:(CFTimeInterval)startTime {
    CFTimeInterval elapsed = CACurrentMediaTime() - startTime;
    if (elapsed >= 0.065) {
        self.jumpPhysicallyDown = NO;
        horizon_ios_send_key(HORIZON_HID_SPACE, false);
        return;
    }
    NSUInteger token = ++self.jumpReleaseToken;
    int64_t delayNs = (int64_t)((0.065 - elapsed) * (double)NSEC_PER_SEC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delayNs), dispatch_get_main_queue(), ^{
        if (self.jumpReleaseToken == token && self.jumpPhysicallyDown) {
            self.jumpPhysicallyDown = NO;
            horizon_ios_send_key(HORIZON_HID_SPACE, false);
        }
    });
}

- (void)setTouchSprint:(BOOL)on {
    if (self.sprintHeldByTouch == on) return;
    self.sprintHeldByTouch = on;
    self.joystickView.sprinting = ((self.gameState.facts_flags & HORIZON_FACT_SPRINTING) != 0)
                                || self.sprintHeldByTouch
                                || self.sprintLocked;
    horizon_ios_send_key(HORIZON_HID_LEFT_CTRL, on);
}

- (void)forceReleaseSneak {
    BOOL wasHeld = self.sneakToggled || self.sneakHeldByTouch;
    self.sneakToggled = NO;
    self.sneakHeldByTouch = NO;
    self.sneakButton.activeHighlight = NO;
    self.dpadView.centerHighlighted = NO;
    if (wasHeld) {
        horizon_ios_send_key(HORIZON_HID_LEFT_SHIFT, false);
    }
}

- (void)handleSneakPressDown:(BOOL)down {
    uint32_t f = self.gameState.facts_flags;
    BOOL holdOnly = ((f & HORIZON_FACT_FLYING) != 0)
                 || ((f & HORIZON_FACT_IN_WATER) != 0)
                 || ((f & HORIZON_FACT_RIDING) != 0);
    if (holdOnly) {
        // Flying / Swimming / Riding: ALWAYS hold-only, NEVER latch!
        BOOL shouldSend = down || self.sneakHeldByTouch || self.sneakToggled;
        self.sneakToggled = NO;
        self.sneakHeldByTouch = down;
        self.sneakButton.activeHighlight = NO;
        self.dpadView.centerHighlighted = NO;
        if (shouldSend) {
            horizon_ios_send_key(HORIZON_HID_LEFT_SHIFT, down);
        }
    } else if (down) {
        // On ground: authentic Bedrock toggle Sneak!
        self.sneakToggled = !self.sneakToggled;
        self.sneakHeldByTouch = self.sneakToggled;
        self.sneakButton.activeHighlight = self.sneakToggled;
        self.dpadView.centerHighlighted = self.sneakToggled;
        horizon_ios_send_key(HORIZON_HID_LEFT_SHIFT, self.sneakToggled);
    } else if (!self.sneakToggled && self.sneakHeldByTouch) {
        // Landed or exited water/vehicle while holding Fly Down / Swim Down / Dismount:
        // guarantee Shift is released when the finger lifts so it never sticks!
        self.sneakHeldByTouch = NO;
        self.sneakButton.activeHighlight = NO;
        self.dpadView.centerHighlighted = NO;
        horizon_ios_send_key(HORIZON_HID_LEFT_SHIFT, false);
    }
}

- (void)cancelAllTouchControls {
    for (UITouch *touch in [self.activeTouches.keyEnumerator allObjects]) {
        HorizonFingerRecord *rec = [self.activeTouches objectForKey:touch];
        if (rec != nil) {
            [self finishFinger:rec cancelled:YES];
        }
    }
    [self.activeTouches removeAllObjects];

    self.sprintLocked = NO;
    self.joystickView.active = NO;
    self.joystickView.sprintLocked = NO;
    self.joystickView.sprintLockHover = NO;
    [self.joystickView setKnobVectorX:0 y:0];
    self.dpadSprinting = NO;
    self.dpadView.upPressed = NO;
    self.dpadView.downPressed = NO;
    self.dpadView.leftPressed = NO;
    self.dpadView.rightPressed = NO;
    self.dpadView.diagLeftPressed = NO;
    self.dpadView.diagRightPressed = NO;
    self.dpadView.centerPressed = NO;

    horizon_ios_set_touch_move(false, 0.0f, 0.0f);
    [self setTouchSprint:NO];
    [self forceReleaseSneak];
    horizon_ios_send_modifiers(0);
    if (self.jumpPhysicallyDown) {
        self.jumpReleaseToken++;
        self.jumpPhysicallyDown = NO;
        horizon_ios_send_key(HORIZON_HID_SPACE, false);
    }
    self.breakRingView.hidden = YES;
    self.hotbarDropBar.hidden = YES;
    self.invSplitBar.hidden = YES;
    self.twoFingerScrolling = NO;
    [self layoutControls];
}

#pragma mark - Quick Touch Settings Sheet

- (void)presentTouchSettings {
    if (self.presentedViewController != nil) return;
    [self cancelAllTouchControls];

    HorizonTouchSettingsViewController *vc = [[HorizonTouchSettingsViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationFormSheet;
    vc.preferredContentSize = CGSizeMake(440.0, 340.0);
    __weak typeof(self) weakSelf = self;
    vc.onSettingsChanged = ^{
        [weakSelf applySettingsToViews];
    };
    vc.onDismiss = ^{
        [weakSelf becomeFirstResponder];
        [weakSelf refreshPointerLockIfNeeded];
    };
    [self presentViewController:vc animated:YES completion:nil];
    [self refreshPointerLockIfNeeded];
}

#pragma mark - Per-Finger Multitouch Engine (ZERO Gesture Recognizer Delay!)

- (BOOL)isPoint:(CGPoint)p insideView:(UIView *)v expand:(CGFloat)expand {
    if (v.hidden || v.alpha < 0.05) return NO;
    CGRect frame = CGRectInset(v.frame, -expand, -expand);
    return CGRectContainsPoint(frame, p);
}

- (int)hotbarSlotAtPoint:(CGPoint)p {
    if (CGRectIsEmpty(self.hotbarPointsRect)) return -1;
    CGRect hitRect = CGRectInset(self.hotbarPointsRect, -4.0, -6.0);
    if (!CGRectContainsPoint(hitRect, p)) return -1;
    CGFloat rel = (p.x - self.hotbarPointsRect.origin.x) / MAX(self.hotbarPointsRect.size.width, 1.0);
    int slot = (int)floor(rel * 9.0);
    if (slot < 0) slot = 0;
    if (slot > 8) slot = 8;
    return slot;
}

- (void)selectHotbarSlot:(int)slot {
    if (slot < 0 || slot > 8) return;
    [self playLightTick];
    uint16_t hid = (uint16_t)(HORIZON_HID_1 + slot);
    horizon_ios_send_key(hid, true);
    horizon_ios_send_key(hid, false);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        // Indirect pointer (iPad trackpad / mouse click) -> KeyboardMouse mode
        if (@available(iOS 13.4, *)) {
            if (touch.type == UITouchTypeIndirectPointer) {
                [self switchToInputMode:HORIZON_INPUT_MODE_KEYBOARD_MOUSE];
                CGPoint pt = [touch locationInView:self.view];
                if (!self.gameState.grabbing) {
                    self.hwManager.softwareCursorPoints = pt;
                    horizon_ios_send_cursor(pt.x * self.screenScale, pt.y * self.screenScale);
                    horizon_ios_send_mouse_button(0, true);
                }
                continue;
            }
        }

        // Direct finger touch -> immediately switch to Touch mode!
        [self switchToInputMode:HORIZON_INPUT_MODE_TOUCH];

        CGPoint pt = [touch locationInView:self.view];

        // If chat bar is open and touch lands inside it, let UIKit handle it naturally.
        if (!self.chatBar.hidden && CGRectContainsPoint(self.chatBar.frame, pt)) {
            continue;
        }

        HorizonFingerRecord *rec = [[HorizonFingerRecord alloc] init];
        rec.startPoint = pt;
        rec.currentPoint = pt;
        rec.lastPoint = pt;
        rec.startTime = CACurrentMediaTime();
        rec.hotbarSlot = -1;

        uint8_t kind = self.gameState.screen_kind;
        BOOL isPlaying = self.gameState.grabbing && kind == HORIZON_SCREEN_PLAYING;
        BOOL isInv = !isPlaying && (kind == HORIZON_SCREEN_INVENTORY || kind == HORIZON_SCREEN_CREATIVE || kind == HORIZON_SCREEN_CONTAINER);

        if (isPlaying) {
            [self assignGameplayFinger:rec atPoint:pt];
        } else if (isInv) {
            [self assignInventoryFinger:rec atPoint:pt];
        } else {
            [self assignMenuFinger:rec atPoint:pt];
        }

        [self.activeTouches setObject:rec forKey:touch];
    }

    // Detect 2-finger scrolling in menus / inventories
    if (!self.gameState.grabbing && self.activeTouches.count >= 2) {
        [self startOrUpdateTwoFingerScroll];
    }
}

- (void)assignGameplayFinger:(HorizonFingerRecord *)rec atPoint:(CGPoint)pt {
    HorizonSettings *s = HorizonSettings.shared;

    // 1. Top center mini-bar
    if ([self isPoint:pt insideView:self.pauseButton expand:5.0]) {
        rec.role = HorizonFingerRoleTopBar;
        rec.actionTag = HorizonActionTagPause;
        self.pauseButton.pressed = YES;
        [self playLightTick];
        return;
    }
    if ([self isPoint:pt insideView:self.chatButton expand:5.0]) {
        rec.role = HorizonFingerRoleTopBar;
        rec.actionTag = HorizonActionTagChat;
        self.chatButton.pressed = YES;
        [self playLightTick];
        return;
    }
    if ([self isPoint:pt insideView:self.perspectiveButton expand:5.0]) {
        rec.role = HorizonFingerRoleTopBar;
        rec.actionTag = HorizonActionTagPerspective;
        self.perspectiveButton.pressed = YES;
        [self playLightTick];
        return;
    }
    if ([self isPoint:pt insideView:self.settingsButton expand:5.0]) {
        rec.role = HorizonFingerRoleTopBar;
        rec.actionTag = HorizonActionTagSettings;
        self.settingsButton.pressed = YES;
        [self playLightTick];
        return;
    }

    // 2. Hotbar `⋯` Inventory button & Hotbar slots
    if ([self isPoint:pt insideView:self.inventoryDotsButton expand:4.0]) {
        rec.role = HorizonFingerRoleButton;
        rec.actionTag = HorizonActionTagInventory;
        self.inventoryDotsButton.pressed = YES;
        [self playLightTick];
        return;
    }
    int slot = [self hotbarSlotAtPoint:pt];
    if (slot >= 0) {
        rec.role = HorizonFingerRoleHotbar;
        rec.hotbarSlot = slot;
        rec.hotbarSlotSince = rec.startTime;
        [self selectHotbarSlot:slot];
        return;
    }

    // 3. Action buttons (Jump, Sneak, Attack, Use, Contextual Pill)
    if ([self isPoint:pt insideView:self.jumpButton expand:6.0]) {
        rec.role = HorizonFingerRoleButton;
        rec.actionTag = HorizonActionTagJump;
        self.jumpButton.pressed = YES;
        [self playLightTick];
        [self sendJumpDown];
        return;
    }
    if ([self isPoint:pt insideView:self.sneakButton expand:6.0]) {
        rec.role = HorizonFingerRoleButton;
        rec.actionTag = HorizonActionTagSneak;
        self.sneakButton.pressed = YES;
        [self playLightTick];
        [self handleSneakPressDown:YES];
        return;
    }
    if ([self isPoint:pt insideView:self.attackButton expand:6.0]) {
        rec.role = HorizonFingerRoleButton;
        rec.actionTag = HorizonActionTagAttack;
        self.attackButton.pressed = YES;
        [self playLightTick];
        horizon_ios_send_mouse_button(0, true);
        return;
    }
    if ([self isPoint:pt insideView:self.useButton expand:6.0]) {
        rec.role = HorizonFingerRoleButton;
        rec.actionTag = HorizonActionTagUse;
        self.useButton.pressed = YES;
        [self playLightTick];
        horizon_ios_send_mouse_button(1, true);
        return;
    }
    if ([self isPoint:pt insideView:self.contextPill expand:6.0]) {
        rec.role = HorizonFingerRoleButton;
        rec.actionTag = HorizonActionTagContextPill;
        self.contextPill.pressed = YES;
        [self playLightTick];
        horizon_ios_send_mouse_button(1, true);
        return;
    }

    // 4. Movement control (Joystick or D-Pad)
    if (s.scheme == HorizonTouchSchemeDpadTap) {
        if ([self isPoint:pt insideView:self.dpadView expand:10.0]) {
            rec.role = HorizonFingerRoleDpad;
            [self updateDpadFinger:rec atViewPoint:pt isInitial:YES];
            return;
        }
    } else {
        BOOL joystickFree = !self.joystickView.active;
        BOOL inFloatingZone = NO;
        if (s.floatingJoystick && joystickFree) {
            CGFloat w = self.view.bounds.size.width;
            CGFloat h = self.view.bounds.size.height;
            BOOL onMoveSide = s.leftHanded ? (pt.x >= w * 0.58) : (pt.x <= w * 0.42);
            inFloatingZone = onMoveSide && (pt.y >= h * 0.25);
        }
        BOOL inFixedJoystick = joystickFree && [self isPoint:pt insideView:self.joystickView expand:14.0];
        if (inFloatingZone || inFixedJoystick) {
            rec.role = HorizonFingerRoleJoystick;
            // Unlock any latched auto-sprint when player grabs the joystick again
            self.sprintLocked = NO;
            self.joystickView.sprintLocked = NO;
            self.joystickView.active = YES;
            if (s.floatingJoystick) {
                CGFloat d = self.joystickView.bounds.size.width;
                CGFloat minX = 10.0;
                CGFloat maxX = self.view.bounds.size.width - d - 10.0;
                CGFloat minY = 56.0;
                CGFloat maxY = self.view.bounds.size.height - d - 10.0;
                CGFloat fx = fmin(fmax(pt.x - d * 0.5, minX), maxX);
                CGFloat fy = fmin(fmax(pt.y - d * 0.5, minY), maxY);
                self.joystickView.frame = CGRectMake(fx, fy, d, d);
            }
            [self updateJoystickFinger:rec atViewPoint:pt];
            return;
        }
    }

    // 5. Free screen area -> Camera pan (and Tap-to-Interact in Tap / D-Pad schemes)
    rec.role = HorizonFingerRoleCameraOrWorld;
}

- (void)assignInventoryFinger:(HorizonFingerRecord *)rec atPoint:(CGPoint)pt {
    if ([self isPoint:pt insideView:self.invCloseButton expand:6.0]) {
        rec.role = HorizonFingerRoleButton;
        rec.actionTag = HorizonActionTagMenuClose;
        self.invCloseButton.pressed = YES;
        [self playLightTick];
        return;
    }
    if ([self isPoint:pt insideView:self.invQuickMoveButton expand:6.0]) {
        rec.role = HorizonFingerRoleButton;
        rec.actionTag = HorizonActionTagInvQuickMove;
        self.invQuickMoveButton.pressed = YES;
        [self playLightTick];
        return;
    }
    if ([self isPoint:pt insideView:self.invDropButton expand:6.0]) {
        rec.role = HorizonFingerRoleButton;
        rec.actionTag = HorizonActionTagInvDrop;
        self.invDropButton.pressed = YES;
        [self playLightTick];
        return;
    }

    rec.role = HorizonFingerRoleInventory;
    // Move cursor to the touched slot immediately!
    horizon_ios_send_cursor(pt.x * self.screenScale, pt.y * self.screenScale);

    // If Drop toggle is ON, tapping immediately drops the slot's item.
    if (self.invDropEnabled) {
        [self playLightTick];
        horizon_ios_send_key(HORIZON_HID_Q, true);
        horizon_ios_send_key(HORIZON_HID_Q, false);
        return;
    }
    // If Quick Move toggle is ON, press Shift + Left Click right away.
    if (self.invQuickMoveEnabled) {
        [self playLightTick];
        horizon_ios_send_modifiers(HORIZON_MOD_SHIFT);
        rec.invQuickMoveModSent = YES;
        horizon_ios_send_mouse_button(0, true);
        rec.invMouseDown = YES;
        return;
    }
    // If already carrying an item stack, start mouse-down right away so quick-craft dragging works!
    if (self.gameState.carrying_item) {
        horizon_ios_send_mouse_button(0, true);
        rec.invMouseDown = YES;
    }
    // Otherwise wait briefly (<= 0.28s): short tap sends Left Click on touch up; holding >= 0.28s
    // activates Bedrock green Hold-to-Split-Stack bar -> Right Click!
}

- (void)assignMenuFinger:(HorizonFingerRecord *)rec atPoint:(CGPoint)pt {
    if ([self isPoint:pt insideView:self.menuBackButton expand:6.0]) {
        rec.role = HorizonFingerRoleButton;
        rec.actionTag = HorizonActionTagMenuBack;
        self.menuBackButton.pressed = YES;
        [self playLightTick];
        return;
    }
    rec.role = HorizonFingerRoleMenu;
    // If user tapped a text field while keyboard was dismissed, allow auto-show again
    self.keyboardDismissedForCurrentField = NO;
    horizon_ios_send_cursor(pt.x * self.screenScale, pt.y * self.screenScale);
    horizon_ios_send_mouse_button(0, true);
    rec.invMouseDown = YES;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!self.gameState.grabbing && self.activeTouches.count >= 2) {
        for (UITouch *t in touches) {
            HorizonFingerRecord *rec = [self.activeTouches objectForKey:t];
            if (rec != nil) {
                rec.lastPoint = rec.currentPoint;
                rec.currentPoint = [t locationInView:self.view];
            }
        }
        [self startOrUpdateTwoFingerScroll];
        return;
    }

    for (UITouch *touch in touches) {
        if (@available(iOS 13.4, *)) {
            if (touch.type == UITouchTypeIndirectPointer) {
                CGPoint pt = [touch locationInView:self.view];
                if (!self.gameState.grabbing) {
                    self.hwManager.softwareCursorPoints = pt;
                    horizon_ios_send_cursor(pt.x * self.screenScale, pt.y * self.screenScale);
                }
                continue;
            }
        }

        HorizonFingerRecord *rec = [self.activeTouches objectForKey:touch];
        if (rec == nil) continue;
        CGPoint pt = [touch locationInView:self.view];
        CGPoint prev = rec.currentPoint;
        rec.lastPoint = prev;
        rec.currentPoint = pt;

        CGFloat movedFromStart = hypot(pt.x - rec.startPoint.x, pt.y - rec.startPoint.y);
        if (movedFromStart > 11.0) {
            rec.dragged = YES;
        }

        switch (rec.role) {
            case HorizonFingerRoleJoystick:
                [self updateJoystickFinger:rec atViewPoint:pt];
                break;

            case HorizonFingerRoleDpad:
                [self updateDpadFinger:rec atViewPoint:pt isInitial:NO];
                break;

            case HorizonFingerRoleHotbar: {
                int slot = [self hotbarSlotAtPoint:pt];
                if (slot >= 0 && slot != rec.hotbarSlot) {
                    rec.hotbarSlot = slot;
                    rec.hotbarSlotSince = CACurrentMediaTime();
                    rec.hotbarSingleDropped = NO;
                    rec.hotbarStackDropped = NO;
                    self.hotbarDropBar.hidden = YES;
                    [self selectHotbarSlot:slot];
                }
                break;
            }

            case HorizonFingerRoleCameraOrWorld: {
                if (rec.worldHoldActive) {
                    // In Tap-to-Interact hold: smoothly follow finger onto neighboring blocks!
                    CGSize sz = self.view.bounds.size;
                    float nx = (float)(pt.x / MAX(sz.width, 1.0));
                    float ny = (float)(pt.y / MAX(sz.height, 1.0));
                    horizon_ios_move_world_hold(nx, ny);
                    self.breakRingView.center = pt;
                } else {
                    // Smooth zero-latency camera pan
                    double sens = (double)HorizonSettings.shared.cameraSensitivity * (double)self.screenScale * 0.85;
                    double dx = (pt.x - prev.x) * sens;
                    double dy = (pt.y - prev.y) * sens;
                    horizon_ios_send_look(dx, dy);
                }
                break;
            }

            case HorizonFingerRoleInventory: {
                horizon_ios_send_cursor(pt.x * self.screenScale, pt.y * self.screenScale);
                if (rec.dragged && !rec.invSplitStarted && !rec.invMouseDown && !self.invDropEnabled) {
                    // Finger dragged out of the slot -> turn into regular pointer drag
                    horizon_ios_send_mouse_button(0, true);
                    rec.invMouseDown = YES;
                }
                if (rec.invSplitStarted && movedFromStart > 22.0) {
                    // Moved far off slot -> cancel split bar
                    rec.invSplitStarted = NO;
                    self.invSplitBar.hidden = YES;
                }
                break;
            }

            case HorizonFingerRoleMenu: {
                horizon_ios_send_cursor(pt.x * self.screenScale, pt.y * self.screenScale);
                break;
            }

            default:
                break;
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self handleTouchesFinished:touches cancelled:NO];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self handleTouchesFinished:touches cancelled:YES];
}

- (void)handleTouchesFinished:(NSSet<UITouch *> *)touches cancelled:(BOOL)cancelled {
    for (UITouch *touch in touches) {
        if (@available(iOS 13.4, *)) {
            if (touch.type == UITouchTypeIndirectPointer) {
                if (!self.gameState.grabbing) {
                    horizon_ios_send_mouse_button(0, false);
                }
                continue;
            }
        }

        HorizonFingerRecord *rec = [self.activeTouches objectForKey:touch];
        if (rec != nil) {
            rec.currentPoint = [touch locationInView:self.view];
            [self finishFinger:rec cancelled:cancelled];
            [self.activeTouches removeObjectForKey:touch];
        }
    }
    if (self.activeTouches.count < 2) {
        self.twoFingerScrolling = NO;
    }
}

- (void)finishFinger:(HorizonFingerRecord *)rec cancelled:(BOOL)cancelled {
    switch (rec.role) {
        case HorizonFingerRoleTopBar:
            self.pauseButton.pressed = NO;
            self.chatButton.pressed = NO;
            self.perspectiveButton.pressed = NO;
            self.settingsButton.pressed = NO;
            if (!cancelled) {
                switch (rec.actionTag) {
                    case HorizonActionTagPause:       [self sendTapKey:HORIZON_HID_ESCAPE]; break;
                    case HorizonActionTagChat:        [self sendTapKey:HORIZON_HID_T]; break;
                    case HorizonActionTagPerspective: [self sendTapKey:HORIZON_HID_F5]; break;
                    case HorizonActionTagSettings:    [self presentTouchSettings]; break;
                    default: break;
                }
            }
            break;

        case HorizonFingerRoleButton:
            switch (rec.actionTag) {
                case HorizonActionTagJump:
                    self.jumpButton.pressed = NO;
                    [self sendJumpUpWithMinHoldFrom:rec.startTime];
                    break;
                case HorizonActionTagSneak:
                    self.sneakButton.pressed = NO;
                    [self handleSneakPressDown:NO];
                    break;
                case HorizonActionTagAttack:
                    self.attackButton.pressed = NO;
                    horizon_ios_send_mouse_button(0, false);
                    break;
                case HorizonActionTagUse:
                    self.useButton.pressed = NO;
                    horizon_ios_send_mouse_button(1, false);
                    break;
                case HorizonActionTagContextPill:
                    self.contextPill.pressed = NO;
                    horizon_ios_send_mouse_button(1, false);
                    break;
                case HorizonActionTagInventory:
                    self.inventoryDotsButton.pressed = NO;
                    if (!cancelled) {
                        [self sendTapKey:HORIZON_HID_E];
                    }
                    break;
                case HorizonActionTagMenuClose:
                    self.invCloseButton.pressed = NO;
                    if (!cancelled) {
                        horizon_ios_send_key(HORIZON_HID_ESCAPE, true);
                        horizon_ios_send_key(HORIZON_HID_ESCAPE, false);
                    }
                    break;
                case HorizonActionTagMenuBack:
                    self.menuBackButton.pressed = NO;
                    if (!cancelled) {
                        horizon_ios_send_key(HORIZON_HID_ESCAPE, true);
                        horizon_ios_send_key(HORIZON_HID_ESCAPE, false);
                    }
                    break;
                case HorizonActionTagInvQuickMove:
                    self.invQuickMoveButton.pressed = NO;
                    if (!cancelled) {
                        self.invQuickMoveEnabled = !self.invQuickMoveEnabled;
                        if (self.invQuickMoveEnabled) self.invDropEnabled = NO;
                        self.invQuickMoveButton.activeHighlight = self.invQuickMoveEnabled;
                        self.invDropButton.activeHighlight = self.invDropEnabled;
                    }
                    break;
                case HorizonActionTagInvDrop:
                    self.invDropButton.pressed = NO;
                    if (!cancelled) {
                        self.invDropEnabled = !self.invDropEnabled;
                        if (self.invDropEnabled) self.invQuickMoveEnabled = NO;
                        self.invQuickMoveButton.activeHighlight = self.invQuickMoveEnabled;
                        self.invDropButton.activeHighlight = self.invDropEnabled;
                    }
                    break;
                default:
                    break;
            }
            break;

        case HorizonFingerRoleJoystick: {
            BOOL latchLock = !cancelled && self.joystickView.sprintLockHover;
            self.joystickView.active = NO;
            self.joystickView.sprintLockHover = NO;
            if (latchLock) {
                self.sprintLocked = YES;
                self.joystickView.sprintLocked = YES;
                [self.joystickView setKnobVectorX:0.0 y:1.0];
                horizon_ios_set_touch_move(true, 0.0f, 1.0f);
                [self setTouchSprint:YES];
                [self playMediumTick];
            } else {
                self.sprintLocked = NO;
                self.joystickView.sprintLocked = NO;
                [self.joystickView setKnobVectorX:0.0 y:0.0];
                horizon_ios_set_touch_move(false, 0.0f, 0.0f);
                [self setTouchSprint:NO];
            }
            [self layoutControls];
            break;
        }

        case HorizonFingerRoleDpad: {
            if (rec.dpadMask & (1u << 4)) {
                if (rec.dpadCenterIsJump) {
                    [self sendJumpUpWithMinHoldFrom:rec.startTime];
                } else {
                    [self handleSneakPressDown:NO];
                }
                rec.dpadCenterIsJump = NO;
            }
            self.dpadView.upPressed = NO;
            self.dpadView.downPressed = NO;
            self.dpadView.leftPressed = NO;
            self.dpadView.rightPressed = NO;
            self.dpadView.diagLeftPressed = NO;
            self.dpadView.diagRightPressed = NO;
            self.dpadView.centerPressed = NO;
            self.dpadSprinting = NO;
            [self setTouchSprint:NO];
            horizon_ios_set_touch_move(false, 0.0f, 0.0f);
            break;
        }

        case HorizonFingerRoleHotbar:
            self.hotbarDropBar.hidden = YES;
            break;

        case HorizonFingerRoleCameraOrWorld: {
            if (rec.worldHoldActive) {
                rec.worldHoldActive = NO;
                self.breakRingView.hidden = YES;
                horizon_ios_hold_world(0.5f, 0.5f, false);
            } else if (!cancelled && !rec.dragged && [HorizonSettings.shared isTapToInteract]) {
                // Short Tap-to-Interact! Cast screen-space ray through exact tapped point.
                CFTimeInterval dt = CACurrentMediaTime() - rec.startTime;
                if (dt < 0.28) {
                    CGSize sz = self.view.bounds.size;
                    float nx = (float)(rec.currentPoint.x / MAX(sz.width, 1.0));
                    float ny = (float)(rec.currentPoint.y / MAX(sz.height, 1.0));
                    [self playLightTick];
                    horizon_ios_tap_world(nx, ny);
                }
            }
            break;
        }

        case HorizonFingerRoleInventory: {
            self.invSplitBar.hidden = YES;
            if (rec.invMouseDown) {
                horizon_ios_send_mouse_button(0, false);
                rec.invMouseDown = NO;
            } else if (!cancelled && !rec.invSplitTriggered && !self.invDropEnabled) {
                if (rec.invSplitStarted) {
                    // Released during green bar -> perform Bedrock split stack (Right Click)!
                    [self triggerInventorySplitAt:rec.startPoint];
                } else if (!rec.dragged) {
                    // Short tap on slot -> crisp Left Click!
                    horizon_ios_send_cursor(rec.currentPoint.x * self.screenScale, rec.currentPoint.y * self.screenScale);
                    horizon_ios_send_mouse_button(0, true);
                    horizon_ios_send_mouse_button(0, false);
                }
            }
            if (rec.invQuickMoveModSent) {
                rec.invQuickMoveModSent = NO;
                horizon_ios_send_modifiers(0);
            }
            break;
        }

        case HorizonFingerRoleMenu: {
            if (rec.invMouseDown) {
                horizon_ios_send_mouse_button(0, false);
                rec.invMouseDown = NO;
            }
            break;
        }

        default:
            break;
    }
}

#pragma mark - Joystick, D-Pad & Timed Touch Loops

- (void)updateJoystickFinger:(HorizonFingerRecord *)rec atViewPoint:(CGPoint)pt {
    CGPoint center = self.joystickView.center;
    CGFloat radius = MAX(self.joystickView.bounds.size.width * 0.42, 24.0);
    CGFloat rawX = (pt.x - center.x) / radius;   // +x right
    CGFloat rawY = (center.y - pt.y) / radius;   // +y forward (up)
    CGFloat dist = hypot(rawX, rawY);

    [self.joystickView setKnobVectorX:rawX y:rawY];

    // Check Sprint Lock hover zone above the joystick ring
    CGPoint lockCenter = [self.joystickView sprintLockCenterInSuperview];
    BOOL overLock = (rawY > 0.85 && (dist > 1.15 || hypot(pt.x - lockCenter.x, pt.y - lockCenter.y) < 30.0));
    self.joystickView.sprintLockHover = overLock;

    if (dist < 0.14) {
        horizon_ios_set_touch_move(false, 0.0f, 0.0f);
        [self setTouchSprint:NO];
        return;
    }

    // Rescale outside deadzone 0.14..1.0 smoothly to 0..1
    CGFloat mag = fmin((dist - 0.14) / 0.86, 1.0);
    CGFloat nx = (rawX / dist) * mag;
    CGFloat ny = (rawY / dist) * mag;

    // Horizon's `input_move()` expects `[left, forward]` (left positive = -nx, forward positive = ny).
    horizon_ios_set_touch_move(true, (float)(-nx), (float)ny);

    // Auto-sprint when pushed > 85% forward within ~38° cone
    BOOL autoSprint = (mag > 0.85 && ny > 0.65 && fabs(nx) < 0.62);
    [self setTouchSprint:autoSprint];
}

- (void)updateDpadFinger:(HorizonFingerRecord *)rec atViewPoint:(CGPoint)pt isInitial:(BOOL)isInitial {
    CGPoint local = [self.view convertPoint:pt toView:self.dpadView];
    uint8_t mask = [self.dpadView hitMaskForPoint:local];
    uint8_t prev = rec.dpadMask;

    // Center button handling (Sneak or Jump if swapped). Remember which action was pressed
    // so flying/water transitions mid-hold always release the exact key that went down.
    BOOL prevCenter = (prev & (1u << 4)) != 0;
    BOOL nowCenter  = (mask & (1u << 4)) != 0;
    if (nowCenter != prevCenter) {
        self.dpadView.centerPressed = nowCenter;
        if (nowCenter) {
            BOOL centerIsJump = HorizonSettings.shared.swapJumpSneak &&
                !(self.gameState.facts_flags & (HORIZON_FACT_FLYING | HORIZON_FACT_IN_WATER));
            rec.dpadCenterIsJump = centerIsJump;
            [self playLightTick];
            if (centerIsJump) {
                [self sendJumpDown];
            } else {
                [self handleSneakPressDown:YES];
            }
        } else {
            if (rec.dpadCenterIsJump) {
                [self sendJumpUpWithMinHoldFrom:rec.startTime];
            } else {
                [self handleSneakPressDown:NO];
            }
            rec.dpadCenterIsJump = NO;
        }
    }

    BOOL up    = (mask & (1u << 0)) != 0;
    BOOL down  = (mask & (1u << 1)) != 0;
    BOOL left  = (mask & (1u << 2)) != 0;
    BOOL right = (mask & (1u << 3)) != 0;

    // Double-tap Forward on D-Pad activates Sprint (Bedrock classic!)
    if (isInitial && up && !left && !right) {
        CFTimeInterval now = CACurrentMediaTime();
        if (now - self.lastDpadForwardTapTime < 0.32) {
            self.dpadSprinting = YES;
        }
        self.lastDpadForwardTapTime = now;
    }
    if (!up) {
        self.dpadSprinting = NO;
    }
    [self setTouchSprint:self.dpadSprinting];

    self.dpadView.upPressed        = up && !left && !right;
    self.dpadView.downPressed      = down;
    self.dpadView.leftPressed      = left && !up;
    self.dpadView.rightPressed     = right && !up;
    self.dpadView.diagLeftPressed  = up && left;
    self.dpadView.diagRightPressed = up && right;
    rec.dpadMask = mask;

    float fwd = (up ? 1.0f : 0.0f) - (down ? 1.0f : 0.0f);
    float lft = (left ? 1.0f : 0.0f) - (right ? 1.0f : 0.0f);
    if (fwd != 0.0f || lft != 0.0f) {
        float len = hypotf(lft, fwd);
        horizon_ios_set_touch_move(true, lft / len, fwd / len);
    } else {
        horizon_ios_set_touch_move(false, 0.0f, 0.0f);
    }
}

- (void)startOrUpdateTwoFingerScroll {
    NSArray<UITouch *> *all = [self.activeTouches.keyEnumerator allObjects];
    if (all.count < 2) return;
    HorizonFingerRecord *a = [self.activeTouches objectForKey:all[0]];
    HorizonFingerRecord *b = [self.activeTouches objectForKey:all[1]];
    if (a == nil || b == nil) return;

    // Release any pending single-finger press (and explicit Quick Move Shift) before scrolling
    for (HorizonFingerRecord *r in @[a, b]) {
        if (r.invMouseDown) {
            horizon_ios_send_mouse_button(0, false);
            r.invMouseDown = NO;
        }
        if (r.invQuickMoveModSent) {
            r.invQuickMoveModSent = NO;
            horizon_ios_send_modifiers(0);
        }
        r.invSplitStarted = NO;
        r.dragged = YES;
    }
    self.invSplitBar.hidden = YES;

    CGPoint mid = CGPointMake((a.currentPoint.x + b.currentPoint.x) * 0.5,
                              (a.currentPoint.y + b.currentPoint.y) * 0.5);
    if (!self.twoFingerScrolling) {
        self.twoFingerScrolling = YES;
        self.lastTwoFingerMidpoint = mid;
        return;
    }
    CGFloat dy = mid.y - self.lastTwoFingerMidpoint.y;
    CGFloat dx = mid.x - self.lastTwoFingerMidpoint.x;
    if (fabs(dy) > 3.0 || fabs(dx) > 3.0) {
        self.lastTwoFingerMidpoint = mid;
        horizon_ios_send_scroll((float)(dx / 24.0), (float)(dy / 24.0));
    }
}

- (void)triggerInventorySplitAt:(CGPoint)pt {
    [self playMediumTick];
    horizon_ios_send_cursor(pt.x * self.screenScale, pt.y * self.screenScale);
    horizon_ios_send_mouse_button(1, true);
    horizon_ios_send_mouse_button(1, false);
}

- (void)tickActiveTouches {
    CFTimeInterval now = CACurrentMediaTime();
    BOOL tapMode = [HorizonSettings.shared isTapToInteract];

    for (UITouch *touch in [self.activeTouches.keyEnumerator allObjects]) {
        HorizonFingerRecord *rec = [self.activeTouches objectForKey:touch];
        if (rec == nil) continue;
        CFTimeInterval held = now - rec.startTime;

        // 1. Tap-to-Interact world hold (mine block with Bedrock ring, or hold-use consumable/bow)
        if (rec.role == HorizonFingerRoleCameraOrWorld && tapMode && !rec.dragged && !rec.worldHoldActive) {
            if (held >= 0.22) {
                rec.worldHoldActive = YES;
                CGSize sz = self.view.bounds.size;
                float nx = (float)(rec.currentPoint.x / MAX(sz.width, 1.0));
                float ny = (float)(rec.currentPoint.y / MAX(sz.height, 1.0));
                horizon_ios_hold_world(nx, ny, true);
                self.breakRingView.center = rec.currentPoint;
                self.breakRingView.progress = 0.0;
                self.breakRingView.hidden = NO;
            }
        }

        // 2. Hotbar hold-to-drop with Bedrock green progress bar (~0.45s -> drop 1; ~0.85s -> drop stack!)
        if (rec.role == HorizonFingerRoleHotbar && rec.hotbarSlot >= 0 && !CGRectIsEmpty(self.hotbarPointsRect)) {
            CFTimeInterval slotHeld = now - rec.hotbarSlotSince;
            if (slotHeld >= 0.14) {
                CGFloat slotW = self.hotbarPointsRect.size.width / 9.0;
                CGFloat sx = self.hotbarPointsRect.origin.x + slotW * (CGFloat)rec.hotbarSlot;
                self.hotbarDropBar.frame = CGRectMake(sx + 2.0, self.hotbarPointsRect.origin.y - 9.0, MAX(slotW - 4.0, 20.0), 6.0);
                self.hotbarDropBar.hidden = NO;
                self.hotbarDropBar.progress = fmin((slotHeld - 0.14) / 0.31, 1.0);

                if (slotHeld >= 0.45 && !rec.hotbarSingleDropped) {
                    rec.hotbarSingleDropped = YES;
                    rec.hotbarLastRepeatDrop = now;
                    [self playMediumTick];
                    horizon_ios_send_key(HORIZON_HID_Q, true);
                    horizon_ios_send_key(HORIZON_HID_Q, false);
                } else if (slotHeld >= 0.85 && !rec.hotbarStackDropped) {
                    rec.hotbarStackDropped = YES;
                    rec.hotbarLastRepeatDrop = now;
                    [self playMediumTick];
                    horizon_ios_send_modifiers(HORIZON_MOD_CTRL);
                    horizon_ios_send_key(HORIZON_HID_Q, true);
                    horizon_ios_send_key(HORIZON_HID_Q, false);
                    horizon_ios_send_modifiers(0);
                } else if (rec.hotbarStackDropped && (now - rec.hotbarLastRepeatDrop) >= 0.25) {
                    rec.hotbarLastRepeatDrop = now;
                    horizon_ios_send_key(HORIZON_HID_Q, true);
                    horizon_ios_send_key(HORIZON_HID_Q, false);
                }
            }
        }

        // 3. Inventory Bedrock Hold-to-Split-Stack green progress bar
        if (rec.role == HorizonFingerRoleInventory && !rec.dragged && !rec.invMouseDown &&
            !rec.invSplitTriggered && !self.invDropEnabled && !self.invQuickMoveEnabled) {
            if (held >= 0.26) {
                rec.invSplitStarted = YES;
                CGFloat barW = 44.0;
                CGFloat barH = 7.0;
                CGFloat bx = fmin(fmax(rec.startPoint.x - barW * 0.5, 8.0), self.view.bounds.size.width - barW - 8.0);
                CGFloat by = fmax(rec.startPoint.y - 34.0, 10.0);
                self.invSplitBar.frame = CGRectMake(bx, by, barW, barH);
                self.invSplitBar.hidden = NO;
                CGFloat p = fmin((held - 0.26) / 0.34, 1.0);
                self.invSplitBar.progress = p;
                if (p >= 1.0) {
                    rec.invSplitTriggered = YES;
                    self.invSplitBar.hidden = YES;
                    [self triggerInventorySplitAt:rec.startPoint];
                }
            }
        }
    }
}

@end

#pragma mark - C entry point called from Rust `host.rs`

void horizon_ios_attach_overlay(void *ui_view) {
    UIView *gameView = (__bridge UIView *)ui_view;
    if (gameView == nil) return;

    dispatch_block_t attachBlock = ^{
        horizon_ios_start_watchdog();
        HorizonOverlayViewController *overlay = sCurrentOverlay;
        if (overlay == nil) {
            overlay = [[HorizonOverlayViewController alloc] init];
            sCurrentOverlay = overlay;
        }
        [overlay attachToGameView:gameView];
        horizon_ios_dismiss_prelauncher_window();
    };

    if (NSThread.isMainThread) {
        attachBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), attachBlock);
    }
}
