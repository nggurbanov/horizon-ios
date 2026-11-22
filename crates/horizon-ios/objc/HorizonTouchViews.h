// horizon-ios: native UIKit Bedrock HUD views (buttons, joystick, D-pad, break ring,
// green hold-progress bar, hotbar overlay, top chat bar, inventory controls).
#pragma once

#import <UIKit/UIKit.h>
#import "HorizonIcons.h"

NS_ASSUME_NONNULL_BEGIN

/// Translucent Bedrock-styled HUD button (driven by our per-finger multitouch dispatcher).
@interface HorizonBedrockButton : UIView
@property (nonatomic, assign) HorizonIconKind iconKind;
@property (nonatomic, assign) BOOL circular;
@property (nonatomic, assign) BOOL pressed;
@property (nonatomic, assign) BOOL activeHighlight;
@property (nonatomic, assign) CGFloat hudOpacity;
@property (nonatomic, copy, nullable) NSString *caption;
- (instancetype)initWithIcon:(HorizonIconKind)kind circular:(BOOL)circular;
@end

/// Bedrock floating contextual pill button above the hotbar in Tap-to-Interact schemes.
@interface HorizonContextPillView : UIView
@property (nonatomic, assign) BOOL pressed;
@property (nonatomic, assign) CGFloat hudOpacity;
- (void)configureWithIcon:(HorizonIconKind)kind label:(NSString *)label;
- (CGSize)intrinsicSize;
@end

/// Bedrock 360-degree analog joystick with sprint highlight and floating auto-sprint lock.
@interface HorizonJoystickView : UIView
@property (nonatomic, assign) CGFloat hudOpacity;
@property (nonatomic, assign) BOOL floatingMode;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) BOOL sprinting;
@property (nonatomic, assign) BOOL sprintLocked;
@property (nonatomic, assign) BOOL sprintLockHover;
/// Normalized knob vector `[x, y]` with +x right, +y up, length up to 1.25 for lock pull.
- (void)setKnobVectorX:(CGFloat)x y:(CGFloat)y;
- (CGPoint)sprintLockCenterInSuperview;
@end

/// Classic Minecraft Pocket/Bedrock cross D-Pad with dynamic diagonals and center Sneak/Jump.
@interface HorizonDpadView : UIView
@property (nonatomic, assign) CGFloat hudOpacity;
@property (nonatomic, assign) BOOL upPressed;
@property (nonatomic, assign) BOOL downPressed;
@property (nonatomic, assign) BOOL leftPressed;
@property (nonatomic, assign) BOOL rightPressed;
@property (nonatomic, assign) BOOL diagLeftPressed;
@property (nonatomic, assign) BOOL diagRightPressed;
@property (nonatomic, assign) BOOL centerPressed;
@property (nonatomic, assign) BOOL centerHighlighted;
@property (nonatomic, assign) HorizonIconKind centerIcon;
/// Returns bitmask of active direction(s): bit0=up, bit1=down, bit2=left, bit3=right, bit4=center.
- (uint8_t)hitMaskForPoint:(CGPoint)localPoint;
@end

/// Signature Bedrock expanding circular break-progress indicator drawn around the finger.
@interface HorizonBreakRingView : UIView
@property (nonatomic, assign) CGFloat progress; // 0.0 .. 1.0
@end

/// Signature Bedrock green hold-progress bar (hotbar drop & inventory hold-to-split-stack).
@interface HorizonGreenProgressBar : UIView
@property (nonatomic, assign) CGFloat progress; // 0.0 .. 1.0
@end

/// Native Bedrock top chat input bar (`✕`, `UITextField`, `Tab`, `↑`, `↓`, `Send`).
@protocol HorizonChatBarDelegate <NSObject>
- (void)chatBarDidChangeText:(NSString *)text;
- (void)chatBarDidTapSend;
- (void)chatBarDidTapClose;
- (void)chatBarDidTapTab;
- (void)chatBarDidTapHistoryUp;
- (void)chatBarDidTapHistoryDown;
@end

@interface HorizonChatBarView : UIView
@property (nonatomic, weak, nullable) id<HorizonChatBarDelegate> delegate;
@property (nonatomic, strong, readonly) UITextField *textField;
- (void)setSyncedText:(NSString *)text;
@end

NS_ASSUME_NONNULL_END
