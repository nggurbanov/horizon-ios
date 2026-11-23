// horizon-ios: native UIKit Bedrock HUD views.
#import "HorizonTouchViews.h"
#import "HorizonL10n.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

static UIColor *bedrockFillColor(BOOL pressed, BOOL active, CGFloat opacity) {
    CGFloat alpha = fmin(fmax(opacity, 0.20), 1.0);
    if (pressed) {
        return [UIColor colorWithRed:1.0 green:1.0 blue:1.0 alpha:fmin(0.42 * alpha + 0.14, 0.60)];
    }
    if (active) {
        return [UIColor colorWithRed:0.18 green:0.78 blue:0.42 alpha:0.55 * alpha + 0.16];
    }
    return [UIColor colorWithRed:0.08 green:0.10 blue:0.13 alpha:0.56 * alpha];
}

static UIColor *bedrockBorderColor(BOOL pressed, BOOL active, CGFloat opacity) {
    CGFloat alpha = fmin(fmax(opacity, 0.20), 1.0);
    if (active) {
        return [UIColor colorWithRed:0.48 green:0.98 blue:0.64 alpha:fmin(0.95, alpha + 0.20)];
    }
    if (pressed) {
        return [UIColor colorWithWhite:1.0 alpha:fmin(0.95, alpha + 0.25)];
    }
    return [UIColor colorWithWhite:1.0 alpha:0.48 * alpha + 0.12];
}

#pragma mark - HorizonBedrockButton

@interface HorizonBedrockButton ()
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *captionLabel;
@end

@implementation HorizonBedrockButton

- (instancetype)initWithIcon:(HorizonIconKind)kind circular:(BOOL)circular {
    self = [super initWithFrame:CGRectZero];
    if (self != nil) {
        _iconKind = kind;
        _circular = circular;
        _hudOpacity = 0.72;
        self.userInteractionEnabled = NO;
        self.layer.borderWidth = 1.5;

        _iconView = [[UIImageView alloc] init];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.tintColor = UIColor.whiteColor;
        [self addSubview:_iconView];

        _captionLabel = [[UILabel alloc] init];
        _captionLabel.font = [UIFont systemFontOfSize:9.5 weight:UIFontWeightSemibold];
        _captionLabel.textColor = UIColor.whiteColor;
        _captionLabel.textAlignment = NSTextAlignmentCenter;
        _captionLabel.hidden = YES;
        [self addSubview:_captionLabel];

        [self refreshAppearance];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    self.layer.cornerRadius = self.circular ? MIN(b.size.width, b.size.height) * 0.5 : 10.0;
    BOOL hasCaption = self.caption.length > 0;
    self.captionLabel.hidden = !hasCaption;
    if (hasCaption) {
        CGFloat iconSide = MIN(b.size.width, b.size.height) * 0.48;
        self.iconView.frame = CGRectMake((b.size.width - iconSide) * 0.5,
                                         b.size.height * 0.14,
                                         iconSide, iconSide);
        self.captionLabel.frame = CGRectMake(2.0, b.size.height * 0.64, b.size.width - 4.0, b.size.height * 0.30);
    } else {
        CGFloat iconSide = MIN(b.size.width, b.size.height) * 0.56;
        self.iconView.frame = CGRectMake((b.size.width - iconSide) * 0.5,
                                         (b.size.height - iconSide) * 0.5,
                                         iconSide, iconSide);
    }
    CGFloat pt = MAX(14.0, self.iconView.bounds.size.width);
    self.iconView.image = [HorizonIcons iconForKind:self.iconKind pointSize:pt];
}

- (void)setIconKind:(HorizonIconKind)iconKind {
    if (_iconKind == iconKind) return;
    _iconKind = iconKind;
    CGFloat pt = MAX(14.0, self.iconView.bounds.size.width);
    self.iconView.image = [HorizonIcons iconForKind:iconKind pointSize:pt];
}

- (void)setCaption:(NSString *)caption {
    if ((_caption == nil && caption == nil) || [_caption isEqualToString:caption]) return;
    _caption = [caption copy];
    self.captionLabel.text = caption;
    [self setNeedsLayout];
}

- (void)setPressed:(BOOL)pressed {
    if (_pressed == pressed) return;
    _pressed = pressed;
    [self refreshAppearance];
    self.transform = pressed ? CGAffineTransformMakeScale(0.92, 0.92) : CGAffineTransformIdentity;
}

- (void)setActiveHighlight:(BOOL)activeHighlight {
    if (_activeHighlight == activeHighlight) return;
    _activeHighlight = activeHighlight;
    [self refreshAppearance];
}

- (void)setHudOpacity:(CGFloat)hudOpacity {
    _hudOpacity = hudOpacity;
    [self refreshAppearance];
}

- (void)refreshAppearance {
    self.backgroundColor = bedrockFillColor(self.pressed, self.activeHighlight, self.hudOpacity);
    self.layer.borderColor = bedrockBorderColor(self.pressed, self.activeHighlight, self.hudOpacity).CGColor;
    CGFloat iconAlpha = fmin(1.0, self.hudOpacity + 0.22);
    self.iconView.alpha = (self.pressed || self.activeHighlight) ? 1.0 : iconAlpha;
    self.captionLabel.alpha = self.iconView.alpha;
}

@end

#pragma mark - HorizonContextPillView

@interface HorizonContextPillView ()
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, assign) HorizonIconKind currentKind;
@end

