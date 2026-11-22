// horizon-ios: native compact Bedrock touch settings sheet presented over the game.
#import "HorizonTouchSettingsViewController.h"
#import "HorizonSettings.h"

@interface HorizonTouchSettingsViewController ()
@property (nonatomic, strong) UISegmentedControl *schemeControl;
@property (nonatomic, strong) UISwitch *floatingSwitch;
@property (nonatomic, strong) UISwitch *autoJumpSwitch;
@property (nonatomic, strong) UISlider *buttonScaleSlider;
@property (nonatomic, strong) UILabel *buttonScaleValue;
@property (nonatomic, strong) UISlider *opacitySlider;
@property (nonatomic, strong) UILabel *opacityValue;
@property (nonatomic, strong) UISlider *sensitivitySlider;
@property (nonatomic, strong) UILabel *sensitivityValue;
@property (nonatomic, strong) UISwitch *leftHandedSwitch;
@property (nonatomic, strong) UISwitch *swapJumpSneakSwitch;
@property (nonatomic, strong) UISwitch *hapticsSwitch;
@property (nonatomic, strong) UISwitch *gyroSwitch;
@property (nonatomic, strong) UISlider *gyroSlider;
@property (nonatomic, strong) UILabel *gyroValue;
@property (nonatomic, strong) UISwitch *showLauncherSwitch;
@end

@implementation HorizonTouchSettingsViewController

- (BOOL)prefersPointerLocked {
    return NO;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.09 green:0.11 blue:0.14 alpha:0.96];

    // Header
    UIView *header = [[UIView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    [self.view addSubview:header];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Touch Controls";
    title.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    [header addSubview:title];

    UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    resetBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [resetBtn setTitle:@"Reset" forState:UIControlStateNormal];
    [resetBtn setTitleColor:[UIColor colorWithRed:1.0 green:0.55 blue:0.45 alpha:1.0] forState:UIControlStateNormal];
    resetBtn.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    [resetBtn addTarget:self action:@selector(onReset) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:resetBtn];

    UIButton *doneBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    doneBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [doneBtn setTitle:@"Done" forState:UIControlStateNormal];
    [doneBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    doneBtn.backgroundColor = [UIColor colorWithRed:0.20 green:0.74 blue:0.40 alpha:1.0];
    doneBtn.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    doneBtn.layer.cornerRadius = 8.0;
    doneBtn.contentEdgeInsets = UIEdgeInsetsMake(6.0, 14.0, 6.0, 14.0);
    [doneBtn addTarget:self action:@selector(onDone) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:doneBtn];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12.0;
    [scroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:50.0],

        [title.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [title.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16.0],

        [doneBtn.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [doneBtn.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-14.0],

        [resetBtn.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [resetBtn.trailingAnchor constraintEqualToAnchor:doneBtn.leadingAnchor constant:-14.0],

        [scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:14.0],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:16.0],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-16.0],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-18.0],
    ]];

    // Control scheme segmented picker
    UILabel *schemeTitle = [[UILabel alloc] init];
    schemeTitle.text = @"Control Mode";
    schemeTitle.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    schemeTitle.textColor = [UIColor colorWithWhite:1.0 alpha:0.70];
    [stack addArrangedSubview:schemeTitle];

    self.schemeControl = [[UISegmentedControl alloc] initWithItems:@[@"Crosshair", @"Tap to Interact", @"Classic D-Pad"]];
    self.schemeControl.selectedSegmentTintColor = [UIColor colorWithRed:0.20 green:0.74 blue:0.40 alpha:1.0];
    [self.schemeControl setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateNormal];
    [self.schemeControl setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateSelected];
    [self.schemeControl addTarget:self action:@selector(onChanged) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:self.schemeControl];

    self.floatingSwitch = [self addToggleRow:@"Floating Joystick" toStack:stack];
    self.autoJumpSwitch = [self addToggleRow:@"Auto-Jump (Touch Mode)" toStack:stack];

    UILabel *lbl = nil;
    self.buttonScaleSlider = [self addSliderRow:@"Button Size" min:0.70 max:1.40 valueLabel:&lbl toStack:stack];
    self.buttonScaleValue = lbl;

    self.opacitySlider = [self addSliderRow:@"Button Opacity" min:0.25 max:1.00 valueLabel:&lbl toStack:stack];
    self.opacityValue = lbl;

    self.sensitivitySlider = [self addSliderRow:@"Camera Sensitivity" min:0.30 max:2.50 valueLabel:&lbl toStack:stack];
    self.sensitivityValue = lbl;

    self.leftHandedSwitch = [self addToggleRow:@"Left-Handed Layout" toStack:stack];
    self.swapJumpSneakSwitch = [self addToggleRow:@"Swap Jump & Sneak" toStack:stack];
    self.hapticsSwitch = [self addToggleRow:@"Haptic Feedback" toStack:stack];
    self.gyroSwitch = [self addToggleRow:@"Gyroscope Aiming" toStack:stack];

    self.gyroSlider = [self addSliderRow:@"Gyro Sensitivity" min:0.20 max:3.00 valueLabel:&lbl toStack:stack];
    self.gyroValue = lbl;

    self.showLauncherSwitch = [self addToggleRow:@"Show Launcher on Next Start" toStack:stack];

    [self syncUIFromSettings];
}

