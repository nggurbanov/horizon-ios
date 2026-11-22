// horizon-ios: scrollable monospace log & crash report viewer sheet.
#import "HorizonLogViewerViewController.h"
#import "HorizonIcons.h"

static UIColor *hl_color(uint8_t r, uint8_t g, uint8_t b, CGFloat a) {
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

@interface HorizonLogViewerViewController ()
@property (nonatomic, strong) UISegmentedControl *selector;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIButton *shareButton;
@end

@implementation HorizonLogViewerViewController

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        self.modalPresentationStyle = UIModalPresentationPageSheet;
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
    self.view.backgroundColor = hl_color(16, 21, 27, 1.0);

    UIView *header = [[UIView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.backgroundColor = hl_color(20, 25, 32, 1.0);
    [self.view addSubview:header];

    UIView *line = [[UIView alloc] init];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    [header addSubview:line];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Логи и отчёты";
    title.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightBold];
    title.textColor = hl_color(242, 246, 250, 1.0);
    [header addSubview:title];

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    copyBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [copyBtn setTitle:@"Копировать" forState:UIControlStateNormal];
    [copyBtn setTitleColor:hl_color(152, 166, 184, 1.0) forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
    [copyBtn addTarget:self action:@selector(onCopy) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:copyBtn];

    self.shareButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.shareButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.shareButton setImage:[HorizonIcons iconForKind:HorizonIconShare pointSize:16.0] forState:UIControlStateNormal];
    [self.shareButton setTitle:@"Поделиться" forState:UIControlStateNormal];
    self.shareButton.tintColor = hl_color(51, 189, 102, 1.0);
    [self.shareButton setTitleColor:hl_color(51, 189, 102, 1.0) forState:UIControlStateNormal];
    self.shareButton.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    self.shareButton.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 5);
    [self.shareButton addTarget:self action:@selector(onShare:) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.shareButton];

    UIButton *doneBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    doneBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [doneBtn setTitle:@"Готово" forState:UIControlStateNormal];
    [doneBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    doneBtn.backgroundColor = hl_color(51, 189, 102, 1.0);
    doneBtn.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    doneBtn.layer.cornerRadius = 8.0;
    doneBtn.contentEdgeInsets = UIEdgeInsetsMake(6.0, 14.0, 6.0, 14.0);
    [doneBtn addTarget:self action:@selector(onDone) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:doneBtn];

    NSArray<NSString *> *items = self.titles.count > 0 ? self.titles : @[@"Лог"];
    self.selector = [[UISegmentedControl alloc] initWithItems:items];
    self.selector.translatesAutoresizingMaskIntoConstraints = NO;
    self.selector.selectedSegmentIndex = 0;
    self.selector.selectedSegmentTintColor = hl_color(51, 189, 102, 1.0);
    self.selector.backgroundColor = hl_color(27, 34, 44, 1.0);
    [self.selector setTitleTextAttributes:@{NSForegroundColorAttributeName: hl_color(186, 198, 214, 1.0)} forState:UIControlStateNormal];
    [self.selector setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateSelected];
    [self.selector addTarget:self action:@selector(loadSelectedFile) forControlEvents:UIControlEventValueChanged];
    self.selector.hidden = (items.count <= 1);
    [self.view addSubview:self.selector];

    self.textView = [[UITextView alloc] init];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.backgroundColor = hl_color(13, 17, 22, 1.0);
    self.textView.textColor = hl_color(214, 226, 238, 1.0);
    self.textView.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];
    self.textView.textContainerInset = UIEdgeInsetsMake(12.0, 14.0, 16.0, 14.0);
    [self.view addSubview:self.textView];

    NSLayoutConstraint *topAnchor = (items.count <= 1)
        ? [self.textView.topAnchor constraintEqualToAnchor:header.bottomAnchor]
        : [self.textView.topAnchor constraintEqualToAnchor:self.selector.bottomAnchor constant:10.0];

    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:52.0],

        [line.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [line.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [line.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
        [line.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],

        [title.leadingAnchor constraintEqualToAnchor:header.safeAreaLayoutGuide.leadingAnchor constant:16.0],
        [title.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [doneBtn.trailingAnchor constraintEqualToAnchor:header.safeAreaLayoutGuide.trailingAnchor constant:-16.0],
        [doneBtn.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [self.shareButton.trailingAnchor constraintEqualToAnchor:doneBtn.leadingAnchor constant:-14.0],
        [self.shareButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [copyBtn.trailingAnchor constraintEqualToAnchor:self.shareButton.leadingAnchor constant:-14.0],
        [copyBtn.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [self.selector.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:10.0],
        [self.selector.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16.0],
        [self.selector.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16.0],

        topAnchor,
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self loadSelectedFile];
}

- (nullable NSURL *)selectedFileURL {
    NSInteger idx = self.selector.selectedSegmentIndex;
    if (idx < 0 || (NSUInteger)idx >= self.fileURLs.count) return nil;
    return self.fileURLs[(NSUInteger)idx];
}

- (void)loadSelectedFile {
    NSURL *url = [self selectedFileURL];
    if (url == nil) {
        self.textView.text = @"Лог-файлы пока отсутствуют.";
        return;
    }
    // Read up to last 256 KB so huge logs open instantly without stalling UI.
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (fh == nil) {
        self.textView.text = @"Не удалось прочитать файл.";
        return;
    }
    unsigned long long size = [fh seekToEndOfFile];
    const unsigned long long kMaxBytes = 256 * 1024;
    NSString *prefix = @"";
    if (size > kMaxBytes) {
        [fh seekToFileOffset:(size - kMaxBytes)];
        prefix = [NSString stringWithFormat:@"... показаны последние 256 КБ из %.1f КБ ...\n\n", size / 1024.0];
    } else {
        [fh seekToFileOffset:0];
    }
    NSData *data = [fh readDataToEndOfFile];
    [fh closeFile];

    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (body == nil) {
        body = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
    }
    if (body.length == 0) {
        self.textView.text = @"(файл пуст)";
    } else {
        self.textView.text = [prefix stringByAppendingString:body];
        // Scroll to bottom (most recent entries).
        NSRange end = NSMakeRange(self.textView.text.length > 0 ? self.textView.text.length - 1 : 0, 1);
        [self.textView scrollRangeToVisible:end];
    }
}

- (void)onCopy {
    UIPasteboard.generalPasteboard.string = self.textView.text ?: @"";
}

- (void)onShare:(UIButton *)sender {
    NSURL *url = [self selectedFileURL];
    if (url == nil) return;
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                                                      applicationActivities:nil];
    if (avc.popoverPresentationController != nil) {
        avc.popoverPresentationController.sourceView = sender;
        avc.popoverPresentationController.sourceRect = sender.bounds;
    }
    [self presentViewController:avc animated:YES completion:nil];
}

- (void)onDone {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