@implementation HorizonContextPillView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        _hudOpacity = 0.78;
        self.userInteractionEnabled = NO;
        self.layer.cornerRadius = 16.0;
        self.layer.borderWidth = 1.5;

        _iconView = [[UIImageView alloc] init];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.tintColor = UIColor.whiteColor;
        [self addSubview:_iconView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        _titleLabel.textColor = UIColor.whiteColor;
        [self addSubview:_titleLabel];

        [self refreshAppearance];
    }
    return self;
}

- (void)configureWithIcon:(HorizonIconKind)kind label:(NSString *)label {
    self.currentKind = kind;
    self.iconView.image = [HorizonIcons iconForKind:kind pointSize:18.0];
    self.titleLabel.text = label;
    [self setNeedsLayout];
}

- (CGSize)intrinsicSize {
    CGSize textSz = [self.titleLabel sizeThatFits:CGSizeMake(160.0, 24.0)];
    return CGSizeMake(ceil(12.0 + 18.0 + 6.0 + textSz.width + 14.0), 34.0);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    self.layer.cornerRadius = b.size.height * 0.5;
    self.iconView.frame = CGRectMake(12.0, (b.size.height - 18.0) * 0.5, 18.0, 18.0);
    self.titleLabel.frame = CGRectMake(36.0, 0.0, MAX(0.0, b.size.width - 46.0), b.size.height);
}

- (void)setPressed:(BOOL)pressed {
    if (_pressed == pressed) return;
    _pressed = pressed;
    [self refreshAppearance];
    self.transform = pressed ? CGAffineTransformMakeScale(0.94, 0.94) : CGAffineTransformIdentity;
}

- (void)setHudOpacity:(CGFloat)hudOpacity {
    _hudOpacity = hudOpacity;
    [self refreshAppearance];
}

- (void)refreshAppearance {
    self.backgroundColor = bedrockFillColor(self.pressed, NO, fmax(self.hudOpacity, 0.65));
    self.layer.borderColor = bedrockBorderColor(self.pressed, NO, fmax(self.hudOpacity, 0.65)).CGColor;
}

@end

#pragma mark - HorizonJoystickView

@interface HorizonJoystickView ()
@property (nonatomic, strong) UIView *outerRing;
@property (nonatomic, strong) UIView *sprintHalo;
@property (nonatomic, strong) UIView *knobView;
@property (nonatomic, strong) UIView *lockBadge;
@property (nonatomic, strong) UIImageView *lockIconView;
@property (nonatomic, assign) CGFloat knobX;
@property (nonatomic, assign) CGFloat knobY;
@end