- (UISwitch *)addToggleRow:(NSString *)title toStack:(UIStackView *)stack {
    UIView *row = [[UIView alloc] init];
    row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.05];
    row.layer.cornerRadius = 9.0;

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = title;
    label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    label.textColor = UIColor.whiteColor;
    [row addSubview:label];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    sw.onTintColor = [UIColor colorWithRed:0.20 green:0.74 blue:0.40 alpha:1.0];
    [sw addTarget:self action:@selector(onChanged) forControlEvents:UIControlEventValueChanged];
    [row addSubview:sw];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:44.0],
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12.0],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [sw.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12.0],
        [sw.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];
    [stack addArrangedSubview:row];
    return sw;
}

- (UISlider *)addSliderRow:(NSString *)title min:(float)minVal max:(float)maxVal valueLabel:(UILabel **)outLabel toStack:(UIStackView *)stack {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.05];
    card.layer.cornerRadius = 9.0;

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = title;
    label.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
    label.textColor = UIColor.whiteColor;
    [card addSubview:label];

    UILabel *val = [[UILabel alloc] init];
    val.translatesAutoresizingMaskIntoConstraints = NO;
    val.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightSemibold];
    val.textColor = [UIColor colorWithRed:0.48 green:0.95 blue:0.64 alpha:1.0];
    [card addSubview:val];

    UISlider *slider = [[UISlider alloc] init];
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    slider.minimumValue = minVal;
    slider.maximumValue = maxVal;
    slider.minimumTrackTintColor = [UIColor colorWithRed:0.20 green:0.74 blue:0.40 alpha:1.0];
    [slider addTarget:self action:@selector(onChanged) forControlEvents:UIControlEventValueChanged];
    [card addSubview:slider];

    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:card.topAnchor constant:8.0],
        [label.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12.0],
        [val.centerYAnchor constraintEqualToAnchor:label.centerYAnchor],
        [val.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
        [slider.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:4.0],
        [slider.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12.0],
        [slider.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
        [slider.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8.0],
    ]];
    [stack addArrangedSubview:card];
    if (outLabel != NULL) {
        *outLabel = val;
    }
    return slider;
}

- (void)syncUIFromSettings {
    HorizonSettings *s = HorizonSettings.shared;
    self.schemeControl.selectedSegmentIndex = (NSInteger)s.scheme;
    self.floatingSwitch.on = s.floatingJoystick;
    self.autoJumpSwitch.on = s.autoJump;
    self.buttonScaleSlider.value = (float)s.buttonScale;
    self.opacitySlider.value = (float)s.buttonOpacity;
    self.sensitivitySlider.value = (float)s.cameraSensitivity;
    self.leftHandedSwitch.on = s.leftHanded;
    self.swapJumpSneakSwitch.on = s.swapJumpSneak;
    self.hapticsSwitch.on = s.hapticsEnabled;
    self.gyroSwitch.on = s.gyroEnabled;
    self.gyroSlider.value = (float)s.gyroSensitivity;
    self.showLauncherSwitch.on = !s.skipLauncher;
    [self refreshValueLabels];
}

- (void)refreshValueLabels {
    self.buttonScaleValue.text = [NSString stringWithFormat:@"%d%%", (int)llround(self.buttonScaleSlider.value * 100.0f)];
    self.opacityValue.text     = [NSString stringWithFormat:@"%d%%", (int)llround(self.opacitySlider.value * 100.0f)];
    self.sensitivityValue.text = [NSString stringWithFormat:@"%.2fx", self.sensitivitySlider.value];
    self.gyroValue.text        = [NSString stringWithFormat:@"%.2fx", self.gyroSlider.value];
}

- (void)onChanged {
    HorizonSettings *s = HorizonSettings.shared;
    s.scheme            = (HorizonTouchScheme)self.schemeControl.selectedSegmentIndex;
    s.floatingJoystick  = self.floatingSwitch.isOn;
    s.autoJump          = self.autoJumpSwitch.isOn;
    s.buttonScale       = self.buttonScaleSlider.value;
    s.buttonOpacity     = self.opacitySlider.value;
    s.cameraSensitivity = self.sensitivitySlider.value;
    s.leftHanded        = self.leftHandedSwitch.isOn;
    s.swapJumpSneak     = self.swapJumpSneakSwitch.isOn;
    s.hapticsEnabled    = self.hapticsSwitch.isOn;
    s.gyroEnabled       = self.gyroSwitch.isOn;
    s.gyroSensitivity   = self.gyroSlider.value;
    s.skipLauncher      = !self.showLauncherSwitch.isOn;
    [self refreshValueLabels];
    if (self.onSettingsChanged) {
        self.onSettingsChanged();
    }
}

- (void)onReset {
    [HorizonSettings.shared resetToDefaults];
    [self syncUIFromSettings];
    if (self.onSettingsChanged) {
        self.onSettingsChanged();
    }
}

- (void)onDone {
    void (^dismissCb)(void) = self.onDismiss;
    [self dismissViewControllerAnimated:YES completion:^{
        if (dismissCb) dismissCb();
    }];
}

@end
