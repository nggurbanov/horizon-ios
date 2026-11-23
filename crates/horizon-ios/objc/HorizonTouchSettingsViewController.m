// horizon-ios: native compact Bedrock touch settings sheet presented over the game.
#import "HorizonTouchSettingsViewController.h"
#import "HorizonIcons.h"
#import "HorizonL10n.h"
#import "HorizonSettings.h"
#include "horizon_bridge.h"

static NSString *hts_documentsDir(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.count > 0 ? paths.firstObject : [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
}

static id _Nullable hts_parseOwnedCStringJSON(char *raw) {
    if (raw == NULL) return nil;
    NSData *data = [NSData dataWithBytes:raw length:strlen(raw)];
    horizon_ios_free_string(raw);
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

static UIColor *hts_emerald(void)     { return [UIColor colorWithRed:0.20 green:0.74 blue:0.40 alpha:1.0]; }
static UIColor *hts_emeraldSoft(void) { return [UIColor colorWithRed:0.20 green:0.74 blue:0.40 alpha:0.16]; }
static UIColor *hts_emeraldText(void) { return [UIColor colorWithRed:0.48 green:0.95 blue:0.64 alpha:1.0]; }
static UIColor *hts_amber(void)       { return [UIColor colorWithRed:0.95 green:0.66 blue:0.23 alpha:1.0]; }
static UIColor *hts_amberSoft(void)   { return [UIColor colorWithRed:0.95 green:0.66 blue:0.23 alpha:0.16]; }

@interface HorizonTouchSettingsViewController ()
@property (nonatomic, strong) UIStackView *shaderListStack;
@property (nonatomic, strong) UILabel *shaderStatusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *shaderSpinner;
@property (nonatomic, copy) NSArray<NSDictionary *> *installedShaders;
@property (nonatomic, copy) NSString *activeShaderKey;
@property (nonatomic, assign) BOOL shadersLoaded;
@property (nonatomic, assign) BOOL userSelectedShader;
@property (nonatomic, assign) NSUInteger statusGeneration;
@property (nonatomic, strong) UIImpactFeedbackGenerator *lightHaptic;

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
    title.text = HL(@"Touch Controls", @"Сенсорное управление");
    title.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    [header addSubview:title];

    UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    resetBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [resetBtn setTitle:HL(@"Reset", @"Сброс") forState:UIControlStateNormal];
    [resetBtn setTitleColor:[UIColor colorWithRed:1.0 green:0.55 blue:0.45 alpha:1.0] forState:UIControlStateNormal];
    resetBtn.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    [resetBtn addTarget:self action:@selector(onReset) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:resetBtn];

    UIButton *doneBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    doneBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [doneBtn setTitle:HL(@"Done", @"Готово") forState:UIControlStateNormal];
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

    // Live Shader Pack Switcher (top section — 1 tap away after opening Settings)
    self.installedShaders = @[];
    self.activeShaderKey = @"";
    self.lightHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];

    UIView *shaderHeader = [[UIView alloc] init];
    shaderHeader.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *shaderTitle = [[UILabel alloc] init];
    shaderTitle.translatesAutoresizingMaskIntoConstraints = NO;
    shaderTitle.text = HL(@"Shaders", @"Шейдеры");
    shaderTitle.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    shaderTitle.textColor = [UIColor colorWithWhite:1.0 alpha:0.70];
    [shaderHeader addSubview:shaderTitle];

    self.shaderSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.shaderSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.shaderSpinner.color = hts_emerald();
    self.shaderSpinner.hidesWhenStopped = YES;
    self.shaderSpinner.transform = CGAffineTransformMakeScale(0.75, 0.75);
    [shaderHeader addSubview:self.shaderSpinner];

    self.shaderStatusLabel = [[UILabel alloc] init];
    self.shaderStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.shaderStatusLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    self.shaderStatusLabel.textColor = hts_emeraldText();
    self.shaderStatusLabel.textAlignment = NSTextAlignmentRight;
    self.shaderStatusLabel.alpha = 0.0;
    [shaderHeader addSubview:self.shaderStatusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [shaderHeader.heightAnchor constraintGreaterThanOrEqualToConstant:20.0],
        [shaderTitle.leadingAnchor constraintEqualToAnchor:shaderHeader.leadingAnchor],
        [shaderTitle.topAnchor constraintEqualToAnchor:shaderHeader.topAnchor],
        [shaderTitle.bottomAnchor constraintEqualToAnchor:shaderHeader.bottomAnchor],
        [self.shaderSpinner.leadingAnchor constraintEqualToAnchor:shaderTitle.trailingAnchor constant:8.0],
        [self.shaderSpinner.centerYAnchor constraintEqualToAnchor:shaderTitle.centerYAnchor],
        [self.shaderStatusLabel.trailingAnchor constraintEqualToAnchor:shaderHeader.trailingAnchor],
        [self.shaderStatusLabel.centerYAnchor constraintEqualToAnchor:shaderTitle.centerYAnchor],
        [self.shaderStatusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.shaderSpinner.trailingAnchor constant:8.0],
    ]];
    [stack addArrangedSubview:shaderHeader];

    self.shaderListStack = [[UIStackView alloc] init];
    self.shaderListStack.axis = UILayoutConstraintAxisVertical;
    self.shaderListStack.spacing = 6.0;
    [stack addArrangedSubview:self.shaderListStack];
    [self rebuildShaderRows];
    [self loadInstalledShadersAsync];

    UIView *sectionDivider = [[UIView alloc] init];
    sectionDivider.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    [sectionDivider.heightAnchor constraintEqualToConstant:1.0].active = YES;
    [stack addArrangedSubview:sectionDivider];

    // Control scheme segmented picker
    UILabel *schemeTitle = [[UILabel alloc] init];
    schemeTitle.text = HL(@"Control Mode", @"Режим управления");
    schemeTitle.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    schemeTitle.textColor = [UIColor colorWithWhite:1.0 alpha:0.70];
    [stack addArrangedSubview:schemeTitle];

    self.schemeControl = [[UISegmentedControl alloc] initWithItems:@[
        HL(@"Crosshair", @"Прицел"),
        HL(@"Tap to Interact", @"Тап по миру"),
        HL(@"Classic D-Pad", @"Крестовина"),
    ]];
    self.schemeControl.selectedSegmentTintColor = [UIColor colorWithRed:0.20 green:0.74 blue:0.40 alpha:1.0];
    [self.schemeControl setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateNormal];
    [self.schemeControl setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateSelected];
    [self.schemeControl addTarget:self action:@selector(onChanged) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:self.schemeControl];

    self.floatingSwitch = [self addToggleRow:HL(@"Floating Joystick", @"Плавающий джойстик") toStack:stack];
    self.autoJumpSwitch = [self addToggleRow:HL(@"Auto-Jump (Touch Mode)", @"Автопрыжок (сенсорный режим)") toStack:stack];

    UILabel *lbl = nil;
    self.buttonScaleSlider = [self addSliderRow:HL(@"Button Size", @"Размер кнопок") min:0.70 max:1.40 valueLabel:&lbl toStack:stack];
    self.buttonScaleValue = lbl;

    self.opacitySlider = [self addSliderRow:HL(@"Button Opacity", @"Прозрачность кнопок") min:0.25 max:1.00 valueLabel:&lbl toStack:stack];
    self.opacityValue = lbl;

    self.sensitivitySlider = [self addSliderRow:HL(@"Camera Sensitivity", @"Чувствительность камеры") min:0.30 max:2.50 valueLabel:&lbl toStack:stack];
    self.sensitivityValue = lbl;

    self.leftHandedSwitch = [self addToggleRow:HL(@"Left-Handed Layout", @"Раскладка для левши") toStack:stack];
    self.swapJumpSneakSwitch = [self addToggleRow:HL(@"Swap Jump & Sneak", @"Поменять прыжок и приседание") toStack:stack];
    self.hapticsSwitch = [self addToggleRow:HL(@"Haptic Feedback", @"Тактильный отклик") toStack:stack];
    self.gyroSwitch = [self addToggleRow:HL(@"Gyroscope Aiming", @"Прицеливание гироскопом") toStack:stack];

    self.gyroSlider = [self addSliderRow:HL(@"Gyro Sensitivity", @"Чувствительность гироскопа") min:0.20 max:3.00 valueLabel:&lbl toStack:stack];
    self.gyroValue = lbl;

    self.showLauncherSwitch = [self addToggleRow:HL(@"Show Launcher on Next Start", @"Показывать лаунчер при следующем запуске") toStack:stack];

    [self syncUIFromSettings];
}