@implementation HorizonJoystickView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        _hudOpacity = 0.72;
        self.userInteractionEnabled = NO;
        self.clipsToBounds = NO;

        _outerRing = [[UIView alloc] init];
        _outerRing.layer.borderWidth = 2.0;
        [self addSubview:_outerRing];

        _sprintHalo = [[UIView alloc] init];
        _sprintHalo.layer.borderWidth = 2.5;
        _sprintHalo.layer.borderColor = [UIColor colorWithRed:0.35 green:0.96 blue:0.56 alpha:0.90].CGColor;
        _sprintHalo.backgroundColor = UIColor.clearColor;
        _sprintHalo.hidden = YES;
        [self addSubview:_sprintHalo];

        _knobView = [[UIView alloc] init];
        _knobView.layer.borderWidth = 1.5;
        [self addSubview:_knobView];

        _lockBadge = [[UIView alloc] init];
        _lockBadge.layer.borderWidth = 1.5;
        _lockBadge.hidden = YES;
        [self addSubview:_lockBadge];

        _lockIconView = [[UIImageView alloc] init];
        _lockIconView.contentMode = UIViewContentModeScaleAspectFit;
        _lockIconView.tintColor = UIColor.whiteColor;
        _lockIconView.image = [HorizonIcons iconForKind:HorizonIconSprintLock pointSize:16.0];
        [_lockBadge addSubview:_lockIconView];

        [self refreshAppearance];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat d = MIN(b.size.width, b.size.height);
    CGFloat r = d * 0.5;
    CGPoint c = CGPointMake(b.size.width * 0.5, b.size.height * 0.5);

    self.outerRing.frame = CGRectMake(c.x - r, c.y - r, d, d);
    self.outerRing.layer.cornerRadius = r;

    self.sprintHalo.frame = CGRectInset(self.outerRing.frame, -3.0, -3.0);
    self.sprintHalo.layer.cornerRadius = self.sprintHalo.bounds.size.width * 0.5;

    CGFloat knobD = d * 0.42;
    CGFloat maxTravel = r - knobD * 0.34;
    CGFloat len = hypot(self.knobX, self.knobY);
    CGFloat cx = self.knobX;
    CGFloat cy = self.knobY;
    if (len > 1.0) {
        cx /= len;
        cy /= len;
    }
    CGPoint knobCenter = CGPointMake(c.x + cx * maxTravel, c.y - cy * maxTravel);
    self.knobView.frame = CGRectMake(knobCenter.x - knobD * 0.5, knobCenter.y - knobD * 0.5, knobD, knobD);
    self.knobView.layer.cornerRadius = knobD * 0.5;

    CGFloat badgeD = 32.0;
    self.lockBadge.frame = CGRectMake(c.x - badgeD * 0.5, c.y - r - badgeD - 12.0, badgeD, badgeD);
    self.lockBadge.layer.cornerRadius = badgeD * 0.5;
    self.lockIconView.frame = CGRectInset(self.lockBadge.bounds, 7.0, 7.0);
}

- (CGPoint)sprintLockCenterInSuperview {
    return [self convertPoint:self.lockBadge.center toView:self.superview];
}

- (void)setKnobVectorX:(CGFloat)x y:(CGFloat)y {
    self.knobX = x;
    self.knobY = y;
    [self setNeedsLayout];
}

- (void)setActive:(BOOL)active {
    if (_active == active) return;
    _active = active;
    [self refreshAppearance];
}

- (void)setFloatingMode:(BOOL)floatingMode {
    if (_floatingMode == floatingMode) return;
    _floatingMode = floatingMode;
    [self refreshAppearance];
}

- (void)setSprinting:(BOOL)sprinting {
    if (_sprinting == sprinting) return;
    _sprinting = sprinting;
    [self refreshAppearance];
}

- (void)setSprintLocked:(BOOL)sprintLocked {
    if (_sprintLocked == sprintLocked) return;
    _sprintLocked = sprintLocked;
    [self refreshAppearance];
}

- (void)setSprintLockHover:(BOOL)sprintLockHover {
    if (_sprintLockHover == sprintLockHover) return;
    _sprintLockHover = sprintLockHover;
    [self refreshAppearance];
}

