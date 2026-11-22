// horizon-ios: native dark-slate Add / Edit Server sheet with per-server Auto-Login settings.
#import "HorizonServerEditorViewController.h"
#import "HorizonAutoLoginStore.h"
#import "HorizonIcons.h"
#include "horizon_bridge.h"

static UIColor *he_color(uint8_t r, uint8_t g, uint8_t b, CGFloat a) {
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

@interface HorizonServerEditorViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UITextField *addressField;
@property (nonatomic, strong) UISwitch *autoLoginSwitch;
@property (nonatomic, strong) UIView *autoLoginBody;
@property (nonatomic, strong) UITextField *templateField;
@property (nonatomic, strong) NSArray<UIButton *> *presetButtons;
@property (nonatomic, strong) UITextField *passwordField;
@property (nonatomic, strong) UIButton *eyeButton;
@property (nonatomic, strong) UISegmentedControl *delayControl;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, assign) BOOL existingHasPassword;
@end

@implementation HorizonServerEditorViewController

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _serverIndex = -1;
        _initialName = @"";
        _initialAddress = @"";
        _serversDatPath = @"";
        self.modalPresentationStyle = UIModalPresentationFormSheet;
    }
    return self;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = he_color(20, 25, 32, 1.0);

    HorizonAutoLoginConfig *cfg = (self.initialAddress.length > 0)
        ? [HorizonAutoLoginStore.shared configForAddress:self.initialAddress]
        : [[HorizonAutoLoginConfig alloc] init];
    self.existingHasPassword = cfg.hasPassword;

    // Header bar
    UIView *header = [[UIView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.backgroundColor = he_color(16, 21, 27, 1.0);
    [self.view addSubview:header];

    UIView *headerLine = [[UIView alloc] init];
    headerLine.translatesAutoresizingMaskIntoConstraints = NO;
    headerLine.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    [header addSubview:headerLine];

    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [cancelBtn setTitle:@"Отмена" forState:UIControlStateNormal];
    [cancelBtn setTitleColor:he_color(152, 166, 184, 1.0) forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightMedium];
    [cancelBtn addTarget:self action:@selector(onCancel) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:cancelBtn];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = (self.serverIndex >= 0) ? @"Изменить сервер" : @"Новый сервер";
    titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightBold];
    titleLabel.textColor = he_color(242, 246, 250, 1.0);
    [header addSubview:titleLabel];

    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    saveBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [saveBtn setTitle:@"Сохранить" forState:UIControlStateNormal];
    [saveBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    saveBtn.backgroundColor = he_color(51, 189, 102, 1.0);
    saveBtn.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    saveBtn.layer.cornerRadius = 8.0;
    saveBtn.contentEdgeInsets = UIEdgeInsetsMake(6.0, 14.0, 6.0, 14.0);
    [saveBtn addTarget:self action:@selector(onSave) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:saveBtn];

    // Scrollable body
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:self.scrollView];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12.0;
    [self.scrollView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:52.0],

        [headerLine.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [headerLine.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [headerLine.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
        [headerLine.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],

        [cancelBtn.leadingAnchor constraintEqualToAnchor:header.safeAreaLayoutGuide.leadingAnchor constant:16.0],
        [cancelBtn.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [titleLabel.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [titleLabel.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [saveBtn.trailingAnchor constraintEqualToAnchor:header.safeAreaLayoutGuide.trailingAnchor constant:-16.0],
        [saveBtn.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [self.scrollView.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [stack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:14.0],
        [stack.leadingAnchor constraintEqualToAnchor:self.scrollView.safeAreaLayoutGuide.leadingAnchor constant:18.0],
        [stack.trailingAnchor constraintEqualToAnchor:self.scrollView.safeAreaLayoutGuide.trailingAnchor constant:-18.0],
        [stack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-22.0],
    ]];

    // Error banner (hidden until needed)
    self.errorLabel = [[UILabel alloc] init];
    self.errorLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    self.errorLabel.textColor = he_color(242, 169, 59, 1.0);
    self.errorLabel.numberOfLines = 0;
    self.errorLabel.hidden = YES;
    [stack addArrangedSubview:self.errorLabel];

    // Section 1: Server details
    [stack addArrangedSubview:[self sectionHeader:@"СЕРВЕР"]];

    UIView *serverCard = [self cardView];
    UIStackView *serverStack = [[UIStackView alloc] init];
    serverStack.translatesAutoresizingMaskIntoConstraints = NO;
    serverStack.axis = UILayoutConstraintAxisVertical;
    serverStack.spacing = 10.0;
    [serverCard addSubview:serverStack];
    [NSLayoutConstraint activateConstraints:@[
        [serverStack.topAnchor constraintEqualToAnchor:serverCard.topAnchor constant:12.0],
        [serverStack.leadingAnchor constraintEqualToAnchor:serverCard.leadingAnchor constant:14.0],
        [serverStack.trailingAnchor constraintEqualToAnchor:serverCard.trailingAnchor constant:-14.0],
        [serverStack.bottomAnchor constraintEqualToAnchor:serverCard.bottomAnchor constant:-12.0],
    ]];

    self.nameField = [self styledTextFieldWithPlaceholder:@"Например, Survival"];
    self.nameField.text = self.initialName;
    self.nameField.returnKeyType = UIReturnKeyNext;
    [serverStack addArrangedSubview:[self labeledFieldRow:@"Название" field:self.nameField]];

    self.addressField = [self styledTextFieldWithPlaceholder:@"play.example.com или host:port"];
    self.addressField.text = self.initialAddress;
    self.addressField.keyboardType = UIKeyboardTypeURL;
    self.addressField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.addressField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.addressField.returnKeyType = UIReturnKeyDone;
    [serverStack addArrangedSubview:[self labeledFieldRow:@"Адрес" field:self.addressField]];

    [stack addArrangedSubview:serverCard];

    // Section 2: Auto-Login
    [stack addArrangedSubview:[self sectionHeader:@"АВТОЛОГИН ПРИ ВХОДЕ"]];

    UIView *autoCard = [self cardView];
    UIStackView *autoStack = [[UIStackView alloc] init];
    autoStack.translatesAutoresizingMaskIntoConstraints = NO;
    autoStack.axis = UILayoutConstraintAxisVertical;
    autoStack.spacing = 12.0;
    [autoCard addSubview:autoStack];
    [NSLayoutConstraint activateConstraints:@[
        [autoStack.topAnchor constraintEqualToAnchor:autoCard.topAnchor constant:12.0],
        [autoStack.leadingAnchor constraintEqualToAnchor:autoCard.leadingAnchor constant:14.0],
        [autoStack.trailingAnchor constraintEqualToAnchor:autoCard.trailingAnchor constant:-14.0],
        [autoStack.bottomAnchor constraintEqualToAnchor:autoCard.bottomAnchor constant:-12.0],
    ]];

    // Toggle row
    UIView *toggleRow = [[UIView alloc] init];
    UIImageView *keyIcon = [[UIImageView alloc] initWithImage:[HorizonIcons iconForKind:HorizonIconKey pointSize:18.0]];
    keyIcon.translatesAutoresizingMaskIntoConstraints = NO;
    keyIcon.tintColor = he_color(51, 189, 102, 1.0);
    [toggleRow addSubview:keyIcon];

    UILabel *toggleLabel = [[UILabel alloc] init];
    toggleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    toggleLabel.text = @"Включить автологин";
    toggleLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
    toggleLabel.textColor = he_color(242, 246, 250, 1.0);
    [toggleRow addSubview:toggleLabel];

    self.autoLoginSwitch = [[UISwitch alloc] init];
    self.autoLoginSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.autoLoginSwitch.onTintColor = he_color(51, 189, 102, 1.0);
    self.autoLoginSwitch.on = cfg.enabled;
    [self.autoLoginSwitch addTarget:self action:@selector(onAutoLoginToggled) forControlEvents:UIControlEventValueChanged];
    [toggleRow addSubview:self.autoLoginSwitch];

    [NSLayoutConstraint activateConstraints:@[
        [toggleRow.heightAnchor constraintEqualToConstant:34.0],
        [keyIcon.leadingAnchor constraintEqualToAnchor:toggleRow.leadingAnchor],
        [keyIcon.centerYAnchor constraintEqualToAnchor:toggleRow.centerYAnchor],
        [keyIcon.widthAnchor constraintEqualToConstant:18.0],
        [keyIcon.heightAnchor constraintEqualToConstant:18.0],
        [toggleLabel.leadingAnchor constraintEqualToAnchor:keyIcon.trailingAnchor constant:8.0],
        [toggleLabel.centerYAnchor constraintEqualToAnchor:toggleRow.centerYAnchor],
        [self.autoLoginSwitch.trailingAnchor constraintEqualToAnchor:toggleRow.trailingAnchor],
        [self.autoLoginSwitch.centerYAnchor constraintEqualToAnchor:toggleRow.centerYAnchor],
    ]];
    [autoStack addArrangedSubview:toggleRow];

    // Auto-Login body
    UIStackView *bodyStack = [[UIStackView alloc] init];
    bodyStack.axis = UILayoutConstraintAxisVertical;
    bodyStack.spacing = 10.0;
    self.autoLoginBody = bodyStack;

    self.templateField = [self styledTextFieldWithPlaceholder:@"/l {password}"];
    self.templateField.text = cfg.templateString;
    self.templateField.font = [UIFont monospacedSystemFontOfSize:13.5 weight:UIFontWeightMedium];
    self.templateField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.templateField.autocorrectionType = UITextAutocorrectionTypeNo;
    [self.templateField addTarget:self action:@selector(refreshPresetHighlight) forControlEvents:UIControlEventEditingChanged];
    [bodyStack addArrangedSubview:[self labeledFieldRow:@"Шаблон команды" field:self.templateField]];

    // 3 quick preset pills
    NSArray<NSString *> *presets = @[@"/l {password}", @"/login {password}", @"/auth {password}"];
    UIStackView *presetRow = [[UIStackView alloc] init];
    presetRow.axis = UILayoutConstraintAxisHorizontal;
    presetRow.spacing = 8.0;
    presetRow.distribution = UIStackViewDistributionFillEqually;
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    for (NSUInteger i = 0; i < presets.count; i++) {
        UIButton *pill = [UIButton buttonWithType:UIButtonTypeSystem];
        [pill setTitle:presets[i] forState:UIControlStateNormal];
        pill.titleLabel.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightMedium];
        pill.titleLabel.adjustsFontSizeToFitWidth = YES;
        pill.titleLabel.minimumScaleFactor = 0.8;
        pill.layer.cornerRadius = 8.0;
        pill.layer.borderWidth = 1.0;
        pill.tag = (NSInteger)i;
        pill.contentEdgeInsets = UIEdgeInsetsMake(7.0, 8.0, 7.0, 8.0);
        [pill addTarget:self action:@selector(onPresetTapped:) forControlEvents:UIControlEventTouchUpInside];
        [presetRow addArrangedSubview:pill];
        [buttons addObject:pill];
    }
    self.presetButtons = buttons;
    [bodyStack addArrangedSubview:presetRow];

    // Password field with eye toggle
    NSString *pwPlaceholder = self.existingHasPassword
        ? @"Пароль сохранён (введите новый для замены)"
        : @"Введите пароль";
    self.passwordField = [self styledTextFieldWithPlaceholder:pwPlaceholder];
    self.passwordField.secureTextEntry = YES;
    self.passwordField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.passwordField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.passwordField.textContentType = UITextContentTypePassword;

    self.eyeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.eyeButton.frame = CGRectMake(0, 0, 38, 36);
    self.eyeButton.tintColor = he_color(152, 166, 184, 1.0);
    [self.eyeButton setImage:[HorizonIcons iconForKind:HorizonIconEye pointSize:18.0] forState:UIControlStateNormal];
    [self.eyeButton addTarget:self action:@selector(onTogglePasswordVisibility) forControlEvents:UIControlEventTouchUpInside];
    self.passwordField.rightView = self.eyeButton;
    self.passwordField.rightViewMode = UITextFieldViewModeAlways;
    [bodyStack addArrangedSubview:[self labeledFieldRow:@"Пароль" field:self.passwordField]];

    // Delay segmented picker
    UILabel *delayLabel = [[UILabel alloc] init];
    delayLabel.text = @"Задержка после входа в мир";
    delayLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    delayLabel.textColor = he_color(152, 166, 184, 1.0);
    [bodyStack addArrangedSubview:delayLabel];

    self.delayControl = [[UISegmentedControl alloc] initWithItems:@[@"0.5с", @"1.0с", @"2.0с", @"3.0с"]];
    self.delayControl.selectedSegmentTintColor = he_color(51, 189, 102, 1.0);
    self.delayControl.backgroundColor = he_color(34, 43, 55, 1.0);
    [self.delayControl setTitleTextAttributes:@{NSForegroundColorAttributeName: he_color(186, 198, 214, 1.0), NSFontAttributeName: [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium]} forState:UIControlStateNormal];
    [self.delayControl setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor, NSFontAttributeName: [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold]} forState:UIControlStateSelected];
    NSInteger delayIdx = 1;
    if (cfg.delayMs <= 500) delayIdx = 0;
    else if (cfg.delayMs <= 1000) delayIdx = 1;
    else if (cfg.delayMs <= 2000) delayIdx = 2;
    else delayIdx = 3;
    self.delayControl.selectedSegmentIndex = delayIdx;
    [bodyStack addArrangedSubview:self.delayControl];

    // Privacy note
    UILabel *privacyNote = [[UILabel alloc] init];
    privacyNote.text = @"Пароль хранится локально в Keychain и никогда не записывается в логи или историю чата.";
    privacyNote.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    privacyNote.textColor = he_color(109, 123, 142, 1.0);
    privacyNote.numberOfLines = 0;
    [bodyStack addArrangedSubview:privacyNote];

    [autoStack addArrangedSubview:bodyStack];
    [stack addArrangedSubview:autoCard];

    // Section 3: Delete button when editing
    if (self.serverIndex >= 0) {
        UIButton *deleteBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        deleteBtn.backgroundColor = he_color(229, 83, 75, 0.14);
        deleteBtn.layer.cornerRadius = 10.0;
        deleteBtn.layer.borderWidth = 1.0;
        deleteBtn.layer.borderColor = he_color(229, 83, 75, 0.35).CGColor;
        [deleteBtn setTitle:@"Удалить сервер" forState:UIControlStateNormal];
        [deleteBtn setTitleColor:he_color(245, 114, 107, 1.0) forState:UIControlStateNormal];
        [deleteBtn setImage:[HorizonIcons iconForKind:HorizonIconTrash pointSize:16.0] forState:UIControlStateNormal];
        deleteBtn.tintColor = he_color(245, 114, 107, 1.0);
        deleteBtn.titleLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
        deleteBtn.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 8);
        deleteBtn.contentEdgeInsets = UIEdgeInsetsMake(11.0, 16.0, 11.0, 16.0);
        [deleteBtn addTarget:self action:@selector(onDeleteTapped) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:deleteBtn];
    }

    [self updateAutoLoginVisibility];
    [self refreshPresetHighlight];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(onKeyboardChange:)
                                               name:UIKeyboardWillChangeFrameNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(onKeyboardHide:)
                                               name:UIKeyboardWillHideNotification
                                             object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)onKeyboardChange:(NSNotification *)note {
    CGRect kb = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect kbInView = [self.view convertRect:kb fromView:nil];
    CGFloat overlap = MAX(0.0, CGRectGetMaxY(self.scrollView.frame) - CGRectGetMinY(kbInView));
    self.scrollView.contentInset = UIEdgeInsetsMake(0, 0, overlap + 16.0, 0);
    self.scrollView.scrollIndicatorInsets = self.scrollView.contentInset;
}

- (void)onKeyboardHide:(NSNotification *)note {
    (void)note;
    self.scrollView.contentInset = UIEdgeInsetsZero;
    self.scrollView.scrollIndicatorInsets = UIEdgeInsetsZero;
}

- (UILabel *)sectionHeader:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightBold];
    l.textColor = he_color(109, 123, 142, 1.0);
    return l;
}

- (UIView *)cardView {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = he_color(27, 34, 44, 1.0);
    v.layer.cornerRadius = 12.0;
    v.layer.borderWidth = 1.0;
    v.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.06].CGColor;
    return v;
}