#pragma mark - In-Game Shader Pack Switcher

- (void)loadInstalledShadersAsync {
    [self.shaderSpinner startAnimating];
    NSString *dir = hts_documentsDir();
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char *raw = horizon_ios_mods_list_installed_json(dir.UTF8String, "", NULL);
        id parsed = hts_parseOwnedCStringJSON(raw);
        NSArray<NSDictionary *> *shaders = @[];
        NSString *picked = @"";
        if ([parsed isKindOfClass:NSDictionary.class]) {
            NSDictionary *dict = (NSDictionary *)parsed;
            if ([dict[@"shaders"] isKindOfClass:NSArray.class]) {
                shaders = dict[@"shaders"];
            }
            if ([dict[@"picked_shader"] isKindOfClass:NSString.class]) {
                picked = dict[@"picked_shader"];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = weakSelf;
            if (s == nil) return;
            [s.shaderSpinner stopAnimating];
            s.installedShaders = shaders;
            if (!s.userSelectedShader) {
                s.activeShaderKey = picked;
            }
            s.shadersLoaded = YES;
            [s rebuildShaderRows];
        });
    });
}

- (UIControl *)makeShaderRowWithTitle:(NSString *)title
                            packValue:(NSString *)packValue
                             heavyGpu:(BOOL)heavyGpu
                               active:(BOOL)active {
    UIControl *row = [[UIControl alloc] init];
    row.backgroundColor = active ? hts_emeraldSoft() : [UIColor colorWithWhite:1.0 alpha:0.05];
    row.layer.cornerRadius = 9.0;
    row.layer.borderWidth = active ? 1.0 : 0.0;
    row.layer.borderColor = active ? hts_emerald().CGColor : UIColor.clearColor.CGColor;
    row.accessibilityIdentifier = packValue ?: @"";
    [row addTarget:self action:@selector(onShaderRowTapped:) forControlEvents:UIControlEventTouchUpInside];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = title;
    label.font = [UIFont systemFontOfSize:13.5 weight:(active ? UIFontWeightSemibold : UIFontWeightMedium)];
    label.textColor = active ? hts_emeraldText() : UIColor.whiteColor;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.userInteractionEnabled = NO;
    [row addSubview:label];

    UIImageView *check = [[UIImageView alloc] initWithImage:[HorizonIcons iconForKind:HorizonIconCheck pointSize:15.0]];
    check.translatesAutoresizingMaskIntoConstraints = NO;
    check.tintColor = hts_emerald();
    check.hidden = !active;
    check.userInteractionEnabled = NO;
    [row addSubview:check];

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [row.heightAnchor constraintEqualToConstant:40.0],
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12.0],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [check.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12.0],
        [check.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [check.widthAnchor constraintEqualToConstant:15.0],
        [check.heightAnchor constraintEqualToConstant:15.0],
    ]];

    if (heavyGpu) {
        UILabel *badge = [[UILabel alloc] init];
        badge.translatesAutoresizingMaskIntoConstraints = NO;
        badge.text = [NSString stringWithFormat:@" %@ ", HL(@"Heavy GPU", @"Тяжёлый GPU")];
        badge.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
        badge.textColor = hts_amber();
        badge.backgroundColor = hts_amberSoft();
        badge.layer.cornerRadius = 5.0;
        badge.clipsToBounds = YES;
        badge.userInteractionEnabled = NO;
        [badge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [badge setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [row addSubview:badge];

        [constraints addObjectsFromArray:@[
            [badge.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [badge.trailingAnchor constraintEqualToAnchor:check.leadingAnchor constant:-8.0],
            [badge.heightAnchor constraintEqualToConstant:18.0],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor:badge.leadingAnchor constant:-8.0],
        ]];
    } else {
        [constraints addObject:[label.trailingAnchor constraintLessThanOrEqualToAnchor:check.leadingAnchor constant:-8.0]];
    }

    [NSLayoutConstraint activateConstraints:constraints];
    return row;
}

- (void)rebuildShaderRows {
    for (UIView *sub in [self.shaderListStack.arrangedSubviews copy]) {
        [self.shaderListStack removeArrangedSubview:sub];
        [sub removeFromSuperview];
    }

    NSString *activeKey = self.activeShaderKey ?: @"";
    BOOL offActive = (activeKey.length == 0);
    [self.shaderListStack addArrangedSubview:[self makeShaderRowWithTitle:HL(@"Off (Vanilla)", @"Выкл (Ванилла)")
                                                                packValue:@""
                                                                 heavyGpu:NO
                                                                   active:offActive]];

    for (NSDictionary *item in self.installedShaders) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *key = [item[@"key"] isKindOfClass:NSString.class] ? item[@"key"] : @"";
        NSString *file = [item[@"file"] isKindOfClass:NSString.class] ? item[@"file"] : @"";
        NSString *name = [item[@"name"] isKindOfClass:NSString.class] ? item[@"name"] : @"";
        NSString *packValue = key.length > 0 ? key : file;
        if (packValue.length == 0) continue;
        NSString *displayName = name.length > 0 ? name : packValue;
        BOOL heavyGpu = [item[@"heavy_gpu"] boolValue] || [item[@"traces"] boolValue];
        BOOL active = (activeKey.length > 0)
            && ([activeKey isEqualToString:packValue]
                || (file.length > 0 && [activeKey isEqualToString:file]));
        [self.shaderListStack addArrangedSubview:[self makeShaderRowWithTitle:displayName
                                                                    packValue:packValue
                                                                     heavyGpu:heavyGpu
                                                                       active:active]];
    }

    if (self.shadersLoaded && self.installedShaders.count == 0) {
        UILabel *hint = [[UILabel alloc] init];
        hint.text = HL(@"Install shader packs in Pre-Launcher → Mods → Shaders",
                       @"Установите шейдеры: Лаунчер → Моды → Шейдеры");
        hint.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
        hint.textColor = [UIColor colorWithWhite:1.0 alpha:0.52];
        hint.numberOfLines = 0;
        [self.shaderListStack addArrangedSubview:hint];
    }
}

- (void)onShaderRowTapped:(UIControl *)sender {
    NSString *packValue = sender.accessibilityIdentifier ?: @"";
    self.userSelectedShader = YES;
    self.activeShaderKey = packValue;
    [self rebuildShaderRows];

    if (HorizonSettings.shared.hapticsEnabled) {
        [self.lightHaptic prepare];
        [self.lightHaptic impactOccurred];
    }

    horizon_ios_set_live_shader_pack(packValue.UTF8String);

    self.statusGeneration += 1;
    NSUInteger gen = self.statusGeneration;
    self.shaderStatusLabel.text = (packValue.length == 0)
        ? HL(@"Shader disabled", @"Шейдер выключен")
        : HL(@"Shader applied", @"Шейдер применён");
    self.shaderStatusLabel.alpha = 1.0;

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) s = weakSelf;
        if (s == nil || s.statusGeneration != gen) return;
        [UIView animateWithDuration:0.25 animations:^{
            s.shaderStatusLabel.alpha = 0.0;
        }];
    });
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