- (void)setHudOpacity:(CGFloat)hudOpacity {
    _hudOpacity = hudOpacity;
    [self refreshAppearance];
}

- (void)refreshAppearance {
    CGFloat baseAlpha = self.hudOpacity;
    BOOL restingFloating = self.floatingMode && !self.active && !self.sprintLocked;
    CGFloat alpha = restingFloating ? baseAlpha * 0.34 : baseAlpha;

    self.outerRing.backgroundColor = [UIColor colorWithRed:0.08 green:0.10 blue:0.13 alpha:0.42 * alpha];
    self.outerRing.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.45 * alpha + 0.08].CGColor;

    BOOL showSprint = self.sprinting || self.sprintLocked;
    self.sprintHalo.hidden = !showSprint;

    self.knobView.backgroundColor = showSprint
        ? [UIColor colorWithRed:0.42 green:0.96 blue:0.60 alpha:fmin(0.92, alpha + 0.18)]
        : [UIColor colorWithWhite:1.0 alpha:self.active ? fmin(0.85, alpha + 0.16) : (0.55 * alpha)];
    self.knobView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:fmin(0.95, alpha + 0.22)].CGColor;

    BOOL showLock = self.sprintLocked || (self.active && self.sprinting);
    self.lockBadge.hidden = !showLock;
    self.lockBadge.backgroundColor = bedrockFillColor(self.sprintLockHover, self.sprintLocked || self.sprintLockHover, fmax(baseAlpha, 0.72));
    self.lockBadge.layer.borderColor = bedrockBorderColor(self.sprintLockHover, self.sprintLocked || self.sprintLockHover, fmax(baseAlpha, 0.72)).CGColor;
    self.lockBadge.transform = self.sprintLockHover ? CGAffineTransformMakeScale(1.18, 1.18) : CGAffineTransformIdentity;
}

@end

#pragma mark - HorizonDpadView

@interface HorizonDpadView ()
@property (nonatomic, strong) HorizonBedrockButton *upBtn;
@property (nonatomic, strong) HorizonBedrockButton *downBtn;
@property (nonatomic, strong) HorizonBedrockButton *leftBtn;
@property (nonatomic, strong) HorizonBedrockButton *rightBtn;
@property (nonatomic, strong) HorizonBedrockButton *diagLeftBtn;
@property (nonatomic, strong) HorizonBedrockButton *diagRightBtn;
@property (nonatomic, strong) HorizonBedrockButton *centerBtn;
@end

@implementation HorizonDpadView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        _hudOpacity = 0.72;
        _centerIcon = HorizonIconSneak;
        self.userInteractionEnabled = NO;

        _upBtn        = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconDpadUp circular:NO];
        _downBtn      = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconDpadDown circular:NO];
        _leftBtn      = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconDpadLeft circular:NO];
        _rightBtn     = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconDpadRight circular:NO];
        _diagLeftBtn  = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconDpadDiagUpLeft circular:NO];
        _diagRightBtn = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconDpadDiagUpRight circular:NO];
        _centerBtn    = [[HorizonBedrockButton alloc] initWithIcon:HorizonIconSneak circular:NO];

        _diagLeftBtn.alpha = 0.0;
        _diagRightBtn.alpha = 0.0;

        for (UIView *v in @[_upBtn, _downBtn, _leftBtn, _rightBtn, _diagLeftBtn, _diagRightBtn, _centerBtn]) {
            [self addSubview:v];
        }
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat gap = 4.0;
    CGFloat cell = (MIN(b.size.width, b.size.height) - gap * 2.0) / 3.0;
    CGFloat ox = (b.size.width - (cell * 3.0 + gap * 2.0)) * 0.5;
    CGFloat oy = (b.size.height - (cell * 3.0 + gap * 2.0)) * 0.5;

    self.diagLeftBtn.frame  = CGRectMake(ox, oy, cell, cell);
    self.upBtn.frame        = CGRectMake(ox + cell + gap, oy, cell, cell);
    self.diagRightBtn.frame = CGRectMake(ox + (cell + gap) * 2.0, oy, cell, cell);

    self.leftBtn.frame      = CGRectMake(ox, oy + cell + gap, cell, cell);
    self.centerBtn.frame    = CGRectMake(ox + cell + gap, oy + cell + gap, cell, cell);
    self.rightBtn.frame     = CGRectMake(ox + (cell + gap) * 2.0, oy + cell + gap, cell, cell);

    self.downBtn.frame      = CGRectMake(ox + cell + gap, oy + (cell + gap) * 2.0, cell, cell);
}