- (UITextField *)styledTextFieldWithPlaceholder:(NSString *)placeholder {
    UITextField *tf = [[UITextField alloc] init];
    tf.backgroundColor = he_color(34, 43, 55, 1.0);
    tf.textColor = he_color(242, 246, 250, 1.0);
    tf.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightRegular];
    tf.layer.cornerRadius = 8.0;
    tf.layer.borderWidth = 1.0;
    tf.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.09].CGColor;
    tf.tintColor = he_color(51, 189, 102, 1.0);
    tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 11, 1)];
    tf.leftViewMode = UITextFieldViewModeAlways;
    tf.rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 11, 1)];
    tf.rightViewMode = UITextFieldViewModeAlways;
    tf.delegate = self;
    tf.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:placeholder
            attributes:@{NSForegroundColorAttributeName: he_color(109, 123, 142, 1.0)}];
    [tf.heightAnchor constraintEqualToConstant:38.0].active = YES;
    return tf;
}

- (UIView *)labeledFieldRow:(NSString *)labelText field:(UITextField *)field {
    UIStackView *col = [[UIStackView alloc] init];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 5.0;
    UILabel *l = [[UILabel alloc] init];
    l.text = labelText;
    l.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    l.textColor = he_color(152, 166, 184, 1.0);
    [col addArrangedSubview:l];
    [col addArrangedSubview:field];
    return col;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.nameField) {
        [self.addressField becomeFirstResponder];
    } else {
        [textField resignFirstResponder];
    }
    return YES;
}