- (void)setHudOpacity:(CGFloat)hudOpacity {
    _hudOpacity = hudOpacity;
    for (HorizonBedrockButton *btn in @[self.upBtn, self.downBtn, self.leftBtn, self.rightBtn,
                                        self.diagLeftBtn, self.diagRightBtn, self.centerBtn]) {
        btn.hudOpacity = hudOpacity;
    }
}

- (void)setCenterIcon:(HorizonIconKind)centerIcon {
    _centerIcon = centerIcon;
    self.centerBtn.iconKind = centerIcon;
}

- (void)updateDiagonalsVisibility {
    BOOL showDiag = self.upPressed || self.diagLeftPressed || self.diagRightPressed;
    CGFloat target = showDiag ? 1.0 : 0.0;
    self.diagLeftBtn.alpha = target;
    self.diagRightBtn.alpha = target;
}

- (void)setUpPressed:(BOOL)v { _upPressed = v; self.upBtn.pressed = v; [self updateDiagonalsVisibility]; }
- (void)setDownPressed:(BOOL)v { _downPressed = v; self.downBtn.pressed = v; }
- (void)setLeftPressed:(BOOL)v { _leftPressed = v; self.leftBtn.pressed = v; }
- (void)setRightPressed:(BOOL)v { _rightPressed = v; self.rightBtn.pressed = v; }
- (void)setDiagLeftPressed:(BOOL)v { _diagLeftPressed = v; self.diagLeftBtn.pressed = v; [self updateDiagonalsVisibility]; }
- (void)setDiagRightPressed:(BOOL)v { _diagRightPressed = v; self.diagRightBtn.pressed = v; [self updateDiagonalsVisibility]; }
- (void)setCenterPressed:(BOOL)v { _centerPressed = v; self.centerBtn.pressed = v; }
- (void)setCenterHighlighted:(BOOL)v { _centerHighlighted = v; self.centerBtn.activeHighlight = v; }

- (uint8_t)hitMaskForPoint:(CGPoint)p {
    if (CGRectContainsPoint(self.centerBtn.frame, p)) return (1u << 4);
    if (CGRectContainsPoint(self.upBtn.frame, p))     return (1u << 0);
    if (CGRectContainsPoint(self.downBtn.frame, p))   return (1u << 1);
    if (CGRectContainsPoint(self.leftBtn.frame, p))   return (1u << 2);
    if (CGRectContainsPoint(self.rightBtn.frame, p))  return (1u << 3);
    BOOL showDiag = self.upPressed || self.diagLeftPressed || self.diagRightPressed;
    if (showDiag && CGRectContainsPoint(self.diagLeftBtn.frame, p))  return (1u << 0) | (1u << 2);
    if (showDiag && CGRectContainsPoint(self.diagRightBtn.frame, p)) return (1u << 0) | (1u << 3);
    return 0;
}

@end

#pragma mark - HorizonBreakRingView

@interface HorizonBreakRingView ()
@property (nonatomic, strong) CAShapeLayer *outerRingLayer;
@property (nonatomic, strong) CAShapeLayer *fillDiscLayer;
@property (nonatomic, strong) CAShapeLayer *progressArcLayer;
@end

@implementation HorizonBreakRingView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;

        _outerRingLayer = [CAShapeLayer layer];
        _outerRingLayer.fillColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
        _outerRingLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.65].CGColor;
        _outerRingLayer.lineWidth = 2.0;
        [self.layer addSublayer:_outerRingLayer];

        _fillDiscLayer = [CAShapeLayer layer];
        _fillDiscLayer.fillColor = [UIColor colorWithWhite:1.0 alpha:0.30].CGColor;
        [self.layer addSublayer:_fillDiscLayer];

        _progressArcLayer = [CAShapeLayer layer];
        _progressArcLayer.fillColor = UIColor.clearColor.CGColor;
        _progressArcLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.95].CGColor;
        _progressArcLayer.lineWidth = 3.0;
        _progressArcLayer.lineCap = kCALineCapRound;
        _progressArcLayer.strokeEnd = 0.0;
        [self.layer addSublayer:_progressArcLayer];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self updateLayers];
}

- (void)setProgress:(CGFloat)progress {
    _progress = fmin(fmax(progress, 0.0), 1.0);
    [self updateLayers];
}

- (void)updateLayers {
    CGRect b = self.bounds;
    CGPoint center = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    CGFloat radius = MIN(b.size.width, b.size.height) * 0.5 - 2.0;
    if (radius <= 1.0) return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.outerRingLayer.path = [UIBezierPath bezierPathWithOvalInRect:
        CGRectMake(center.x - radius, center.y - radius, radius * 2.0, radius * 2.0)].CGPath;

    CGFloat innerR = radius * (0.18 + 0.80 * self.progress);
    self.fillDiscLayer.path = [UIBezierPath bezierPathWithOvalInRect:
        CGRectMake(center.x - innerR, center.y - innerR, innerR * 2.0, innerR * 2.0)].CGPath;

    UIBezierPath *arc = [UIBezierPath bezierPathWithArcCenter:center
                                                       radius:radius
                                                   startAngle:(CGFloat)(-M_PI_2)
                                                     endAngle:(CGFloat)(M_PI * 1.5)
                                                    clockwise:YES];
    self.progressArcLayer.path = arc.CGPath;
    self.progressArcLayer.strokeEnd = self.progress;
    [CATransaction commit];
}

@end

#pragma mark - HorizonGreenProgressBar

@interface HorizonGreenProgressBar ()
@property (nonatomic, strong) UIView *fillView;
@end

@implementation HorizonGreenProgressBar

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor colorWithRed:0.06 green:0.08 blue:0.07 alpha:0.85];
        self.layer.cornerRadius = 3.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.50].CGColor;
        self.clipsToBounds = YES;

        _fillView = [[UIView alloc] init];
        _fillView.backgroundColor = [UIColor colorWithRed:0.30 green:0.90 blue:0.34 alpha:1.0];
        [self addSubview:_fillView];
    }
    return self;
}

- (void)setProgress:(CGFloat)progress {
    _progress = fmin(fmax(progress, 0.0), 1.0);
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect inner = CGRectInset(self.bounds, 1.0, 1.0);
    inner.size.width *= self.progress;
    self.fillView.frame = inner;
}

@end

#pragma mark - HorizonChatBarView

@interface HorizonChatBarView () <UITextFieldDelegate>
@property (nonatomic, strong, readwrite) UITextField *textField;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *tabButton;
@property (nonatomic, strong) UIButton *upButton;
@property (nonatomic, strong) UIButton *downButton;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, assign) BOOL applyingSyncedText;
@end

@implementation HorizonChatBarView