- (void)onAutoLoginToggled {
    [self updateAutoLoginVisibility];
}

- (void)updateAutoLoginVisibility {
    BOOL on = self.autoLoginSwitch.isOn;
    self.autoLoginBody.hidden = !on;
}

- (void)onPresetTapped:(UIButton *)sender {
    NSArray<NSString *> *presets = @[@"/l {password}", @"/login {password}", @"/auth {password}"];
    if (sender.tag >= 0 && (NSUInteger)sender.tag < presets.count) {
        self.templateField.text = presets[(NSUInteger)sender.tag];
        [self refreshPresetHighlight];
    }
}

- (void)refreshPresetHighlight {
    NSString *cur = [self.templateField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (UIButton *btn in self.presetButtons) {
        BOOL active = [cur isEqualToString:[btn titleForState:UIControlStateNormal]];
        btn.backgroundColor = active ? he_color(51, 189, 102, 0.22) : he_color(34, 43, 55, 1.0);
        btn.layer.borderColor = active ? he_color(51, 189, 102, 0.85).CGColor : [UIColor colorWithWhite:1.0 alpha:0.09].CGColor;
        [btn setTitleColor:(active ? he_color(120, 236, 162, 1.0) : he_color(186, 198, 214, 1.0))
                  forState:UIControlStateNormal];
    }
}

- (void)onTogglePasswordVisibility {
    BOOL wasFirstResponder = self.passwordField.isFirstResponder;
    self.passwordField.secureTextEntry = !self.passwordField.secureTextEntry;
    HorizonIconKind icon = self.passwordField.secureTextEntry ? HorizonIconEye : HorizonIconEyeOff;
    [self.eyeButton setImage:[HorizonIcons iconForKind:icon pointSize:18.0] forState:UIControlStateNormal];
    if (wasFirstResponder) {
        NSString *current = self.passwordField.text;
        self.passwordField.text = @"";
        self.passwordField.text = current;
    }
}

- (void)showError:(NSString *)message {
    self.errorLabel.text = message;
    self.errorLabel.hidden = NO;
}

- (void)onCancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onSave {
    [self.view endEditing:YES];
    self.errorLabel.hidden = YES;

    NSString *addr = [self.addressField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (addr.length == 0 || [HorizonAutoLoginStore normalizeAddress:addr] == nil) {
        [self showError:@"Введите корректный адрес сервера (например, play.example.com или host:port)."];
        return;
    }
    if (name.length == 0) {
        name = addr;
    }

    BOOL autoOn = self.autoLoginSwitch.isOn;
    NSString *newPw = self.passwordField.text ?: @"";
    if (autoOn && newPw.length == 0 && !self.existingHasPassword) {
        [self showError:@"Для автологина укажите пароль сервера."];
        return;
    }

    char errBuf[256] = {0};
    bool ok = horizon_ios_upsert_server(
        self.serversDatPath.UTF8String,
        (int32_t)self.serverIndex,
        name.UTF8String,
        addr.UTF8String,
        errBuf,
        sizeof(errBuf)
    );
    if (!ok) {
        NSString *msg = (errBuf[0] != '\0') ? [NSString stringWithUTF8String:errBuf] : @"Не удалось сохранить servers.dat";
        [self showError:msg];
        return;
    }

    // If editing and address changed, migrate stored credentials first.
    if (self.serverIndex >= 0 && self.initialAddress.length > 0) {
        [HorizonAutoLoginStore.shared migrateFromAddress:self.initialAddress toAddress:addr];
    }

    static const uint64_t kDelays[4] = {500, 1000, 2000, 3000};
    NSInteger seg = self.delayControl.selectedSegmentIndex;
    uint64_t delayMs = (seg >= 0 && seg < 4) ? kDelays[seg] : 1000;

    HorizonAutoLoginConfig *cfg = [[HorizonAutoLoginConfig alloc] init];
    cfg.enabled = autoOn;
    cfg.templateString = self.templateField.text.length > 0 ? self.templateField.text : @"/l {password}";
    cfg.delayMs = delayMs;

    [HorizonAutoLoginStore.shared saveConfig:cfg
                                 newPassword:(newPw.length > 0 ? newPw : nil)
                               clearPassword:NO
                                  forAddress:addr];

    void (^cb)(void) = self.onSaved;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb();
    }];
}

- (void)onDeleteTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Удалить сервер?"
                                                                   message:@"Сервер и его сохранённый пароль автологина будут удалены."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Удалить" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        (void)action;
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        char errBuf[256] = {0};
        if (horizon_ios_delete_server(strongSelf.serversDatPath.UTF8String, (int32_t)strongSelf.serverIndex, errBuf, sizeof(errBuf))) {
            if (strongSelf.initialAddress.length > 0) {
                [HorizonAutoLoginStore.shared deleteForAddress:strongSelf.initialAddress];
            }
            void (^cb)(void) = strongSelf.onDeleted;
            [strongSelf dismissViewControllerAnimated:YES completion:^{
                if (cb) cb();
            }];
        } else {
            NSString *msg = (errBuf[0] != '\0') ? [NSString stringWithUTF8String:errBuf] : @"Ошибка удаления";
            [strongSelf showError:msg];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