- (UIButton *)makeToolbarButtonWithTitle:(NSString *)title bg:(UIColor *)bg action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    btn.backgroundColor = bg;
    btn.layer.cornerRadius = 7.0;
    btn.layer.borderWidth = 1.0;
    btn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.backgroundColor = [UIColor colorWithRed:0.08 green:0.10 blue:0.13 alpha:0.88];
        self.layer.cornerRadius = 11.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;

        UIColor *subtleBg = [UIColor colorWithWhite:1.0 alpha:0.14];
        UIColor *sendBg   = [UIColor colorWithRed:0.18 green:0.74 blue:0.38 alpha:0.92];

        _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_closeButton setImage:[HorizonIcons iconForKind:HorizonIconClose pointSize:16.0] forState:UIControlStateNormal];
        _closeButton.tintColor = UIColor.whiteColor;
        _closeButton.backgroundColor = subtleBg;
        _closeButton.layer.cornerRadius = 7.0;
        [_closeButton addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_closeButton];

        _textField = [[UITextField alloc] init];
        _textField.delegate = self;
        _textField.textColor = UIColor.whiteColor;
        _textField.tintColor = [UIColor colorWithRed:0.40 green:0.95 blue:0.58 alpha:1.0];
        _textField.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.38];
        _textField.layer.cornerRadius = 7.0;
        _textField.layer.borderWidth = 1.0;
        _textField.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
        _textField.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
        _textField.returnKeyType = UIReturnKeySend;
        _textField.autocorrectionType = UITextAutocorrectionTypeNo;
        _textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _textField.spellCheckingType = UITextSpellCheckingTypeNo;
        _textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        _textField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 9.0, 1.0)];
        _textField.leftViewMode = UITextFieldViewModeAlways;
        _textField.attributedPlaceholder = [[NSAttributedString alloc]
            initWithString:HL(@"Chat or /command...", @"Чат или /команда...")
                attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.42]}];
        [_textField addTarget:self action:@selector(onTextChanged) forControlEvents:UIControlEventEditingChanged];
        [self addSubview:_textField];

        _tabButton  = [self makeToolbarButtonWithTitle:@"Tab" bg:subtleBg action:@selector(onTab)];
        _upButton   = [self makeToolbarButtonWithTitle:@"" bg:subtleBg action:@selector(onUp)];
        _downButton = [self makeToolbarButtonWithTitle:@"" bg:subtleBg action:@selector(onDown)];
        [_upButton setImage:[HorizonIcons iconForKind:HorizonIconDpadUp pointSize:13.0] forState:UIControlStateNormal];
        [_downButton setImage:[HorizonIcons iconForKind:HorizonIconDpadDown pointSize:13.0] forState:UIControlStateNormal];
        _upButton.tintColor = UIColor.whiteColor;
        _downButton.tintColor = UIColor.whiteColor;
        _sendButton = [self makeToolbarButtonWithTitle:HL(@"Send", @"Отпр.") bg:sendBg action:@selector(onSend)];

        for (UIView *v in @[_tabButton, _upButton, _downButton, _sendButton]) {
            [self addSubview:v];
        }
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat pad = 5.0;
    CGFloat h = b.size.height - pad * 2.0;
    CGFloat x = pad;

    self.closeButton.frame = CGRectMake(x, pad, h, h);
    x += h + pad;

    CGFloat sendW = 54.0;
    CGFloat arrowW = 30.0;
    CGFloat tabW = 42.0;
    CGFloat rightGroupW = tabW + pad + arrowW + pad + arrowW + pad + sendW + pad;
    CGFloat fieldW = MAX(80.0, b.size.width - x - rightGroupW);

    self.textField.frame = CGRectMake(x, pad, fieldW, h);
    x += fieldW + pad;

    self.tabButton.frame  = CGRectMake(x, pad, tabW, h);   x += tabW + pad;
    self.upButton.frame   = CGRectMake(x, pad, arrowW, h); x += arrowW + pad;
    self.downButton.frame = CGRectMake(x, pad, arrowW, h); x += arrowW + pad;
    self.sendButton.frame = CGRectMake(x, pad, sendW, h);
}

- (void)setSyncedText:(NSString *)text {
    if ([self.textField.text isEqualToString:text]) return;
    self.applyingSyncedText = YES;
    self.textField.text = text;
    self.applyingSyncedText = NO;
}

- (void)onTextChanged {
    if (self.applyingSyncedText) return;
    [self.delegate chatBarDidChangeText:self.textField.text ?: @""];
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    (void)textField;
    [self.delegate chatBarDidBeginEditing];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    (void)textField;
    [self.delegate chatBarDidTapSend];
    return NO;
}

- (void)onSend  { [self.delegate chatBarDidTapSend]; }
- (void)onClose { [self.delegate chatBarDidTapClose]; }
- (void)onTab   { [self.delegate chatBarDidTapTab]; }
- (void)onUp    { [self.delegate chatBarDidTapHistoryUp]; }
- (void)onDown  { [self.delegate chatBarDidTapHistoryDown]; }

@end
