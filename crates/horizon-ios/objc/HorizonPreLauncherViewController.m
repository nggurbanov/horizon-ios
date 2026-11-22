// horizon-ios: native UIKit 5-tab landscape split-view Pre-Launcher.
// Fast ~0.2s boot before Metal / 686 MB assets load. Dark slate + emerald design,
// full safe-area support for Dynamic Island / notch / iPad, zero emoji.
#import "HorizonPreLauncherViewController.h"
#import "HorizonAutoLoginStore.h"
#import "HorizonIcons.h"
#import "HorizonLogViewerViewController.h"
#import "HorizonPreLauncherAppDelegate.h"
#import "HorizonServerEditorViewController.h"
#import "HorizonSettings.h"
#import <GameController/GameController.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "horizon_bridge.h"
#include <os/proc.h>

typedef NS_ENUM(NSInteger, HorizonLauncherTab) {
    HorizonLauncherTabHome = 0,
    HorizonLauncherTabServers = 1,
    HorizonLauncherTabControls = 2,
    HorizonLauncherTabGraphics = 3,
    HorizonLauncherTabFiles = 4,
};

typedef NS_ENUM(NSInteger, HorizonPickerPurpose) {
    HorizonPickerPurposeResourcesFolder = 1,
    HorizonPickerPurposeResourcesZip = 2,
    HorizonPickerPurposeResourcePackZip = 3,
    HorizonPickerPurposeShaderPackZip = 4,
};

#pragma mark - Palette Helpers

static UIColor *pl_rgb(uint8_t r, uint8_t g, uint8_t b, CGFloat a) {
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

static UIColor *pl_railBg(void)      { return pl_rgb(16, 21, 27, 1.0); }    // #10151b
static UIColor *pl_stageBg(void)     { return pl_rgb(20, 25, 32, 1.0); }    // #141920
static UIColor *pl_cardBg(void)      { return pl_rgb(27, 34, 44, 1.0); }    // #1b222c
static UIColor *pl_elevatedBg(void)  { return pl_rgb(34, 43, 55, 1.0); }    // #222b37
static UIColor *pl_emerald(void)     { return pl_rgb(51, 189, 102, 1.0); }  // #33bd66
static UIColor *pl_emeraldSoft(void) { return pl_rgb(51, 189, 102, 0.16); }
static UIColor *pl_amber(void)       { return pl_rgb(242, 169, 59, 1.0); }
static UIColor *pl_danger(void)      { return pl_rgb(229, 83, 75, 1.0); }
static UIColor *pl_textPrimary(void) { return pl_rgb(242, 246, 250, 1.0); }
static UIColor *pl_textSec(void)     { return pl_rgb(152, 166, 184, 1.0); }
static UIColor *pl_textMuted(void)   { return pl_rgb(109, 123, 142, 1.0); }
static UIColor *pl_hairline(void)    { return [UIColor colorWithWhite:1.0 alpha:0.08]; }

static NSString *pl_formatBytes(uint64_t bytes) {
    if (bytes >= 1024ULL * 1024ULL * 1024ULL) {
        return [NSString stringWithFormat:@"%.1f ГБ", bytes / (1024.0 * 1024.0 * 1024.0)];
    }
    if (bytes >= 1024ULL * 1024ULL) {
        return [NSString stringWithFormat:@"%.0f МБ", bytes / (1024.0 * 1024.0)];
    }
    if (bytes >= 1024ULL) {
        return [NSString stringWithFormat:@"%.0f КБ", bytes / 1024.0];
    }
    return [NSString stringWithFormat:@"%llu Б", (unsigned long long)bytes];
}

static uint64_t pl_directorySize(NSString *path) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDirectoryEnumerator *en = [fm enumeratorAtURL:[NSURL fileURLWithPath:path]
                         includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLIsRegularFileKey]
                                            options:0
                                       errorHandler:nil];
    uint64_t total = 0;
    for (NSURL *url in en) {
        NSNumber *isFile = nil;
        [url getResourceValue:&isFile forKey:NSURLIsRegularFileKey error:nil];
        if (!isFile.boolValue) continue;
        NSNumber *sz = nil;
        [url getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
        total += sz.unsignedLongLongValue;
    }
    return total;
}

static BOOL pl_hasIncreasedMemoryEntitlement(void) {
    // 1. Check embedded provisioning profile (present on sideloaded IPA / AltStore / SideStore).
    NSString *provPath = [NSBundle.mainBundle pathForResource:@"embedded" ofType:@"mobileprovision"];
    if (provPath.length > 0) {
        NSData *data = [NSData dataWithContentsOfFile:provPath];
        if (data.length > 0) {
            NSString *raw = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
            NSRange keyRange = [raw rangeOfString:@"com.apple.developer.kernel.increased-memory-limit"];
            if (keyRange.location != NSNotFound) {
                NSUInteger tailLen = MIN((NSUInteger)64, raw.length - NSMaxRange(keyRange));
                NSString *tail = [raw substringWithRange:NSMakeRange(NSMaxRange(keyRange), tailLen)];
                if ([tail containsString:@"<true/>"]) {
                    return YES;
                }
            }
        }
    }
    // 2. Heuristic fallback via public iOS 13+ os_proc_available_memory() (e.g. inside LiveContainer).
    size_t avail = os_proc_available_memory();
    return avail >= (size_t)(2400ULL * 1024ULL * 1024ULL);
}

#pragma mark - Server Ping State Model

@interface HorizonPingState : NSObject
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL online;
@property (nonatomic, assign) uint64_t latencyMs;
@property (nonatomic, assign) int64_t playersOnline;
@property (nonatomic, assign) int64_t playersMax;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *motd;
@property (nonatomic, copy) NSString *errorText;
@end

@implementation HorizonPingState
@end

#pragma mark - Navigation Rail Item View

@interface HorizonRailTabButton : UIControl
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, strong) UIView *warningDot;
@property (nonatomic, assign) BOOL activeTab;
@end

@implementation HorizonRailTabButton

- (instancetype)initWithTitle:(NSString *)title icon:(HorizonIconKind)icon {
    self = [super initWithFrame:CGRectZero];
    if (self != nil) {
        self.layer.cornerRadius = 10.0;
        self.translatesAutoresizingMaskIntoConstraints = NO;

        _iconView = [[UIImageView alloc] initWithImage:[HorizonIcons iconForKind:icon pointSize:18.0]];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:_iconView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.text = title;
        _titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        [self addSubview:_titleLabel];

        _badgeLabel = [[UILabel alloc] init];
        _badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _badgeLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightBold];
        _badgeLabel.textAlignment = NSTextAlignmentCenter;
        _badgeLabel.layer.cornerRadius = 9.0;
        _badgeLabel.clipsToBounds = YES;
        _badgeLabel.hidden = YES;
        [self addSubview:_badgeLabel];

        _warningDot = [[UIView alloc] init];
        _warningDot.translatesAutoresizingMaskIntoConstraints = NO;
        _warningDot.backgroundColor = pl_amber();
        _warningDot.layer.cornerRadius = 4.0;
        _warningDot.hidden = YES;
        [self addSubview:_warningDot];

        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintEqualToConstant:40.0],
            [_iconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12.0],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:18.0],
            [_iconView.heightAnchor constraintEqualToConstant:18.0],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:10.0],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_badgeLabel.leadingAnchor constant:-6.0],

            [_badgeLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10.0],
            [_badgeLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_badgeLabel.heightAnchor constraintEqualToConstant:18.0],
            [_badgeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:22.0],

            [_warningDot.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12.0],
            [_warningDot.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_warningDot.widthAnchor constraintEqualToConstant:8.0],
            [_warningDot.heightAnchor constraintEqualToConstant:8.0],
        ]];
        self.activeTab = NO;
    }
    return self;
}

- (void)setActiveTab:(BOOL)activeTab {
    _activeTab = activeTab;
    self.backgroundColor = activeTab ? pl_emeraldSoft() : UIColor.clearColor;
    self.iconView.tintColor = activeTab ? pl_emerald() : pl_textSec();
    self.titleLabel.textColor = activeTab ? pl_textPrimary() : pl_textSec();
    self.badgeLabel.backgroundColor = activeTab ? pl_emerald() : pl_elevatedBg();
    self.badgeLabel.textColor = activeTab ? UIColor.whiteColor : pl_textSec();
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.72 : 1.0;
}

@end

#pragma mark - Main Pre-Launcher View Controller

@interface HorizonPreLauncherViewController () <UITextFieldDelegate, UIDocumentPickerDelegate>

// Paths
@property (nonatomic, copy) NSString *documentsDir;
@property (nonatomic, copy) NSString *serversDatPath;
@property (nonatomic, copy) NSString *optionsTxtPath;
@property (nonatomic, copy) NSString *resourcesDir;
@property (nonatomic, copy) NSString *savesDir;
@property (nonatomic, copy) NSString *resourcePacksDir;
@property (nonatomic, copy) NSString *shaderPacksDir;

// Data State
@property (nonatomic, assign) HorizonLauncherTab activeTab;
@property (nonatomic, copy) NSString *playerName;
@property (nonatomic, copy) NSArray<NSDictionary *> *servers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, HorizonPingState *> *pings;
@property (nonatomic, assign) NSUInteger pingGeneration;
@property (nonatomic, copy) NSArray<NSDictionary *> *localWorlds;
@property (nonatomic, assign) BOOL resourcesReady;
@property (nonatomic, assign) uint64_t resourcesBytes;
@property (nonatomic, assign) BOOL resourcesSizeCalculated;
@property (nonatomic, assign) BOOL increasedMemoryActive;
@property (nonatomic, assign) BOOL launching;
@property (nonatomic, assign) HorizonPickerPurpose pickerPurpose;

// Options state (options.txt)
@property (nonatomic, assign) int32_t optRenderDistance;
@property (nonatomic, assign) int32_t optMaxFps;
@property (nonatomic, assign) int32_t optGuiScale;
@property (nonatomic, assign) int32_t optFov;
@property (nonatomic, copy) NSString *optLang;

// Shell Views
@property (nonatomic, strong) NSArray<HorizonRailTabButton *> *tabButtons;
@property (nonatomic, strong) UILabel *footerAvatarLabel;
@property (nonatomic, strong) UILabel *footerNickLabel;
@property (nonatomic, strong) UILabel *footerInputLabel;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIActivityIndicatorView *launchSpinner;
@property (nonatomic, strong) UILabel *launchingLabel;

// Tab Containers
@property (nonatomic, strong) NSArray<UIScrollView *> *tabScrollViews;
@property (nonatomic, strong) UIStackView *homeStack;
@property (nonatomic, strong) UIStackView *serversStack;
@property (nonatomic, strong) UIStackView *controlsStack;
@property (nonatomic, strong) UIStackView *graphicsStack;
@property (nonatomic, strong) UIStackView *filesStack;

// Tab 1 (Home) dynamic controls
@property (nonatomic, strong) UITextField *nickField;
@property (nonatomic, strong) UILabel *nickErrorLabel;
@property (nonatomic, strong) UILabel *homeAvatarLabel;
@property (nonatomic, strong) UIView *homeQuickContainer;
@property (nonatomic, strong) UILabel *tileRenderVal;
@property (nonatomic, strong) UILabel *tileFpsVal;
@property (nonatomic, strong) UILabel *tileSchemeVal;
@property (nonatomic, strong) UILabel *tileResourcesVal;
@property (nonatomic, strong) UIImageView *tileResourcesIcon;

// Tab 3 (Controls) dynamic controls
@property (nonatomic, strong) UILabel *controlsInputPillLabel;
@property (nonatomic, strong) UIView *controlsInputPillDot;
@property (nonatomic, strong) UISegmentedControl *ctrlSchemeSeg;
@property (nonatomic, strong) UISwitch *ctrlFloatingSw;
@property (nonatomic, strong) UISwitch *ctrlAutoJumpSw;
@property (nonatomic, strong) UISlider *ctrlScaleSlider;
@property (nonatomic, strong) UILabel *ctrlScaleVal;
@property (nonatomic, strong) UISlider *ctrlOpacitySlider;
@property (nonatomic, strong) UILabel *ctrlOpacityVal;
@property (nonatomic, strong) UISlider *ctrlSensSlider;
@property (nonatomic, strong) UILabel *ctrlSensVal;
@property (nonatomic, strong) UISwitch *ctrlLeftHandSw;
@property (nonatomic, strong) UISwitch *ctrlSwapJumpSw;
@property (nonatomic, strong) UISwitch *ctrlHapticsSw;
@property (nonatomic, strong) UISwitch *ctrlGyroSw;
@property (nonatomic, strong) UISlider *ctrlGyroSlider;
@property (nonatomic, strong) UILabel *ctrlGyroVal;

// Tab 4 (Graphics) dynamic controls
@property (nonatomic, strong) NSArray<UIButton *> *presetButtons;
@property (nonatomic, strong) UISlider *gfxRenderSlider;
@property (nonatomic, strong) UILabel *gfxRenderVal;
@property (nonatomic, strong) UISegmentedControl *gfxFpsSeg;
@property (nonatomic, strong) UISegmentedControl *gfxGuiSeg;
@property (nonatomic, strong) UISlider *gfxFovSlider;
@property (nonatomic, strong) UILabel *gfxFovVal;
@property (nonatomic, strong) UISegmentedControl *gfxLangSeg;
@property (nonatomic, strong) UISwitch *skipLauncherSwitch;

// Import busy overlay
@property (nonatomic, strong) UIView *importBusyBanner;
@property (nonatomic, strong) UILabel *importBusyLabel;

@end

@implementation HorizonPreLauncherViewController

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = pl_stageBg();

    [self initPaths];
    self.pings = [NSMutableDictionary dictionary];
    self.increasedMemoryActive = pl_hasIncreasedMemoryEntitlement();
    [self loadInitialState];
    [self buildLayout];
    [self selectTab:HorizonLauncherTabHome];
    [self refreshAllUI];
    [self pingAllServers];
    [self refreshResourcesSizeAsync];

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(refreshInputStatusUI) name:GCControllerDidConnectNotification object:nil];
    [nc addObserver:self selector:@selector(refreshInputStatusUI) name:GCControllerDidDisconnectNotification object:nil];
    [nc addObserver:self selector:@selector(refreshInputStatusUI) name:GCKeyboardDidConnectNotification object:nil];
    [nc addObserver:self selector:@selector(refreshInputStatusUI) name:GCKeyboardDidDisconnectNotification object:nil];
    [nc addObserver:self selector:@selector(refreshInputStatusUI) name:GCMouseDidConnectNotification object:nil];
    [nc addObserver:self selector:@selector(refreshInputStatusUI) name:GCMouseDidDisconnectNotification object:nil];
    [nc addObserver:self selector:@selector(onKeyboardChange:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [nc addObserver:self selector:@selector(onKeyboardHide:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - Paths & State Loading

- (void)initPaths {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    self.documentsDir = paths.count > 0 ? paths.firstObject : [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    self.serversDatPath = [self.documentsDir stringByAppendingPathComponent:@"servers.dat"];
    self.optionsTxtPath = [self.documentsDir stringByAppendingPathComponent:@"options.txt"];
    self.resourcesDir = [self.documentsDir stringByAppendingPathComponent:@"resources"];
    self.savesDir = [self.documentsDir stringByAppendingPathComponent:@"saves"];
    self.resourcePacksDir = [self.documentsDir stringByAppendingPathComponent:@"resourcepacks"];
    self.shaderPacksDir = [self.documentsDir stringByAppendingPathComponent:@"shaderpacks"];
}

- (void)loadInitialState {
    // 1. Player nickname from horizon-player.txt
    char *rawNick = horizon_ios_load_player_name(self.documentsDir.UTF8String);
    if (rawNick != NULL) {
        self.playerName = [NSString stringWithUTF8String:rawNick] ?: @"Player";
        horizon_ios_free_string(rawNick);
    } else {
        self.playerName = @"Player";
    }

    // 2. servers.dat
    [self reloadServers];

    // 3. Local worlds
    [self reloadLocalWorlds];

    // 4. options.txt
    [self reloadOptions];

    // 5. Resources readiness
    NSString *manifest = [self.resourcesDir stringByAppendingPathComponent:@"horizon-resources.json"];
    self.resourcesReady = [NSFileManager.defaultManager fileExistsAtPath:manifest];
}

- (void)reloadServers {
    char *raw = horizon_ios_load_servers_json(self.serversDatPath.UTF8String);
    if (raw == NULL) {
        self.servers = @[];
        return;
    }
    NSData *data = [NSData dataWithBytes:raw length:strlen(raw)];
    horizon_ios_free_string(raw);
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    self.servers = [parsed isKindOfClass:NSArray.class] ? (NSArray *)parsed : @[];
}

- (void)reloadLocalWorlds {
    char *raw = horizon_ios_list_worlds_json(self.savesDir.UTF8String);
    if (raw == NULL) {
        self.localWorlds = @[];
        return;
    }
    NSData *data = [NSData dataWithBytes:raw length:strlen(raw)];
    horizon_ios_free_string(raw);
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    self.localWorlds = [parsed isKindOfClass:NSArray.class] ? (NSArray *)parsed : @[];
}

- (void)reloadOptions {
    self.optRenderDistance = 12;
    self.optMaxFps = 120;
    self.optGuiScale = 0;
    self.optFov = 70;
    self.optLang = @"en_us";

    char *raw = horizon_ios_load_options_json(self.optionsTxtPath.UTF8String);
    if (raw == NULL) return;
    NSData *data = [NSData dataWithBytes:raw length:strlen(raw)];
    horizon_ios_free_string(raw);
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![parsed isKindOfClass:NSDictionary.class]) return;
    NSDictionary *d = (NSDictionary *)parsed;
    if ([d[@"render_distance"] isKindOfClass:NSNumber.class]) self.optRenderDistance = [d[@"render_distance"] intValue];
    if ([d[@"max_fps"] isKindOfClass:NSNumber.class])         self.optMaxFps = [d[@"max_fps"] intValue];
    if ([d[@"gui_scale"] isKindOfClass:NSNumber.class])       self.optGuiScale = [d[@"gui_scale"] intValue];
    if ([d[@"fov"] isKindOfClass:NSNumber.class])             self.optFov = [d[@"fov"] intValue];
    if ([d[@"lang"] isKindOfClass:NSString.class])            self.optLang = d[@"lang"];
}

- (void)saveOptionsToDisk {
    horizon_ios_save_options(
        self.optionsTxtPath.UTF8String,
        self.optRenderDistance,
        self.optMaxFps,
        self.optGuiScale,
        self.optFov,
        self.optLang.UTF8String
    );
}

- (void)refreshResourcesSizeAsync {
    NSString *manifest = [self.resourcesDir stringByAppendingPathComponent:@"horizon-resources.json"];
    self.resourcesReady = [NSFileManager.defaultManager fileExistsAtPath:manifest];
    if (!self.resourcesReady) {
        self.resourcesBytes = 0;
        self.resourcesSizeCalculated = YES;
        [self updateReadinessUI];
        [self rebuildFilesTab];
        return;
    }
    NSString *dir = self.resourcesDir;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        uint64_t bytes = pl_directorySize(dir);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = weakSelf;
            if (s == nil) return;
            s.resourcesBytes = bytes;
            s.resourcesSizeCalculated = YES;
            [s updateReadinessUI];
            [s rebuildFilesTab];
        });
    });
}

#pragma mark - Background Server Pinging

- (void)pingAllServers {
    self.pingGeneration += 1;
    NSUInteger gen = self.pingGeneration;
    [self.pings removeAllObjects];

    NSArray<NSDictionary *> *snapshot = [self.servers copy];
    for (NSDictionary *srv in snapshot) {
        NSString *ip = srv[@"ip"] ?: @"";
        if (ip.length == 0) continue;
        HorizonPingState *st = [[HorizonPingState alloc] init];
        st.loading = YES;
        st.playersOnline = -1;
        st.playersMax = -1;
        self.pings[ip] = st;
    }
    [self rebuildHomeQuickSection];
    [self rebuildServersTab];

    __weak typeof(self) weakSelf = self;
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    for (NSDictionary *srv in snapshot) {
        NSString *ip = srv[@"ip"] ?: @"";
        if (ip.length == 0) continue;
        dispatch_async(q, ^{
            char *raw = horizon_ios_ping_server_json(ip.UTF8String, 4000);
            HorizonPingState *res = [[HorizonPingState alloc] init];
            res.loading = NO;
            res.playersOnline = -1;
            res.playersMax = -1;
            if (raw != NULL) {
                NSData *data = [NSData dataWithBytes:raw length:strlen(raw)];
                horizon_ios_free_string(raw);
                id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([parsed isKindOfClass:NSDictionary.class]) {
                    NSDictionary *d = (NSDictionary *)parsed;
                    res.online = [d[@"online"] boolValue];
                    res.latencyMs = [d[@"latency_ms"] unsignedLongLongValue];
                    res.playersOnline = [d[@"players_online"] longLongValue];
                    res.playersMax = [d[@"players_max"] longLongValue];
                    res.version = [d[@"version"] isKindOfClass:NSString.class] ? d[@"version"] : @"";
                    res.motd = [d[@"motd"] isKindOfClass:NSString.class] ? d[@"motd"] : @"";
                    res.errorText = [d[@"error"] isKindOfClass:NSString.class] ? d[@"error"] : @"";
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) s = weakSelf;
                if (s == nil || s.pingGeneration != gen) return;
                s.pings[ip] = res;
                [s rebuildHomeQuickSection];
                [s rebuildServersTab];
            });
        });
    }
}

#pragma mark - Root Split-View Layout

- (void)buildLayout {
    // Left Navigation Rail (fills behind leading safe area, content inset by safeAreaLayoutGuide)
    UIView *railBg = [[UIView alloc] init];
    railBg.translatesAutoresizingMaskIntoConstraints = NO;
    railBg.backgroundColor = pl_railBg();
    [self.view addSubview:railBg];

    UIView *railDivider = [[UIView alloc] init];
    railDivider.translatesAutoresizingMaskIntoConstraints = NO;
    railDivider.backgroundColor = pl_hairline();
    [self.view addSubview:railDivider];

    UIView *railContent = [[UIView alloc] init];
    railContent.translatesAutoresizingMaskIntoConstraints = NO;
    [railBg addSubview:railContent];

    // Right Stage + Bottom Action Bar
    UIView *stageContainer = [[UIView alloc] init];
    stageContainer.translatesAutoresizingMaskIntoConstraints = NO;
    stageContainer.backgroundColor = pl_stageBg();
    [self.view addSubview:stageContainer];

    UIView *bottomBar = [[UIView alloc] init];
    bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
    bottomBar.backgroundColor = pl_rgb(17, 22, 29, 1.0);
    [self.view addSubview:bottomBar];

    UIView *bottomDivider = [[UIView alloc] init];
    bottomDivider.translatesAutoresizingMaskIntoConstraints = NO;
    bottomDivider.backgroundColor = pl_hairline();
    [bottomBar addSubview:bottomDivider];

    [NSLayoutConstraint activateConstraints:@[
        [railBg.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [railBg.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [railBg.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [railBg.trailingAnchor constraintEqualToAnchor:railContent.trailingAnchor],

        [railContent.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [railContent.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [railContent.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [railContent.widthAnchor constraintEqualToConstant:188.0],

        [railDivider.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [railDivider.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [railDivider.leadingAnchor constraintEqualToAnchor:railBg.trailingAnchor],
        [railDivider.widthAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],

        [stageContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [stageContainer.leadingAnchor constraintEqualToAnchor:railDivider.trailingAnchor],
        [stageContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stageContainer.bottomAnchor constraintEqualToAnchor:bottomBar.topAnchor],

        [bottomBar.leadingAnchor constraintEqualToAnchor:railDivider.trailingAnchor],
        [bottomBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bottomBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [bottomDivider.topAnchor constraintEqualToAnchor:bottomBar.topAnchor],
        [bottomDivider.leadingAnchor constraintEqualToAnchor:bottomBar.leadingAnchor],
        [bottomDivider.trailingAnchor constraintEqualToAnchor:bottomBar.trailingAnchor],
        [bottomDivider.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],
    ]];

    [self buildRailInside:railContent];
    [self buildBottomBarInside:bottomBar];
    [self buildTabStagesInside:stageContainer];
}

- (void)buildRailInside:(UIView *)rail {
    // Brand Header
    UIView *brandRow = [[UIView alloc] init];
    brandRow.translatesAutoresizingMaskIntoConstraints = NO;
    [rail addSubview:brandRow];

    UIView *logoBadge = [[UIView alloc] init];
    logoBadge.translatesAutoresizingMaskIntoConstraints = NO;
    logoBadge.backgroundColor = pl_emeraldSoft();
    logoBadge.layer.cornerRadius = 9.0;
    logoBadge.layer.borderWidth = 1.0;
    logoBadge.layer.borderColor = pl_rgb(51, 189, 102, 0.32).CGColor;
    [brandRow addSubview:logoBadge];

    UIImageView *cubeIcon = [[UIImageView alloc] initWithImage:[HorizonIcons iconForKind:HorizonIconHorizonCube pointSize:20.0]];
    cubeIcon.translatesAutoresizingMaskIntoConstraints = NO;
    cubeIcon.tintColor = pl_emerald();
    [logoBadge addSubview:cubeIcon];

    UILabel *brandTitle = [[UILabel alloc] init];
    brandTitle.translatesAutoresizingMaskIntoConstraints = NO;
    brandTitle.text = @"Horizon";
    brandTitle.font = [UIFont systemFontOfSize:16.5 weight:UIFontWeightBold];
    brandTitle.textColor = pl_textPrimary();
    [brandRow addSubview:brandTitle];

    UILabel *brandSub = [[UILabel alloc] init];
    brandSub.translatesAutoresizingMaskIntoConstraints = NO;
    brandSub.text = @"26.3 · iOS";
    brandSub.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightMedium];
    brandSub.textColor = pl_textMuted();
    [brandRow addSubview:brandSub];

    // 5 Tab Buttons
    UIStackView *navStack = [[UIStackView alloc] init];
    navStack.translatesAutoresizingMaskIntoConstraints = NO;
    navStack.axis = UILayoutConstraintAxisVertical;
    navStack.spacing = 4.0;
    [rail addSubview:navStack];

    HorizonRailTabButton *b0 = [[HorizonRailTabButton alloc] initWithTitle:@"Главная" icon:HorizonIconHome];
    HorizonRailTabButton *b1 = [[HorizonRailTabButton alloc] initWithTitle:@"Серверы" icon:HorizonIconServers];
    HorizonRailTabButton *b2 = [[HorizonRailTabButton alloc] initWithTitle:@"Управление" icon:HorizonIconGamepad];
    HorizonRailTabButton *b3 = [[HorizonRailTabButton alloc] initWithTitle:@"Графика" icon:HorizonIconSliders];
    HorizonRailTabButton *b4 = [[HorizonRailTabButton alloc] initWithTitle:@"Файлы" icon:HorizonIconFolder];
    self.tabButtons = @[b0, b1, b2, b3, b4];
    for (NSUInteger i = 0; i < self.tabButtons.count; i++) {
        HorizonRailTabButton *btn = self.tabButtons[i];
        btn.tag = (NSInteger)i;
        [btn addTarget:self action:@selector(onTabButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [navStack addArrangedSubview:btn];
    }

    // Footer Profile Chip
    UIView *footerChip = [[UIView alloc] init];
    footerChip.translatesAutoresizingMaskIntoConstraints = NO;
    footerChip.backgroundColor = pl_cardBg();
    footerChip.layer.cornerRadius = 11.0;
    footerChip.layer.borderWidth = 1.0;
    footerChip.layer.borderColor = pl_hairline().CGColor;
    [rail addSubview:footerChip];

    UIView *avatarCircle = [[UIView alloc] init];
    avatarCircle.translatesAutoresizingMaskIntoConstraints = NO;
    avatarCircle.backgroundColor = pl_emeraldSoft();
    avatarCircle.layer.cornerRadius = 15.0;
    [footerChip addSubview:avatarCircle];

    self.footerAvatarLabel = [[UILabel alloc] init];
    self.footerAvatarLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.footerAvatarLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightBold];
    self.footerAvatarLabel.textColor = pl_emerald();
    self.footerAvatarLabel.textAlignment = NSTextAlignmentCenter;
    [avatarCircle addSubview:self.footerAvatarLabel];

    self.footerNickLabel = [[UILabel alloc] init];
    self.footerNickLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.footerNickLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    self.footerNickLabel.textColor = pl_textPrimary();
    self.footerNickLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [footerChip addSubview:self.footerNickLabel];

    self.footerInputLabel = [[UILabel alloc] init];
    self.footerInputLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.footerInputLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
    self.footerInputLabel.textColor = pl_textMuted();
    self.footerInputLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [footerChip addSubview:self.footerInputLabel];

    [NSLayoutConstraint activateConstraints:@[
        [brandRow.topAnchor constraintEqualToAnchor:rail.topAnchor constant:12.0],
        [brandRow.leadingAnchor constraintEqualToAnchor:rail.leadingAnchor constant:12.0],
        [brandRow.trailingAnchor constraintEqualToAnchor:rail.trailingAnchor constant:-12.0],
        [brandRow.heightAnchor constraintEqualToConstant:38.0],

        [logoBadge.leadingAnchor constraintEqualToAnchor:brandRow.leadingAnchor],
        [logoBadge.centerYAnchor constraintEqualToAnchor:brandRow.centerYAnchor],
        [logoBadge.widthAnchor constraintEqualToConstant:34.0],
        [logoBadge.heightAnchor constraintEqualToConstant:34.0],

        [cubeIcon.centerXAnchor constraintEqualToAnchor:logoBadge.centerXAnchor],
        [cubeIcon.centerYAnchor constraintEqualToAnchor:logoBadge.centerYAnchor],
        [cubeIcon.widthAnchor constraintEqualToConstant:20.0],
        [cubeIcon.heightAnchor constraintEqualToConstant:20.0],

        [brandTitle.leadingAnchor constraintEqualToAnchor:logoBadge.trailingAnchor constant:10.0],
        [brandTitle.topAnchor constraintEqualToAnchor:brandRow.topAnchor constant:1.0],
        [brandSub.leadingAnchor constraintEqualToAnchor:brandTitle.leadingAnchor],
        [brandSub.topAnchor constraintEqualToAnchor:brandTitle.bottomAnchor constant:1.0],

        [navStack.topAnchor constraintEqualToAnchor:brandRow.bottomAnchor constant:14.0],
        [navStack.leadingAnchor constraintEqualToAnchor:rail.leadingAnchor constant:10.0],
        [navStack.trailingAnchor constraintEqualToAnchor:rail.trailingAnchor constant:-10.0],

        [footerChip.leadingAnchor constraintEqualToAnchor:rail.leadingAnchor constant:10.0],
        [footerChip.trailingAnchor constraintEqualToAnchor:rail.trailingAnchor constant:-10.0],
        [footerChip.bottomAnchor constraintEqualToAnchor:rail.bottomAnchor constant:-10.0],
        [footerChip.heightAnchor constraintEqualToConstant:48.0],
        [footerChip.topAnchor constraintGreaterThanOrEqualToAnchor:navStack.bottomAnchor constant:8.0],

        [avatarCircle.leadingAnchor constraintEqualToAnchor:footerChip.leadingAnchor constant:9.0],
        [avatarCircle.centerYAnchor constraintEqualToAnchor:footerChip.centerYAnchor],
        [avatarCircle.widthAnchor constraintEqualToConstant:30.0],
        [avatarCircle.heightAnchor constraintEqualToConstant:30.0],

        [self.footerAvatarLabel.centerXAnchor constraintEqualToAnchor:avatarCircle.centerXAnchor],
        [self.footerAvatarLabel.centerYAnchor constraintEqualToAnchor:avatarCircle.centerYAnchor],

        [self.footerNickLabel.leadingAnchor constraintEqualToAnchor:avatarCircle.trailingAnchor constant:9.0],
        [self.footerNickLabel.trailingAnchor constraintEqualToAnchor:footerChip.trailingAnchor constant:-8.0],
        [self.footerNickLabel.topAnchor constraintEqualToAnchor:footerChip.topAnchor constant:8.0],

        [self.footerInputLabel.leadingAnchor constraintEqualToAnchor:self.footerNickLabel.leadingAnchor],
        [self.footerInputLabel.trailingAnchor constraintEqualToAnchor:footerChip.trailingAnchor constant:-8.0],
        [self.footerInputLabel.topAnchor constraintEqualToAnchor:self.footerNickLabel.bottomAnchor constant:1.0],
    ]];
}

- (void)buildBottomBarInside:(UIView *)bar {
    UIView *content = [[UIView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:content];

    self.statusDot = [[UIView alloc] init];
    self.statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDot.layer.cornerRadius = 4.0;
    [content addSubview:self.statusDot];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    self.statusLabel.textColor = pl_textSec();
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [content addSubview:self.statusLabel];

    self.playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.playButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.playButton.backgroundColor = pl_emerald();
    self.playButton.layer.cornerRadius = 10.0;
    [self.playButton setImage:[HorizonIcons iconForKind:HorizonIconPlay pointSize:15.0] forState:UIControlStateNormal];
    [self.playButton setTitle:@"Играть" forState:UIControlStateNormal];
    [self.playButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.playButton.tintColor = UIColor.whiteColor;
    self.playButton.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightBold];
    self.playButton.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 7);
    self.playButton.contentEdgeInsets = UIEdgeInsetsMake(9.0, 22.0, 9.0, 22.0);
    [self.playButton addTarget:self action:@selector(onPlayButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:self.playButton];

    self.launchSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.launchSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchSpinner.color = pl_emerald();
    self.launchSpinner.hidesWhenStopped = YES;
    [content addSubview:self.launchSpinner];

    self.launchingLabel = [[UILabel alloc] init];
    self.launchingLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchingLabel.text = @"Запуск Horizon…";
    self.launchingLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
    self.launchingLabel.textColor = pl_textPrimary();
    self.launchingLabel.hidden = YES;
    [content addSubview:self.launchingLabel];

    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:16.0],
        [content.trailingAnchor constraintEqualToAnchor:bar.safeAreaLayoutGuide.trailingAnchor constant:-16.0],
        [content.bottomAnchor constraintEqualToAnchor:bar.safeAreaLayoutGuide.bottomAnchor],
        [content.heightAnchor constraintEqualToConstant:56.0],

        [self.statusDot.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.statusDot.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [self.statusDot.widthAnchor constraintEqualToConstant:8.0],
        [self.statusDot.heightAnchor constraintEqualToConstant:8.0],

        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.statusDot.trailingAnchor constant:8.0],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.playButton.leadingAnchor constant:-12.0],

        [self.playButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [self.playButton.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [self.playButton.heightAnchor constraintEqualToConstant:38.0],

        [self.launchingLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [self.launchingLabel.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [self.launchSpinner.trailingAnchor constraintEqualToAnchor:self.launchingLabel.leadingAnchor constant:-10.0],
        [self.launchSpinner.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
    ]];
}

- (void)buildTabStagesInside:(UIView *)container {
    NSMutableArray<UIScrollView *> *scrolls = [NSMutableArray array];
    NSMutableArray<UIStackView *> *stacks = [NSMutableArray array];
    for (int i = 0; i < 5; i++) {
        UIScrollView *sv = [[UIScrollView alloc] init];
        sv.translatesAutoresizingMaskIntoConstraints = NO;
        sv.alwaysBounceVertical = YES;
        sv.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
        sv.hidden = YES;
        [container addSubview:sv];

        UIStackView *st = [[UIStackView alloc] init];
        st.translatesAutoresizingMaskIntoConstraints = NO;
        st.axis = UILayoutConstraintAxisVertical;
        st.spacing = 12.0;
        [sv addSubview:st];

        [NSLayoutConstraint activateConstraints:@[
            [sv.topAnchor constraintEqualToAnchor:container.topAnchor],
            [sv.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [sv.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
            [sv.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],

            [st.topAnchor constraintEqualToAnchor:sv.contentLayoutGuide.topAnchor constant:16.0],
            [st.leadingAnchor constraintEqualToAnchor:sv.safeAreaLayoutGuide.leadingAnchor constant:18.0],
            [st.trailingAnchor constraintEqualToAnchor:sv.safeAreaLayoutGuide.trailingAnchor constant:-18.0],
            [st.bottomAnchor constraintEqualToAnchor:sv.contentLayoutGuide.bottomAnchor constant:-20.0],
        ]];
        [scrolls addObject:sv];
        [stacks addObject:st];
    }

    self.tabScrollViews = scrolls;
    self.homeStack = stacks[0];
    self.serversStack = stacks[1];
    self.controlsStack = stacks[2];
    self.graphicsStack = stacks[3];
    self.filesStack = stacks[4];

    [self buildHomeTab];
    [self buildControlsTab];
    [self buildGraphicsTab];
    // Servers & Files tabs are data-driven and populated in rebuild* methods.

    // Import progress banner floating at top of stage
    self.importBusyBanner = [[UIView alloc] init];
    self.importBusyBanner.translatesAutoresizingMaskIntoConstraints = NO;
    self.importBusyBanner.backgroundColor = pl_rgb(27, 34, 44, 0.96);
    self.importBusyBanner.layer.cornerRadius = 10.0;
    self.importBusyBanner.layer.borderWidth = 1.0;
    self.importBusyBanner.layer.borderColor = pl_emerald().CGColor;
    self.importBusyBanner.hidden = YES;
    [container addSubview:self.importBusyBanner];

    UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    sp.translatesAutoresizingMaskIntoConstraints = NO;
    sp.color = pl_emerald();
    [sp startAnimating];
    [self.importBusyBanner addSubview:sp];

    self.importBusyLabel = [[UILabel alloc] init];
    self.importBusyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.importBusyLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    self.importBusyLabel.textColor = pl_textPrimary();
    [self.importBusyBanner addSubview:self.importBusyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.importBusyBanner.topAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.topAnchor constant:12.0],
        [self.importBusyBanner.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [self.importBusyBanner.heightAnchor constraintEqualToConstant:40.0],
        [sp.leadingAnchor constraintEqualToAnchor:self.importBusyBanner.leadingAnchor constant:14.0],
        [sp.centerYAnchor constraintEqualToAnchor:self.importBusyBanner.centerYAnchor],
        [self.importBusyLabel.leadingAnchor constraintEqualToAnchor:sp.trailingAnchor constant:10.0],
        [self.importBusyLabel.trailingAnchor constraintEqualToAnchor:self.importBusyBanner.trailingAnchor constant:-16.0],
        [self.importBusyLabel.centerYAnchor constraintEqualToAnchor:self.importBusyBanner.centerYAnchor],
    ]];
}

#pragma mark - Reusable UI Builders

- (UILabel *)pageHeaderLabel:(NSString *)title {
    UILabel *l = [[UILabel alloc] init];
    l.text = title;
    l.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
    l.textColor = pl_textPrimary();
    return l;
}

- (UILabel *)sectionCaption:(NSString *)title {
    UILabel *l = [[UILabel alloc] init];
    l.text = title;
    l.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightBold];
    l.textColor = pl_textMuted();
    return l;
}

- (UIView *)insetCard {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = pl_cardBg();
    v.layer.cornerRadius = 12.0;
    v.layer.borderWidth = 1.0;
    v.layer.borderColor = pl_hairline().CGColor;
    return v;
}

- (UISwitch *)makeToggleRow:(NSString *)title subtitle:(nullable NSString *)subtitle action:(SEL)action inStack:(UIStackView *)stack {
    UIView *row = [self insetCard];
    UILabel *lbl = [[UILabel alloc] init];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.text = title;
    lbl.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    lbl.textColor = pl_textPrimary();
    [row addSubview:lbl];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    sw.onTintColor = pl_emerald();
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [row addSubview:sw];

    if (subtitle.length > 0) {
        UILabel *sub = [[UILabel alloc] init];
        sub.translatesAutoresizingMaskIntoConstraints = NO;
        sub.text = subtitle;
        sub.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
        sub.textColor = pl_textMuted();
        sub.numberOfLines = 0;
        [row addSubview:sub];

        [NSLayoutConstraint activateConstraints:@[
            [lbl.topAnchor constraintEqualToAnchor:row.topAnchor constant:10.0],
            [lbl.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14.0],
            [lbl.trailingAnchor constraintLessThanOrEqualToAnchor:sw.leadingAnchor constant:-10.0],
            [sub.topAnchor constraintEqualToAnchor:lbl.bottomAnchor constant:2.0],
            [sub.leadingAnchor constraintEqualToAnchor:lbl.leadingAnchor],
            [sub.trailingAnchor constraintLessThanOrEqualToAnchor:sw.leadingAnchor constant:-10.0],
            [sub.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10.0],
            [sw.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14.0],
            [sw.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [row.heightAnchor constraintEqualToConstant:46.0],
            [lbl.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14.0],
            [lbl.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [lbl.trailingAnchor constraintLessThanOrEqualToAnchor:sw.leadingAnchor constant:-10.0],
            [sw.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14.0],
            [sw.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        ]];
    }
    [stack addArrangedSubview:row];
    return sw;
}

- (UISlider *)makeSliderRow:(NSString *)title min:(float)minVal max:(float)maxVal valueLabel:(UILabel **)outVal action:(SEL)action inStack:(UIStackView *)stack {
    UIView *card = [self insetCard];
    UILabel *lbl = [[UILabel alloc] init];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.text = title;
    lbl.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
    lbl.textColor = pl_textPrimary();
    [card addSubview:lbl];

    UILabel *val = [[UILabel alloc] init];
    val.translatesAutoresizingMaskIntoConstraints = NO;
    val.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightSemibold];
    val.textColor = pl_rgb(122, 238, 164, 1.0);
    [card addSubview:val];

    UISlider *sl = [[UISlider alloc] init];
    sl.translatesAutoresizingMaskIntoConstraints = NO;
    sl.minimumValue = minVal;
    sl.maximumValue = maxVal;
    sl.minimumTrackTintColor = pl_emerald();
    sl.maximumTrackTintColor = pl_elevatedBg();
    [sl addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [card addSubview:sl];

    [NSLayoutConstraint activateConstraints:@[
        [lbl.topAnchor constraintEqualToAnchor:card.topAnchor constant:10.0],
        [lbl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
        [val.centerYAnchor constraintEqualToAnchor:lbl.centerYAnchor],
        [val.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
        [sl.topAnchor constraintEqualToAnchor:lbl.bottomAnchor constant:4.0],
        [sl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
        [sl.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
        [sl.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-10.0],
    ]];
    [stack addArrangedSubview:card];
    if (outVal != NULL) *outVal = val;
    return sl;
}

- (UISegmentedControl *)styledSegmentedControlWithItems:(NSArray<NSString *> *)items action:(SEL)action {
    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:items];
    seg.selectedSegmentTintColor = pl_emerald();
    seg.backgroundColor = pl_cardBg();
    [seg setTitleTextAttributes:@{
        NSForegroundColorAttributeName: pl_textSec(),
        NSFontAttributeName: [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium],
    } forState:UIControlStateNormal];
    [seg setTitleTextAttributes:@{
        NSForegroundColorAttributeName: UIColor.whiteColor,
        NSFontAttributeName: [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold],
    } forState:UIControlStateSelected];
    [seg addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    return seg;
}

#pragma mark - Tab 1: Главная (Home)

- (void)buildHomeTab {
    [self.homeStack addArrangedSubview:[self pageHeaderLabel:@"Главная"]];

    // Profile card
    UIView *profileCard = [self insetCard];
    UIView *avatar = [[UIView alloc] init];
    avatar.translatesAutoresizingMaskIntoConstraints = NO;
    avatar.backgroundColor = pl_emeraldSoft();
    avatar.layer.cornerRadius = 20.0;
    avatar.layer.borderWidth = 1.0;
    avatar.layer.borderColor = pl_rgb(51, 189, 102, 0.35).CGColor;
    [profileCard addSubview:avatar];

    self.homeAvatarLabel = [[UILabel alloc] init];
    self.homeAvatarLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.homeAvatarLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightBold];
    self.homeAvatarLabel.textColor = pl_emerald();
    [avatar addSubview:self.homeAvatarLabel];

    UILabel *nickCaption = [[UILabel alloc] init];
    nickCaption.translatesAutoresizingMaskIntoConstraints = NO;
    nickCaption.text = @"НИКНЕЙМ ИГРОКА (ОФЛАЙН)";
    nickCaption.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightBold];
    nickCaption.textColor = pl_textMuted();
    [profileCard addSubview:nickCaption];

    self.nickField = [[UITextField alloc] init];
    self.nickField.translatesAutoresizingMaskIntoConstraints = NO;
    self.nickField.backgroundColor = pl_elevatedBg();
    self.nickField.textColor = pl_textPrimary();
    self.nickField.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    self.nickField.layer.cornerRadius = 8.0;
    self.nickField.layer.borderWidth = 1.0;
    self.nickField.layer.borderColor = pl_hairline().CGColor;
    self.nickField.tintColor = pl_emerald();
    self.nickField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.nickField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.nickField.returnKeyType = UIReturnKeyDone;
    self.nickField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 1)];
    self.nickField.leftViewMode = UITextFieldViewModeAlways;
    self.nickField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.nickField.delegate = self;
    [self.nickField addTarget:self action:@selector(onNickEdited) forControlEvents:UIControlEventEditingChanged];
    [self.nickField addTarget:self action:@selector(onNickCommit) forControlEvents:UIControlEventEditingDidEnd];
    [profileCard addSubview:self.nickField];

    self.nickErrorLabel = [[UILabel alloc] init];
    self.nickErrorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nickErrorLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
    self.nickErrorLabel.textColor = pl_amber();
    self.nickErrorLabel.hidden = YES;
    [profileCard addSubview:self.nickErrorLabel];

    [NSLayoutConstraint activateConstraints:@[
        [avatar.leadingAnchor constraintEqualToAnchor:profileCard.leadingAnchor constant:14.0],
        [avatar.centerYAnchor constraintEqualToAnchor:profileCard.centerYAnchor],
        [avatar.widthAnchor constraintEqualToConstant:40.0],
        [avatar.heightAnchor constraintEqualToConstant:40.0],

        [self.homeAvatarLabel.centerXAnchor constraintEqualToAnchor:avatar.centerXAnchor],
        [self.homeAvatarLabel.centerYAnchor constraintEqualToAnchor:avatar.centerYAnchor],

        [nickCaption.topAnchor constraintEqualToAnchor:profileCard.topAnchor constant:10.0],
        [nickCaption.leadingAnchor constraintEqualToAnchor:avatar.trailingAnchor constant:12.0],

        [self.nickField.topAnchor constraintEqualToAnchor:nickCaption.bottomAnchor constant:5.0],
        [self.nickField.leadingAnchor constraintEqualToAnchor:nickCaption.leadingAnchor],
        [self.nickField.trailingAnchor constraintEqualToAnchor:profileCard.trailingAnchor constant:-14.0],
        [self.nickField.heightAnchor constraintEqualToConstant:36.0],

        [self.nickErrorLabel.topAnchor constraintEqualToAnchor:self.nickField.bottomAnchor constant:4.0],
        [self.nickErrorLabel.leadingAnchor constraintEqualToAnchor:self.nickField.leadingAnchor],
        [self.nickErrorLabel.trailingAnchor constraintEqualToAnchor:self.nickField.trailingAnchor],
        [self.nickErrorLabel.bottomAnchor constraintEqualToAnchor:profileCard.bottomAnchor constant:-10.0],
    ]];
    [self.homeStack addArrangedSubview:profileCard];

    // Quick 1-Tap Launch Section
    [self.homeStack addArrangedSubview:[self sectionCaption:@"БЫСТРЫЙ ВХОД В 1 ТАП"]];
    UIStackView *quickStack = [[UIStackView alloc] init];
    quickStack.axis = UILayoutConstraintAxisVertical;
    quickStack.spacing = 8.0;
    self.homeQuickContainer = quickStack;
    [self.homeStack addArrangedSubview:quickStack];

    // 4 Pre-flight Summary Tiles (2x2 grid)
    [self.homeStack addArrangedSubview:[self sectionCaption:@"ПАРАМЕТРЫ ПЕРЕД ЗАПУСКОМ"]];

    UILabel *v1 = nil, *v2 = nil, *v3 = nil, *v4 = nil;
    UIImageView *i4 = nil;
    UIControl *t1 = [self summaryTileTitle:@"Дальность" icon:HorizonIconSliders targetTab:HorizonLauncherTabGraphics valueLabel:&v1 iconView:NULL];
    UIControl *t2 = [self summaryTileTitle:@"Лимит FPS" icon:HorizonIconRefresh targetTab:HorizonLauncherTabGraphics valueLabel:&v2 iconView:NULL];
    UIControl *t3 = [self summaryTileTitle:@"Схема" icon:HorizonIconGamepad targetTab:HorizonLauncherTabControls valueLabel:&v3 iconView:NULL];
    UIControl *t4 = [self summaryTileTitle:@"Ресурсы" icon:HorizonIconCheck targetTab:HorizonLauncherTabFiles valueLabel:&v4 iconView:&i4];
    self.tileRenderVal = v1;
    self.tileFpsVal = v2;
    self.tileSchemeVal = v3;
    self.tileResourcesVal = v4;
    self.tileResourcesIcon = i4;

    UIStackView *rowA = [[UIStackView alloc] initWithArrangedSubviews:@[t1, t2]];
    rowA.axis = UILayoutConstraintAxisHorizontal;
    rowA.spacing = 10.0;
    rowA.distribution = UIStackViewDistributionFillEqually;

    UIStackView *rowB = [[UIStackView alloc] initWithArrangedSubviews:@[t3, t4]];
    rowB.axis = UILayoutConstraintAxisHorizontal;
    rowB.spacing = 10.0;
    rowB.distribution = UIStackViewDistributionFillEqually;

    [self.homeStack addArrangedSubview:rowA];
    [self.homeStack addArrangedSubview:rowB];
}

- (UIControl *)summaryTileTitle:(NSString *)title
                           icon:(HorizonIconKind)icon
                      targetTab:(HorizonLauncherTab)tab
                     valueLabel:(UILabel **)outVal
                       iconView:(UIImageView **)outIcon {
    UIControl *tile = [[UIControl alloc] init];
    tile.backgroundColor = pl_cardBg();
    tile.layer.cornerRadius = 11.0;
    tile.layer.borderWidth = 1.0;
    tile.layer.borderColor = pl_hairline().CGColor;
    tile.tag = (NSInteger)tab;
    [tile addTarget:self action:@selector(onSummaryTileTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIImageView *iv = [[UIImageView alloc] initWithImage:[HorizonIcons iconForKind:icon pointSize:16.0]];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.tintColor = pl_emerald();
    [tile addSubview:iv];

    UILabel *tLbl = [[UILabel alloc] init];
    tLbl.translatesAutoresizingMaskIntoConstraints = NO;
    tLbl.text = title;
    tLbl.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
    tLbl.textColor = pl_textMuted();
    [tile addSubview:tLbl];

    UILabel *vLbl = [[UILabel alloc] init];
    vLbl.translatesAutoresizingMaskIntoConstraints = NO;
    vLbl.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightBold];
    vLbl.textColor = pl_textPrimary();
    [tile addSubview:vLbl];

    UIImageView *chev = [[UIImageView alloc] initWithImage:[HorizonIcons iconForKind:HorizonIconChevronRight pointSize:14.0]];
    chev.translatesAutoresizingMaskIntoConstraints = NO;
    chev.tintColor = pl_textMuted();
    [tile addSubview:chev];

    [NSLayoutConstraint activateConstraints:@[
        [tile.heightAnchor constraintEqualToConstant:58.0],
        [iv.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:12.0],
        [iv.topAnchor constraintEqualToAnchor:tile.topAnchor constant:11.0],
        [iv.widthAnchor constraintEqualToConstant:16.0],
        [iv.heightAnchor constraintEqualToConstant:16.0],

        [tLbl.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:6.0],
        [tLbl.centerYAnchor constraintEqualToAnchor:iv.centerYAnchor],

        [vLbl.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:12.0],
        [vLbl.trailingAnchor constraintLessThanOrEqualToAnchor:chev.leadingAnchor constant:-6.0],
        [vLbl.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor constant:-10.0],

        [chev.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-10.0],
        [chev.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor],
        [chev.widthAnchor constraintEqualToConstant:14.0],
        [chev.heightAnchor constraintEqualToConstant:14.0],
    ]];

    if (outVal != NULL) *outVal = vLbl;
    if (outIcon != NULL) *outIcon = iv;
    return tile;
}

- (nullable NSDictionary *)topQuickServer {
    if (self.servers.count == 0) return nil;
    NSString *last = HorizonSettings.shared.lastQuickServerAddress;
    if (last.length > 0) {
        NSString *lastNorm = [HorizonAutoLoginStore normalizeAddress:last];
        for (NSDictionary *srv in self.servers) {
            NSString *norm = srv[@"normalized"] ?: @"";
            if (lastNorm != nil && [norm isEqualToString:lastNorm]) {
                return srv;
            }
        }
    }
    return self.servers.firstObject;
}

- (void)rebuildHomeQuickSection {
    UIStackView *stack = (UIStackView *)self.homeQuickContainer;
    for (UIView *sub in [stack.arrangedSubviews copy]) {
        [stack removeArrangedSubview:sub];
        [sub removeFromSuperview];
    }

    NSDictionary *topSrv = [self topQuickServer];
    if (topSrv != nil) {
        [stack addArrangedSubview:[self buildServerCardForDict:topSrv index:-1 compactQuick:YES]];
    } else {
        UIView *emptySrv = [self insetCard];
        UILabel *lbl = [[UILabel alloc] init];
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        lbl.text = @"Добавьте сервер для входа в 1 тап и автологина";
        lbl.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
        lbl.textColor = pl_textSec();
        [emptySrv addSubview:lbl];

        UIButton *addBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        addBtn.translatesAutoresizingMaskIntoConstraints = NO;
        [addBtn setTitle:@"+ Сервер" forState:UIControlStateNormal];
        [addBtn setTitleColor:pl_emerald() forState:UIControlStateNormal];
        addBtn.backgroundColor = pl_emeraldSoft();
        addBtn.layer.cornerRadius = 8.0;
        addBtn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        addBtn.contentEdgeInsets = UIEdgeInsetsMake(6.0, 12.0, 6.0, 12.0);
        [addBtn addTarget:self action:@selector(onAddServerTapped) forControlEvents:UIControlEventTouchUpInside];
        [emptySrv addSubview:addBtn];

        [NSLayoutConstraint activateConstraints:@[
            [emptySrv.heightAnchor constraintEqualToConstant:52.0],
            [lbl.leadingAnchor constraintEqualToAnchor:emptySrv.leadingAnchor constant:14.0],
            [lbl.centerYAnchor constraintEqualToAnchor:emptySrv.centerYAnchor],
            [lbl.trailingAnchor constraintLessThanOrEqualToAnchor:addBtn.leadingAnchor constant:-10.0],
            [addBtn.trailingAnchor constraintEqualToAnchor:emptySrv.trailingAnchor constant:-12.0],
            [addBtn.centerYAnchor constraintEqualToAnchor:emptySrv.centerYAnchor],
        ]];
        [stack addArrangedSubview:emptySrv];
    }

    NSDictionary *topWorld = self.localWorlds.firstObject;
    if (topWorld != nil) {
        [stack addArrangedSubview:[self buildWorldCardForDict:topWorld]];
    }
}

#pragma mark - Tab 2: Серверы & Локальные миры

- (void)rebuildServersTab {
    for (UIView *sub in [self.serversStack.arrangedSubviews copy]) {
        [self.serversStack removeArrangedSubview:sub];
        [sub removeFromSuperview];
    }

    // Header bar with Refresh + Add Server
    UIView *hdr = [[UIView alloc] init];
    UILabel *title = [self pageHeaderLabel:@"Серверы"];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [hdr addSubview:title];

    UIButton *refreshBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    refreshBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [refreshBtn setImage:[HorizonIcons iconForKind:HorizonIconRefresh pointSize:15.0] forState:UIControlStateNormal];
    refreshBtn.tintColor = pl_textSec();
    refreshBtn.backgroundColor = pl_cardBg();
    refreshBtn.layer.cornerRadius = 8.0;
    refreshBtn.layer.borderWidth = 1.0;
    refreshBtn.layer.borderColor = pl_hairline().CGColor;
    [refreshBtn addTarget:self action:@selector(pingAllServers) forControlEvents:UIControlEventTouchUpInside];
    [hdr addSubview:refreshBtn];

    UIButton *addBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    addBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [addBtn setImage:[HorizonIcons iconForKind:HorizonIconPlus pointSize:14.0] forState:UIControlStateNormal];
    [addBtn setTitle:@"Добавить сервер" forState:UIControlStateNormal];
    [addBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    addBtn.tintColor = UIColor.whiteColor;
    addBtn.backgroundColor = pl_emerald();
    addBtn.layer.cornerRadius = 8.0;
    addBtn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    addBtn.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 6);
    addBtn.contentEdgeInsets = UIEdgeInsetsMake(7.0, 12.0, 7.0, 14.0);
    [addBtn addTarget:self action:@selector(onAddServerTapped) forControlEvents:UIControlEventTouchUpInside];
    [hdr addSubview:addBtn];

    [NSLayoutConstraint activateConstraints:@[
        [hdr.heightAnchor constraintEqualToConstant:36.0],
        [title.leadingAnchor constraintEqualToAnchor:hdr.leadingAnchor],
        [title.centerYAnchor constraintEqualToAnchor:hdr.centerYAnchor],
        [addBtn.trailingAnchor constraintEqualToAnchor:hdr.trailingAnchor],
        [addBtn.centerYAnchor constraintEqualToAnchor:hdr.centerYAnchor],
        [refreshBtn.trailingAnchor constraintEqualToAnchor:addBtn.leadingAnchor constant:-8.0],
        [refreshBtn.centerYAnchor constraintEqualToAnchor:hdr.centerYAnchor],
        [refreshBtn.widthAnchor constraintEqualToConstant:34.0],
        [refreshBtn.heightAnchor constraintEqualToConstant:32.0],
    ]];
    [self.serversStack addArrangedSubview:hdr];

    if (self.servers.count == 0) {
        UIView *empty = [self insetCard];
        UILabel *l = [[UILabel alloc] init];
        l.translatesAutoresizingMaskIntoConstraints = NO;
        l.text = @"Список серверов пуст. Нажмите «Добавить сервер», чтобы сохранить адрес в servers.dat и настроить автологин.";
        l.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
        l.textColor = pl_textSec();
        l.numberOfLines = 0;
        [empty addSubview:l];
        [NSLayoutConstraint activateConstraints:@[
            [l.topAnchor constraintEqualToAnchor:empty.topAnchor constant:14.0],
            [l.leadingAnchor constraintEqualToAnchor:empty.leadingAnchor constant:14.0],
            [l.trailingAnchor constraintEqualToAnchor:empty.trailingAnchor constant:-14.0],
            [l.bottomAnchor constraintEqualToAnchor:empty.bottomAnchor constant:-14.0],
        ]];
        [self.serversStack addArrangedSubview:empty];
    } else {
        for (NSUInteger i = 0; i < self.servers.count; i++) {
            [self.serversStack addArrangedSubview:[self buildServerCardForDict:self.servers[i] index:(NSInteger)i compactQuick:NO]];
        }
    }

    // Local Worlds section
    [self.serversStack addArrangedSubview:[self sectionCaption:@"ЛОКАЛЬНЫЕ МИРЫ"]];
    if (self.localWorlds.count == 0) {
        UIView *emptyW = [self insetCard];
        UILabel *lw = [[UILabel alloc] init];
        lw.translatesAutoresizingMaskIntoConstraints = NO;
        lw.text = @"Локальные миры появятся здесь после создания мира в Documents/saves/.";
        lw.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
        lw.textColor = pl_textMuted();
        lw.numberOfLines = 0;
        [emptyW addSubview:lw];
        [NSLayoutConstraint activateConstraints:@[
            [lw.topAnchor constraintEqualToAnchor:emptyW.topAnchor constant:12.0],
            [lw.leadingAnchor constraintEqualToAnchor:emptyW.leadingAnchor constant:14.0],
            [lw.trailingAnchor constraintEqualToAnchor:emptyW.trailingAnchor constant:-14.0],
            [lw.bottomAnchor constraintEqualToAnchor:emptyW.bottomAnchor constant:-12.0],
        ]];
        [self.serversStack addArrangedSubview:emptyW];
    } else {
        for (NSDictionary *w in self.localWorlds) {
            [self.serversStack addArrangedSubview:[self buildWorldCardForDict:w]];
        }
    }
}

- (UIView *)buildServerCardForDict:(NSDictionary *)srv index:(NSInteger)idx compactQuick:(BOOL)compactQuick {
    NSString *name = srv[@"name"] ?: @"Сервер";
    NSString *ip = srv[@"ip"] ?: @"";
    HorizonPingState *ping = self.pings[ip];
    HorizonAutoLoginConfig *autoCfg = [HorizonAutoLoginStore.shared configForAddress:ip];
    BOOL autoReady = autoCfg.enabled && autoCfg.hasPassword;

    UIView *card = [self insetCard];

    UIView *dot = [[UIView alloc] init];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.layer.cornerRadius = 4.5;
    if (ping == nil || ping.loading) {
        dot.backgroundColor = pl_textMuted();
    } else if (ping.online) {
        dot.backgroundColor = pl_emerald();
    } else {
        dot.backgroundColor = pl_danger();
    }
    [card addSubview:dot];

    UILabel *nameLbl = [[UILabel alloc] init];
    nameLbl.text = name;
    nameLbl.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
    nameLbl.textColor = pl_textPrimary();
    nameLbl.lineBreakMode = NSLineBreakByTruncatingTail;

    // Auto-Login badge pill (snug beside server name; collapsed cleanly when hidden)
    UIView *autoPill = [[UIView alloc] init];
    autoPill.translatesAutoresizingMaskIntoConstraints = NO;
    autoPill.backgroundColor = pl_emeraldSoft();
    autoPill.layer.cornerRadius = 6.0;
    autoPill.hidden = !autoReady;

    UIImageView *keyIv = [[UIImageView alloc] initWithImage:[HorizonIcons iconForKind:HorizonIconKey pointSize:11.0]];
    keyIv.translatesAutoresizingMaskIntoConstraints = NO;
    keyIv.tintColor = pl_emerald();
    [autoPill addSubview:keyIv];

    UILabel *autoLbl = [[UILabel alloc] init];
    autoLbl.translatesAutoresizingMaskIntoConstraints = NO;
    autoLbl.text = @"Автологин";
    autoLbl.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    autoLbl.textColor = pl_rgb(122, 238, 164, 1.0);
    [autoPill addSubview:autoLbl];

    UIStackView *nameRow = [[UIStackView alloc] initWithArrangedSubviews:@[nameLbl, autoPill]];
    nameRow.translatesAutoresizingMaskIntoConstraints = NO;
    nameRow.axis = UILayoutConstraintAxisHorizontal;
    nameRow.alignment = UIStackViewAlignmentCenter;
    nameRow.spacing = 7.0;
    [card addSubview:nameRow];

    // Subtitle: address + ping status
    NSString *pingDesc = @"Опрос…";
    if (ping != nil && !ping.loading) {
        if (ping.online) {
            if (ping.playersOnline >= 0 && ping.playersMax >= 0) {
                pingDesc = [NSString stringWithFormat:@"%llu мс · %lld/%lld",
                            (unsigned long long)ping.latencyMs,
                            (long long)ping.playersOnline,
                            (long long)ping.playersMax];
            } else {
                pingDesc = [NSString stringWithFormat:@"%llu мс · онлайн", (unsigned long long)ping.latencyMs];
            }
        } else {
            pingDesc = @"недоступен";
        }
    }
    UILabel *subLbl = [[UILabel alloc] init];
    subLbl.translatesAutoresizingMaskIntoConstraints = NO;
    subLbl.text = [NSString stringWithFormat:@"%@  ·  %@", ip, pingDesc];
    subLbl.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightRegular];
    subLbl.textColor = (ping != nil && !ping.loading && !ping.online) ? pl_textMuted() : pl_textSec();
    subLbl.lineBreakMode = NSLineBreakByTruncatingTail;
    [card addSubview:subLbl];

    // Join 1-tap button
    UIButton *joinBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    joinBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [joinBtn setTitle:@"Войти" forState:UIControlStateNormal];
    [joinBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    joinBtn.backgroundColor = pl_emerald();
    joinBtn.layer.cornerRadius = 8.0;
    joinBtn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightBold];
    joinBtn.contentEdgeInsets = UIEdgeInsetsMake(7.0, 14.0, 7.0, 14.0);
    joinBtn.accessibilityIdentifier = ip;
    [joinBtn addTarget:self action:@selector(onJoinServerTapped:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:joinBtn];

    UIView *rightAnchorTarget = joinBtn;
    if (!compactQuick && idx >= 0) {
        UIButton *editBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        editBtn.translatesAutoresizingMaskIntoConstraints = NO;
        [editBtn setImage:[HorizonIcons iconForKind:HorizonIconEdit pointSize:15.0] forState:UIControlStateNormal];
        editBtn.tintColor = pl_textSec();
        editBtn.backgroundColor = pl_elevatedBg();
        editBtn.layer.cornerRadius = 8.0;
        editBtn.tag = idx;
        [editBtn addTarget:self action:@selector(onEditServerTapped:) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:editBtn];

        [NSLayoutConstraint activateConstraints:@[
            [editBtn.trailingAnchor constraintEqualToAnchor:joinBtn.leadingAnchor constant:-8.0],
            [editBtn.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [editBtn.widthAnchor constraintEqualToConstant:34.0],
            [editBtn.heightAnchor constraintEqualToConstant:32.0],
        ]];
        rightAnchorTarget = editBtn;
    }

    [NSLayoutConstraint activateConstraints:@[
        [card.heightAnchor constraintGreaterThanOrEqualToConstant:58.0],
        [dot.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
        [dot.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [dot.widthAnchor constraintEqualToConstant:9.0],
        [dot.heightAnchor constraintEqualToConstant:9.0],

        [nameRow.topAnchor constraintEqualToAnchor:card.topAnchor constant:10.0],
        [nameRow.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:11.0],
        [nameRow.trailingAnchor constraintLessThanOrEqualToAnchor:rightAnchorTarget.leadingAnchor constant:-10.0],

        [autoPill.heightAnchor constraintEqualToConstant:19.0],
        [keyIv.leadingAnchor constraintEqualToAnchor:autoPill.leadingAnchor constant:5.0],
        [keyIv.centerYAnchor constraintEqualToAnchor:autoPill.centerYAnchor],
        [keyIv.widthAnchor constraintEqualToConstant:11.0],
        [keyIv.heightAnchor constraintEqualToConstant:11.0],
        [autoLbl.leadingAnchor constraintEqualToAnchor:keyIv.trailingAnchor constant:4.0],
        [autoLbl.trailingAnchor constraintEqualToAnchor:autoPill.trailingAnchor constant:-6.0],
        [autoLbl.centerYAnchor constraintEqualToAnchor:autoPill.centerYAnchor],

        [subLbl.topAnchor constraintEqualToAnchor:nameRow.bottomAnchor constant:3.0],
        [subLbl.leadingAnchor constraintEqualToAnchor:nameRow.leadingAnchor],
        [subLbl.trailingAnchor constraintLessThanOrEqualToAnchor:rightAnchorTarget.leadingAnchor constant:-10.0],
        [subLbl.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-10.0],

        [joinBtn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
        [joinBtn.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [joinBtn.heightAnchor constraintEqualToConstant:32.0],
    ]];
    [nameLbl setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [autoPill setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return card;
}

- (UIView *)buildWorldCardForDict:(NSDictionary *)w {
    NSString *folder = w[@"folder"] ?: @"";
    NSString *name = w[@"name"] ?: folder;
    int gameType = [w[@"game_type"] intValue];
    uint64_t sz = [w[@"size_bytes"] unsignedLongLongValue];
    int64_t lastMs = [w[@"last_played_ms"] longLongValue];

    NSString *modeName = @"Выживание";
    if (gameType == 1) modeName = @"Творческий";
    else if (gameType == 2) modeName = @"Приключение";
    else if (gameType == 3) modeName = @"Наблюдатель";

    NSString *datePart = @"";
    if (lastMs > 0) {
        static NSDateFormatter *fmt = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            fmt = [[NSDateFormatter alloc] init];
            fmt.locale = [NSLocale localeWithLocaleIdentifier:@"ru_RU"];
            fmt.dateFormat = @"d MMM HH:mm";
        });
        datePart = [NSString stringWithFormat:@" · %@", [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:lastMs / 1000.0]]];
    }

    UIView *card = [self insetCard];
    UIImageView *iv = [[UIImageView alloc] initWithImage:[HorizonIcons iconForKind:HorizonIconGlobe pointSize:18.0]];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.tintColor = pl_textSec();
    [card addSubview:iv];

    UILabel *titleLbl = [[UILabel alloc] init];
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
    titleLbl.text = name;
    titleLbl.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
    titleLbl.textColor = pl_textPrimary();
    titleLbl.lineBreakMode = NSLineBreakByTruncatingTail;
    [card addSubview:titleLbl];

    UILabel *subLbl = [[UILabel alloc] init];
    subLbl.translatesAutoresizingMaskIntoConstraints = NO;
    subLbl.text = [NSString stringWithFormat:@"%@ · %@%@", modeName, pl_formatBytes(sz), datePart];
    subLbl.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    subLbl.textColor = pl_textSec();
    subLbl.lineBreakMode = NSLineBreakByTruncatingTail;
    [card addSubview:subLbl];

    UIButton *openBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    openBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [openBtn setTitle:@"Открыть" forState:UIControlStateNormal];
    [openBtn setTitleColor:pl_textPrimary() forState:UIControlStateNormal];
    openBtn.backgroundColor = pl_elevatedBg();
    openBtn.layer.cornerRadius = 8.0;
    openBtn.layer.borderWidth = 1.0;
    openBtn.layer.borderColor = pl_hairline().CGColor;
    openBtn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    openBtn.contentEdgeInsets = UIEdgeInsetsMake(7.0, 14.0, 7.0, 14.0);
    openBtn.accessibilityIdentifier = folder;
    [openBtn addTarget:self action:@selector(onOpenWorldTapped:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:openBtn];

    [NSLayoutConstraint activateConstraints:@[
        [card.heightAnchor constraintGreaterThanOrEqualToConstant:56.0],
        [iv.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:13.0],
        [iv.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [iv.widthAnchor constraintEqualToConstant:18.0],
        [iv.heightAnchor constraintEqualToConstant:18.0],

        [titleLbl.topAnchor constraintEqualToAnchor:card.topAnchor constant:10.0],
        [titleLbl.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:11.0],
        [titleLbl.trailingAnchor constraintLessThanOrEqualToAnchor:openBtn.leadingAnchor constant:-10.0],

        [subLbl.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:2.0],
        [subLbl.leadingAnchor constraintEqualToAnchor:titleLbl.leadingAnchor],
        [subLbl.trailingAnchor constraintLessThanOrEqualToAnchor:openBtn.leadingAnchor constant:-10.0],
        [subLbl.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-10.0],

        [openBtn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
        [openBtn.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [openBtn.heightAnchor constraintEqualToConstant:32.0],
    ]];
    return card;
}

#pragma mark - Tab 3: Управление (Controls)

- (void)buildControlsTab {
    // Header + Live Input Status Pill
    UIView *hdr = [[UIView alloc] init];
    UILabel *title = [self pageHeaderLabel:@"Управление"];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [hdr addSubview:title];

    UIView *pill = [[UIView alloc] init];
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    pill.backgroundColor = pl_cardBg();
    pill.layer.cornerRadius = 13.0;
    pill.layer.borderWidth = 1.0;
    pill.layer.borderColor = pl_hairline().CGColor;
    [hdr addSubview:pill];

    self.controlsInputPillDot = [[UIView alloc] init];
    self.controlsInputPillDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.controlsInputPillDot.layer.cornerRadius = 3.5;
    self.controlsInputPillDot.backgroundColor = pl_emerald();
    [pill addSubview:self.controlsInputPillDot];

    self.controlsInputPillLabel = [[UILabel alloc] init];
    self.controlsInputPillLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.controlsInputPillLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    self.controlsInputPillLabel.textColor = pl_textSec();
    [pill addSubview:self.controlsInputPillLabel];

    [NSLayoutConstraint activateConstraints:@[
        [hdr.heightAnchor constraintEqualToConstant:34.0],
        [title.leadingAnchor constraintEqualToAnchor:hdr.leadingAnchor],
        [title.centerYAnchor constraintEqualToAnchor:hdr.centerYAnchor],
        [pill.trailingAnchor constraintEqualToAnchor:hdr.trailingAnchor],
        [pill.centerYAnchor constraintEqualToAnchor:hdr.centerYAnchor],
        [pill.heightAnchor constraintEqualToConstant:26.0],
        [self.controlsInputPillDot.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:10.0],
        [self.controlsInputPillDot.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
        [self.controlsInputPillDot.widthAnchor constraintEqualToConstant:7.0],
        [self.controlsInputPillDot.heightAnchor constraintEqualToConstant:7.0],
        [self.controlsInputPillLabel.leadingAnchor constraintEqualToAnchor:self.controlsInputPillDot.trailingAnchor constant:6.0],
        [self.controlsInputPillLabel.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-10.0],
        [self.controlsInputPillLabel.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
    ]];
    [self.controlsStack addArrangedSubview:hdr];

    [self.controlsStack addArrangedSubview:[self sectionCaption:@"СХЕМА СЕНСОРНОГО УПРАВЛЕНИЯ"]];
    self.ctrlSchemeSeg = [self styledSegmentedControlWithItems:@[@"Джойстик + прицел", @"Джойстик + тап", @"Крестовина"]
                                                        action:@selector(onControlsChanged)];
    [self.controlsStack addArrangedSubview:self.ctrlSchemeSeg];

    self.ctrlFloatingSw = [self makeToggleRow:@"Плавающий джойстик" subtitle:nil action:@selector(onControlsChanged) inStack:self.controlsStack];
    self.ctrlAutoJumpSw = [self makeToggleRow:@"Автопрыжок (в сенсорном режиме)" subtitle:nil action:@selector(onControlsChanged) inStack:self.controlsStack];

    UILabel *lbl = nil;
    self.ctrlScaleSlider = [self makeSliderRow:@"Размер кнопок" min:0.70 max:1.40 valueLabel:&lbl action:@selector(onControlsChanged) inStack:self.controlsStack];
    self.ctrlScaleVal = lbl;

    self.ctrlOpacitySlider = [self makeSliderRow:@"Прозрачность кнопок" min:0.25 max:1.00 valueLabel:&lbl action:@selector(onControlsChanged) inStack:self.controlsStack];
    self.ctrlOpacityVal = lbl;

    self.ctrlSensSlider = [self makeSliderRow:@"Чувствительность камеры" min:0.30 max:2.50 valueLabel:&lbl action:@selector(onControlsChanged) inStack:self.controlsStack];
    self.ctrlSensVal = lbl;

    self.ctrlLeftHandSw = [self makeToggleRow:@"Раскладка для левши" subtitle:nil action:@selector(onControlsChanged) inStack:self.controlsStack];
    self.ctrlSwapJumpSw = [self makeToggleRow:@"Поменять прыжок и приседание" subtitle:nil action:@selector(onControlsChanged) inStack:self.controlsStack];
    self.ctrlHapticsSw = [self makeToggleRow:@"Тактильный отклик (CoreHaptics)" subtitle:nil action:@selector(onControlsChanged) inStack:self.controlsStack];
    self.ctrlGyroSw = [self makeToggleRow:@"Прицеливание гироскопом" subtitle:nil action:@selector(onControlsChanged) inStack:self.controlsStack];

    self.ctrlGyroSlider = [self makeSliderRow:@"Чувствительность гироскопа" min:0.20 max:3.00 valueLabel:&lbl action:@selector(onControlsChanged) inStack:self.controlsStack];
    self.ctrlGyroVal = lbl;

    UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    resetBtn.backgroundColor = pl_rgb(229, 83, 75, 0.12);
    resetBtn.layer.cornerRadius = 10.0;
    resetBtn.layer.borderWidth = 1.0;
    resetBtn.layer.borderColor = pl_rgb(229, 83, 75, 0.30).CGColor;
    [resetBtn setTitle:@"Сбросить настройки управления" forState:UIControlStateNormal];
    [resetBtn setTitleColor:pl_rgb(245, 114, 107, 1.0) forState:UIControlStateNormal];
    resetBtn.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    resetBtn.contentEdgeInsets = UIEdgeInsetsMake(10.0, 14.0, 10.0, 14.0);
    [resetBtn addTarget:self action:@selector(onResetControlsTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.controlsStack addArrangedSubview:resetBtn];
}

- (void)syncControlsUIFromSettings {
    HorizonSettings *s = HorizonSettings.shared;
    self.ctrlSchemeSeg.selectedSegmentIndex = (NSInteger)s.scheme;
    self.ctrlFloatingSw.on = s.floatingJoystick;
    self.ctrlAutoJumpSw.on = s.autoJump;
    self.ctrlScaleSlider.value = (float)s.buttonScale;
    self.ctrlOpacitySlider.value = (float)s.buttonOpacity;
    self.ctrlSensSlider.value = (float)s.cameraSensitivity;
    self.ctrlLeftHandSw.on = s.leftHanded;
    self.ctrlSwapJumpSw.on = s.swapJumpSneak;
    self.ctrlHapticsSw.on = s.hapticsEnabled;
    self.ctrlGyroSw.on = s.gyroEnabled;
    self.ctrlGyroSlider.value = (float)s.gyroSensitivity;
    [self refreshControlValueLabels];
}

- (void)refreshControlValueLabels {
    self.ctrlScaleVal.text   = [NSString stringWithFormat:@"%d%%", (int)llround(self.ctrlScaleSlider.value * 100.0f)];
    self.ctrlOpacityVal.text = [NSString stringWithFormat:@"%d%%", (int)llround(self.ctrlOpacitySlider.value * 100.0f)];
    self.ctrlSensVal.text    = [NSString stringWithFormat:@"%.2fx", self.ctrlSensSlider.value];
    self.ctrlGyroVal.text    = [NSString stringWithFormat:@"%.2fx", self.ctrlGyroSlider.value];
}

- (void)onControlsChanged {
    HorizonSettings *s = HorizonSettings.shared;
    s.scheme            = (HorizonTouchScheme)self.ctrlSchemeSeg.selectedSegmentIndex;
    s.floatingJoystick  = self.ctrlFloatingSw.isOn;
    s.autoJump          = self.ctrlAutoJumpSw.isOn;
    s.buttonScale       = self.ctrlScaleSlider.value;
    s.buttonOpacity     = self.ctrlOpacitySlider.value;
    s.cameraSensitivity = self.ctrlSensSlider.value;
    s.leftHanded        = self.ctrlLeftHandSw.isOn;
    s.swapJumpSneak     = self.ctrlSwapJumpSw.isOn;
    s.hapticsEnabled    = self.ctrlHapticsSw.isOn;
    s.gyroEnabled       = self.ctrlGyroSw.isOn;
    s.gyroSensitivity   = self.ctrlGyroSlider.value;
    [self refreshControlValueLabels];
    [self updateSummaryTiles];
}

- (void)onResetControlsTapped {
    [HorizonSettings.shared resetToDefaults];
    [self syncControlsUIFromSettings];
    [self updateSummaryTiles];
}

#pragma mark - Tab 4: Графика (Graphics & options.txt)

- (void)buildGraphicsTab {
    [self.graphicsStack addArrangedSubview:[self pageHeaderLabel:@"Графика"]];

    [self.graphicsStack addArrangedSubview:[self sectionCaption:@"БЫСТРЫЕ ПРЕСЕТЫ"]];
    UIStackView *presetRow = [[UIStackView alloc] init];
    presetRow.axis = UILayoutConstraintAxisHorizontal;
    presetRow.spacing = 10.0;
    presetRow.distribution = UIStackViewDistributionFillEqually;

    NSArray<NSArray<NSString *> *> *presets = @[
        @[@"Батарея", @"6 чанков · 30 FPS"],
        @[@"Баланс", @"8 чанков · 60 FPS"],
        @[@"Максимум", @"12 чанков · 120 FPS"],
    ];
    NSMutableArray<UIButton *> *pBtns = [NSMutableArray array];
    for (NSUInteger i = 0; i < presets.count; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.backgroundColor = pl_cardBg();
        btn.layer.cornerRadius = 11.0;
        btn.layer.borderWidth = 1.0;
        btn.layer.borderColor = pl_hairline().CGColor;
        btn.tag = (NSInteger)i;
        btn.titleLabel.numberOfLines = 2;
        btn.titleLabel.textAlignment = NSTextAlignmentCenter;
        btn.contentEdgeInsets = UIEdgeInsetsMake(9.0, 8.0, 9.0, 8.0);

        NSMutableAttributedString *attr = [[NSMutableAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"%@\n", presets[i][0]]
                attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13.5 weight:UIFontWeightBold],
                             NSForegroundColorAttributeName: pl_textPrimary()}];
        [attr appendAttributedString:[[NSAttributedString alloc]
            initWithString:presets[i][1]
                attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular],
                             NSForegroundColorAttributeName: pl_textSec()}]];
        [btn setAttributedTitle:attr forState:UIControlStateNormal];
        [btn addTarget:self action:@selector(onGraphicsPresetTapped:) forControlEvents:UIControlEventTouchUpInside];
        [presetRow addArrangedSubview:btn];
        [pBtns addObject:btn];
    }
    self.presetButtons = pBtns;
    [self.graphicsStack addArrangedSubview:presetRow];

    [self.graphicsStack addArrangedSubview:[self sectionCaption:@"OPTIONS.TXT"]];
    UILabel *lbl = nil;
    self.gfxRenderSlider = [self makeSliderRow:@"Дальность прорисовки" min:2.0 max:24.0 valueLabel:&lbl action:@selector(onGraphicsChanged) inStack:self.graphicsStack];
    self.gfxRenderVal = lbl;

    [self.graphicsStack addArrangedSubview:[self sectionCaption:@"ЛИМИТ FPS"]];
    self.gfxFpsSeg = [self styledSegmentedControlWithItems:@[@"30", @"60", @"90", @"120", @"Без лимита"]
                                                    action:@selector(onGraphicsChanged)];
    [self.graphicsStack addArrangedSubview:self.gfxFpsSeg];

    [self.graphicsStack addArrangedSubview:[self sectionCaption:@"МАСШТАБ ИНТЕРФЕЙСА"]];
    self.gfxGuiSeg = [self styledSegmentedControlWithItems:@[@"Авто", @"1×", @"2×", @"3×", @"4×"]
                                                    action:@selector(onGraphicsChanged)];
    [self.graphicsStack addArrangedSubview:self.gfxGuiSeg];

    self.gfxFovSlider = [self makeSliderRow:@"Поле зрения (FOV)" min:60.0 max:110.0 valueLabel:&lbl action:@selector(onGraphicsChanged) inStack:self.graphicsStack];
    self.gfxFovVal = lbl;

    [self.graphicsStack addArrangedSubview:[self sectionCaption:@"ЯЗЫК ИГРЫ"]];
    self.gfxLangSeg = [self styledSegmentedControlWithItems:@[@"Русский (ru_ru)", @"English (en_us)"]
                                                     action:@selector(onGraphicsChanged)];
    [self.graphicsStack addArrangedSubview:self.gfxLangSeg];

    [self.graphicsStack addArrangedSubview:[self sectionCaption:@"ЗАПУСК"]];
    self.skipLauncherSwitch = [self makeToggleRow:@"Пропускать лаунчер при старте"
                                         subtitle:@"Вернуть лаунчер можно в настройках управления внутри игры (Show Launcher on Next Start)."
                                           action:@selector(onSkipLauncherChanged)
                                          inStack:self.graphicsStack];
}

- (void)syncGraphicsUIFromOptions {
    int32_t clampedRd = MAX(2, MIN(24, self.optRenderDistance));
    self.gfxRenderSlider.value = (float)clampedRd;
    self.gfxRenderVal.text = [NSString stringWithFormat:@"%d чанков", self.optRenderDistance];

    NSInteger fpsIdx = 3; // 120
    if (self.optMaxFps <= 30) fpsIdx = 0;
    else if (self.optMaxFps <= 60) fpsIdx = 1;
    else if (self.optMaxFps <= 90) fpsIdx = 2;
    else if (self.optMaxFps <= 120) fpsIdx = 3;
    else fpsIdx = 4;
    self.gfxFpsSeg.selectedSegmentIndex = fpsIdx;

    self.gfxGuiSeg.selectedSegmentIndex = MAX(0, MIN(4, self.optGuiScale));

    int32_t clampedFov = MAX(60, MIN(110, self.optFov));
    self.gfxFovSlider.value = (float)clampedFov;
    self.gfxFovVal.text = [NSString stringWithFormat:@"%d°", self.optFov];

    BOOL isRu = [self.optLang.lowercaseString hasPrefix:@"ru"];
    self.gfxLangSeg.selectedSegmentIndex = isRu ? 0 : 1;
    self.skipLauncherSwitch.on = HorizonSettings.shared.skipLauncher;

    [self refreshGraphicsPresetHighlight];
}

- (void)refreshGraphicsPresetHighlight {
    int match = -1;
    if (self.optRenderDistance == 6 && self.optMaxFps == 30) match = 0;
    else if (self.optRenderDistance == 8 && self.optMaxFps == 60) match = 1;
    else if (self.optRenderDistance == 12 && self.optMaxFps == 120) match = 2;

    for (NSUInteger i = 0; i < self.presetButtons.count; i++) {
        UIButton *btn = self.presetButtons[i];
        BOOL active = ((int)i == match);
        btn.backgroundColor = active ? pl_emeraldSoft() : pl_cardBg();
        btn.layer.borderColor = active ? pl_emerald().CGColor : pl_hairline().CGColor;
    }
}

- (void)onGraphicsPresetTapped:(UIButton *)sender {
    if (sender.tag == 0) {
        self.optRenderDistance = 6;
        self.optMaxFps = 30;
    } else if (sender.tag == 1) {
        self.optRenderDistance = 8;
        self.optMaxFps = 60;
    } else {
        self.optRenderDistance = 12;
        self.optMaxFps = 120;
    }
    [self saveOptionsToDisk];
    [self syncGraphicsUIFromOptions];
    [self updateSummaryTiles];
}

- (void)onGraphicsChanged {
    static const int32_t kFpsTable[5] = {30, 60, 90, 120, 260};
    self.optRenderDistance = (int32_t)llroundf(self.gfxRenderSlider.value);
    NSInteger fi = self.gfxFpsSeg.selectedSegmentIndex;
    self.optMaxFps = (fi >= 0 && fi < 5) ? kFpsTable[fi] : 120;
    self.optGuiScale = (int32_t)MAX(0, self.gfxGuiSeg.selectedSegmentIndex);
    self.optFov = (int32_t)llroundf(self.gfxFovSlider.value);
    self.optLang = (self.gfxLangSeg.selectedSegmentIndex == 0) ? @"ru_ru" : @"en_us";

    self.gfxRenderVal.text = [NSString stringWithFormat:@"%d чанков", self.optRenderDistance];
    self.gfxFovVal.text = [NSString stringWithFormat:@"%d°", self.optFov];

    [self saveOptionsToDisk];
    [self refreshGraphicsPresetHighlight];
    [self updateSummaryTiles];
}

- (void)onSkipLauncherChanged {
    HorizonSettings.shared.skipLauncher = self.skipLauncherSwitch.isOn;
}

#pragma mark - Tab 5: Файлы (Resources, Packs, Logs, Diagnostics)

- (NSUInteger)countItemsInDirectory:(NSString *)dir {
    NSArray<NSString *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
    NSUInteger count = 0;
    for (NSString *name in items) {
        if (![name hasPrefix:@"."]) count++;
    }
    return count;
}

- (NSArray<NSURL *> *)availableLogURLsWithTitles:(NSMutableArray<NSString *> *)outTitles {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;

    NSString *curLog = [self.documentsDir stringByAppendingPathComponent:@"horizon-log.txt"];
    if ([fm fileExistsAtPath:curLog]) {
        [urls addObject:[NSURL fileURLWithPath:curLog]];
        [outTitles addObject:@"Текущий лог"];
    }
    NSString *prevLog = [self.documentsDir stringByAppendingPathComponent:@"horizon-log.previous.txt"];
    if ([fm fileExistsAtPath:prevLog]) {
        [urls addObject:[NSURL fileURLWithPath:prevLog]];
        [outTitles addObject:@"Предыдущий"];
    }
    // Latest crash report in Documents/horizon/crash-reports/
    NSString *crashDir = [[self.documentsDir stringByAppendingPathComponent:@"horizon"]
                          stringByAppendingPathComponent:@"crash-reports"];
    NSArray<NSString *> *crashes = [fm contentsOfDirectoryAtPath:crashDir error:nil];
    NSURL *newestCrash = nil;
    NSDate *newestDate = nil;
    for (NSString *f in crashes) {
        if ([f hasPrefix:@"."]) continue;
        NSString *full = [crashDir stringByAppendingPathComponent:f];
        NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
        NSDate *mod = attrs[NSFileModificationDate];
        if (newestCrash == nil || (mod != nil && [mod compare:newestDate] == NSOrderedDescending)) {
            newestCrash = [NSURL fileURLWithPath:full];
            newestDate = mod;
        }
    }
    if (newestCrash != nil) {
        [urls addObject:newestCrash];
        [outTitles addObject:@"Краш-репорт"];
    }
    return urls;
}

- (void)rebuildFilesTab {
    for (UIView *sub in [self.filesStack.arrangedSubviews copy]) {
        [self.filesStack removeArrangedSubview:sub];
        [sub removeFromSuperview];
    }

    [self.filesStack addArrangedSubview:[self pageHeaderLabel:@"Файлы и диагностика"]];

    // 1. Game Resources card
    [self.filesStack addArrangedSubview:[self sectionCaption:@"РЕСУРСЫ ИГРЫ (DOCUMENTS/RESOURCES)"]];
    UIView *resCard = [self insetCard];
    UIImageView *resIcon = [[UIImageView alloc] initWithImage:[HorizonIcons iconForKind:(self.resourcesReady ? HorizonIconCheck : HorizonIconWarning) pointSize:18.0]];
    resIcon.translatesAutoresizingMaskIntoConstraints = NO;
    resIcon.tintColor = self.resourcesReady ? pl_emerald() : pl_amber();
    [resCard addSubview:resIcon];

    UILabel *resTitle = [[UILabel alloc] init];
    resTitle.translatesAutoresizingMaskIntoConstraints = NO;
    resTitle.text = self.resourcesReady ? @"Ресурсы Horizon 26.3 готовы" : @"Ресурсы не найдены";
    resTitle.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
    resTitle.textColor = self.resourcesReady ? pl_textPrimary() : pl_amber();
    [resCard addSubview:resTitle];

    UILabel *resSub = [[UILabel alloc] init];
    resSub.translatesAutoresizingMaskIntoConstraints = NO;
    if (self.resourcesReady) {
        NSString *szStr = self.resourcesSizeCalculated ? pl_formatBytes(self.resourcesBytes) : @"подсчёт размера…";
        resSub.text = [NSString stringWithFormat:@"horizon-resources.json найден · %@", szStr];
    } else {
        resSub.text = @"Импортируйте папку resources или .zip-архив с horizon-resources.json";
    }
    resSub.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    resSub.textColor = pl_textSec();
    resSub.numberOfLines = 0;
    [resCard addSubview:resSub];

    UIButton *importBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    importBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [importBtn setTitle:@"Импорт…" forState:UIControlStateNormal];
    [importBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    importBtn.backgroundColor = self.resourcesReady ? pl_elevatedBg() : pl_emerald();
    importBtn.layer.cornerRadius = 8.0;
    importBtn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    importBtn.contentEdgeInsets = UIEdgeInsetsMake(7.0, 14.0, 7.0, 14.0);
    [importBtn addTarget:self action:@selector(onImportResourcesTapped:) forControlEvents:UIControlEventTouchUpInside];
    [resCard addSubview:importBtn];

    [NSLayoutConstraint activateConstraints:@[
        [resIcon.leadingAnchor constraintEqualToAnchor:resCard.leadingAnchor constant:14.0],
        [resIcon.centerYAnchor constraintEqualToAnchor:resCard.centerYAnchor],
        [resIcon.widthAnchor constraintEqualToConstant:18.0],
        [resIcon.heightAnchor constraintEqualToConstant:18.0],

        [resTitle.topAnchor constraintEqualToAnchor:resCard.topAnchor constant:11.0],
        [resTitle.leadingAnchor constraintEqualToAnchor:resIcon.trailingAnchor constant:11.0],
        [resTitle.trailingAnchor constraintLessThanOrEqualToAnchor:importBtn.leadingAnchor constant:-10.0],

        [resSub.topAnchor constraintEqualToAnchor:resTitle.bottomAnchor constant:2.0],
        [resSub.leadingAnchor constraintEqualToAnchor:resTitle.leadingAnchor],
        [resSub.trailingAnchor constraintLessThanOrEqualToAnchor:importBtn.leadingAnchor constant:-10.0],
        [resSub.bottomAnchor constraintEqualToAnchor:resCard.bottomAnchor constant:-11.0],

        [importBtn.trailingAnchor constraintEqualToAnchor:resCard.trailingAnchor constant:-12.0],
        [importBtn.centerYAnchor constraintEqualToAnchor:resCard.centerYAnchor],
    ]];
    [self.filesStack addArrangedSubview:resCard];

    // 2. Resource Packs & Shader Packs
    [self.filesStack addArrangedSubview:[self sectionCaption:@"ПАКЕТЫ РЕСУРСОВ И ШЕЙДЕРЫ"]];
    NSUInteger rpCount = [self countItemsInDirectory:self.resourcePacksDir];
    NSUInteger spCount = [self countItemsInDirectory:self.shaderPacksDir];
    [self.filesStack addArrangedSubview:[self packRowTitle:@"Ресурспаки"
                                                  subtitle:[NSString stringWithFormat:@"%lu шт. в Documents/resourcepacks/", (unsigned long)rpCount]
                                                    action:@selector(onImportResourcePackTapped)]];
    [self.filesStack addArrangedSubview:[self packRowTitle:@"Шейдеры"
                                                  subtitle:[NSString stringWithFormat:@"%lu шт. в Documents/shaderpacks/", (unsigned long)spCount]
                                                    action:@selector(onImportShaderPackTapped)]];

    // 3. Logs & Crash Reports
    [self.filesStack addArrangedSubview:[self sectionCaption:@"ЛОГИ И ОТЧЁТЫ О СБОЯХ"]];
    NSMutableArray<NSString *> *logTitles = [NSMutableArray array];
    NSArray<NSURL *> *logURLs = [self availableLogURLsWithTitles:logTitles];
    UIView *logCard = [self insetCard];

    UIImageView *docIv = [[UIImageView alloc] initWithImage:[HorizonIcons iconForKind:HorizonIconDocument pointSize:18.0]];
    docIv.translatesAutoresizingMaskIntoConstraints = NO;
    docIv.tintColor = pl_textSec();
    [logCard addSubview:docIv];

    UILabel *logTitle = [[UILabel alloc] init];
    logTitle.translatesAutoresizingMaskIntoConstraints = NO;
    logTitle.text = @"Логи запуска и краш-репорты";
    logTitle.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    logTitle.textColor = pl_textPrimary();
    [logCard addSubview:logTitle];

    UILabel *logSub = [[UILabel alloc] init];
    logSub.translatesAutoresizingMaskIntoConstraints = NO;
    logSub.text = (logTitles.count > 0)
        ? [logTitles componentsJoinedByString:@" · "]
        : @"Файлы логов пока не созданы";
    logSub.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    logSub.textColor = pl_textSec();
    [logCard addSubview:logSub];

    UIButton *openLogBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    openLogBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [openLogBtn setTitle:@"Открыть" forState:UIControlStateNormal];
    [openLogBtn setTitleColor:pl_textPrimary() forState:UIControlStateNormal];
    openLogBtn.backgroundColor = pl_elevatedBg();
    openLogBtn.layer.cornerRadius = 8.0;
    openLogBtn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    openLogBtn.contentEdgeInsets = UIEdgeInsetsMake(6.0, 12.0, 6.0, 12.0);
    openLogBtn.enabled = (logURLs.count > 0);
    openLogBtn.alpha = (logURLs.count > 0) ? 1.0 : 0.45;
    [openLogBtn addTarget:self action:@selector(onOpenLogsTapped) forControlEvents:UIControlEventTouchUpInside];
    [logCard addSubview:openLogBtn];

    UIButton *shareLogBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    shareLogBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [shareLogBtn setImage:[HorizonIcons iconForKind:HorizonIconShare pointSize:14.0] forState:UIControlStateNormal];
    [shareLogBtn setTitle:@"Поделиться" forState:UIControlStateNormal];
    shareLogBtn.tintColor = pl_emerald();
    [shareLogBtn setTitleColor:pl_emerald() forState:UIControlStateNormal];
    shareLogBtn.backgroundColor = pl_emeraldSoft();
    shareLogBtn.layer.cornerRadius = 8.0;
    shareLogBtn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    shareLogBtn.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 5);
    shareLogBtn.contentEdgeInsets = UIEdgeInsetsMake(6.0, 12.0, 6.0, 12.0);
    shareLogBtn.enabled = (logURLs.count > 0);
    shareLogBtn.alpha = (logURLs.count > 0) ? 1.0 : 0.45;
    [shareLogBtn addTarget:self action:@selector(onShareLogsTapped:) forControlEvents:UIControlEventTouchUpInside];
    [logCard addSubview:shareLogBtn];

    [NSLayoutConstraint activateConstraints:@[
        [docIv.leadingAnchor constraintEqualToAnchor:logCard.leadingAnchor constant:14.0],
        [docIv.centerYAnchor constraintEqualToAnchor:logCard.centerYAnchor],
        [docIv.widthAnchor constraintEqualToConstant:18.0],
        [docIv.heightAnchor constraintEqualToConstant:18.0],

        [logTitle.topAnchor constraintEqualToAnchor:logCard.topAnchor constant:11.0],
        [logTitle.leadingAnchor constraintEqualToAnchor:docIv.trailingAnchor constant:11.0],
        [logTitle.trailingAnchor constraintLessThanOrEqualToAnchor:openLogBtn.leadingAnchor constant:-10.0],

        [logSub.topAnchor constraintEqualToAnchor:logTitle.bottomAnchor constant:2.0],
        [logSub.leadingAnchor constraintEqualToAnchor:logTitle.leadingAnchor],
        [logSub.trailingAnchor constraintLessThanOrEqualToAnchor:openLogBtn.leadingAnchor constant:-10.0],
        [logSub.bottomAnchor constraintEqualToAnchor:logCard.bottomAnchor constant:-11.0],

        [shareLogBtn.trailingAnchor constraintEqualToAnchor:logCard.trailingAnchor constant:-12.0],
        [shareLogBtn.centerYAnchor constraintEqualToAnchor:logCard.centerYAnchor],
        [openLogBtn.trailingAnchor constraintEqualToAnchor:shareLogBtn.leadingAnchor constant:-8.0],
        [openLogBtn.centerYAnchor constraintEqualToAnchor:logCard.centerYAnchor],
    ]];
    [self.filesStack addArrangedSubview:logCard];

    // 4. System Diagnostics
    [self.filesStack addArrangedSubview:[self sectionCaption:@"ДИАГНОСТИКА СИСТЕМЫ"]];
    uint64_t physRam = NSProcessInfo.processInfo.physicalMemory;
    size_t availMem = os_proc_available_memory();
    NSDictionary *fsAttrs = [NSFileManager.defaultManager attributesOfFileSystemForPath:self.documentsDir error:nil];
    uint64_t freeDisk = [fsAttrs[NSFileSystemFreeSize] unsignedLongLongValue];

    UIView *diagCard = [self insetCard];
    UIStackView *diagStack = [[UIStackView alloc] init];
    diagStack.translatesAutoresizingMaskIntoConstraints = NO;
    diagStack.axis = UILayoutConstraintAxisVertical;
    diagStack.spacing = 8.0;
    [diagCard addSubview:diagStack];
    [NSLayoutConstraint activateConstraints:@[
        [diagStack.topAnchor constraintEqualToAnchor:diagCard.topAnchor constant:12.0],
        [diagStack.leadingAnchor constraintEqualToAnchor:diagCard.leadingAnchor constant:14.0],
        [diagStack.trailingAnchor constraintEqualToAnchor:diagCard.trailingAnchor constant:-14.0],
        [diagStack.bottomAnchor constraintEqualToAnchor:diagCard.bottomAnchor constant:-12.0],
    ]];
    [diagStack addArrangedSubview:[self diagRowKey:@"Оперативная память (RAM)"
                                             value:[NSString stringWithFormat:@"%@ (свободно процессу: %@)",
                                                    pl_formatBytes(physRam), pl_formatBytes((uint64_t)availMem)]
                                             color:pl_textPrimary()]];
    [diagStack addArrangedSubview:[self diagRowKey:@"Свободно на диске"
                                             value:pl_formatBytes(freeDisk)
                                             color:pl_textPrimary()]];
    [diagStack addArrangedSubview:[self diagRowKey:@"Increased Memory Limit"
                                             value:(self.increasedMemoryActive ? @"Активен" : @"Стандартный лимит")
                                             color:(self.increasedMemoryActive ? pl_emerald() : pl_amber())]];
    [self.filesStack addArrangedSubview:diagCard];
}

- (UIView *)packRowTitle:(NSString *)title subtitle:(NSString *)subtitle action:(SEL)action {
    UIView *card = [self insetCard];
    UILabel *t = [[UILabel alloc] init];
    t.translatesAutoresizingMaskIntoConstraints = NO;
    t.text = title;
    t.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    t.textColor = pl_textPrimary();
    [card addSubview:t];

    UILabel *s = [[UILabel alloc] init];
    s.translatesAutoresizingMaskIntoConstraints = NO;
    s.text = subtitle;
    s.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    s.textColor = pl_textSec();
    [card addSubview:s];

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [btn setTitle:@"+ .zip" forState:UIControlStateNormal];
    [btn setTitleColor:pl_emerald() forState:UIControlStateNormal];
    btn.backgroundColor = pl_emeraldSoft();
    btn.layer.cornerRadius = 8.0;
    btn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    btn.contentEdgeInsets = UIEdgeInsetsMake(6.0, 12.0, 6.0, 12.0);
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:btn];

    [NSLayoutConstraint activateConstraints:@[
        [t.topAnchor constraintEqualToAnchor:card.topAnchor constant:10.0],
        [t.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
        [s.topAnchor constraintEqualToAnchor:t.bottomAnchor constant:2.0],
        [s.leadingAnchor constraintEqualToAnchor:t.leadingAnchor],
        [s.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-10.0],
        [btn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
        [btn.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
    ]];
    return card;
}

- (UIView *)diagRowKey:(NSString *)key value:(NSString *)value color:(UIColor *)valColor {
    UIView *row = [[UIView alloc] init];
    UILabel *k = [[UILabel alloc] init];
    k.translatesAutoresizingMaskIntoConstraints = NO;
    k.text = key;
    k.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    k.textColor = pl_textSec();
    [row addSubview:k];

    UILabel *v = [[UILabel alloc] init];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.text = value;
    v.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightSemibold];
    v.textColor = valColor;
    v.textAlignment = NSTextAlignmentRight;
    [row addSubview:v];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:22.0],
        [k.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [k.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [v.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [v.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [v.leadingAnchor constraintGreaterThanOrEqualToAnchor:k.trailingAnchor constant:10.0],
    ]];
    return row;
}

#pragma mark - Unified UI Refresh

- (void)refreshAllUI {
    [self updateProfileUI];
    [self refreshInputStatusUI];
    [self syncControlsUIFromSettings];
    [self syncGraphicsUIFromOptions];
    [self updateSummaryTiles];
    [self updateReadinessUI];
    [self updateTabBadges];
    [self rebuildHomeQuickSection];
    [self rebuildServersTab];
    [self rebuildFilesTab];
}

- (void)updateProfileUI {
    NSString *nick = self.playerName.length > 0 ? self.playerName : @"Player";
    if (!self.nickField.isFirstResponder) {
        self.nickField.text = nick;
    }
    NSString *initial = [[nick substringToIndex:1] uppercaseString];
    self.footerAvatarLabel.text = initial;
    self.homeAvatarLabel.text = initial;
    self.footerNickLabel.text = nick;
}

- (void)refreshInputStatusUI {
    GCController *pad = GCController.controllers.firstObject;
    BOOL hasKb = (GCKeyboard.coalescedKeyboard != nil);
    BOOL hasMouse = (GCMouse.mice.count > 0);

    NSString *footerSub = @"Тач · Офлайн";
    NSString *pillText = @"Сенсорное управление активно";
    UIColor *dotColor = pl_emerald();

    if (pad != nil) {
        NSString *padName = pad.vendorName.length > 0 ? pad.vendorName : @"Геймпад";
        footerSub = [NSString stringWithFormat:@"%@ · Офлайн", padName];
        pillText = [NSString stringWithFormat:@"Подключён геймпад: %@", padName];
    } else if (hasKb && hasMouse) {
        footerSub = @"Клавиатура+мышь";
        pillText = @"Подключены клавиатура и мышь";
    } else if (hasKb) {
        footerSub = @"Клавиатура + тач";
        pillText = @"Подключена аппаратная клавиатура";
    } else if (hasMouse) {
        footerSub = @"Мышь + тач";
        pillText = @"Подключена мышь";
    }

    self.footerInputLabel.text = footerSub;
    self.controlsInputPillLabel.text = pillText;
    self.controlsInputPillDot.backgroundColor = dotColor;
}

- (void)updateSummaryTiles {
    self.tileRenderVal.text = [NSString stringWithFormat:@"%d чанков", self.optRenderDistance];
    self.tileFpsVal.text = (self.optMaxFps >= 260)
        ? @"Без лимита"
        : [NSString stringWithFormat:@"%d FPS", self.optMaxFps];

    HorizonTouchScheme sc = HorizonSettings.shared.scheme;
    if (sc == HorizonTouchSchemeJoystickCrosshair) self.tileSchemeVal.text = @"Джойстик";
    else if (sc == HorizonTouchSchemeJoystickTap)  self.tileSchemeVal.text = @"Тап";
    else                                           self.tileSchemeVal.text = @"Крестовина";

    if (self.resourcesReady) {
        self.tileResourcesVal.text = self.resourcesSizeCalculated ? pl_formatBytes(self.resourcesBytes) : @"Готово";
        self.tileResourcesVal.textColor = pl_textPrimary();
        self.tileResourcesIcon.image = [HorizonIcons iconForKind:HorizonIconCheck pointSize:16.0];
        self.tileResourcesIcon.tintColor = pl_emerald();
    } else {
        self.tileResourcesVal.text = @"Нет ресурсов";
        self.tileResourcesVal.textColor = pl_amber();
        self.tileResourcesIcon.image = [HorizonIcons iconForKind:HorizonIconWarning pointSize:16.0];
        self.tileResourcesIcon.tintColor = pl_amber();
    }
}

- (void)updateReadinessUI {
    [self updateSummaryTiles];
    [self updateTabBadges];

    if (self.resourcesReady) {
        self.statusDot.backgroundColor = pl_emerald();
        self.statusLabel.text = self.increasedMemoryActive
            ? @"Increased Memory активен · Metal ещё не загружен"
            : @"Готов к запуску · Metal ещё не загружен";
        self.statusLabel.textColor = pl_textSec();
        self.playButton.backgroundColor = pl_emerald();
        [self.playButton setTitle:@"Играть" forState:UIControlStateNormal];
    } else {
        self.statusDot.backgroundColor = pl_amber();
        self.statusLabel.text = @"Ресурсы отсутствуют — импортируйте во вкладке «Файлы»";
        self.statusLabel.textColor = pl_amber();
        self.playButton.backgroundColor = pl_amber();
        [self.playButton setTitle:@"Импорт" forState:UIControlStateNormal];
    }
}

- (void)updateTabBadges {
    HorizonRailTabButton *srvBtn = self.tabButtons[HorizonLauncherTabServers];
    if (self.servers.count > 0) {
        srvBtn.badgeLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)self.servers.count];
        srvBtn.badgeLabel.hidden = NO;
    } else {
        srvBtn.badgeLabel.hidden = YES;
    }
    HorizonRailTabButton *filesBtn = self.tabButtons[HorizonLauncherTabFiles];
    filesBtn.warningDot.hidden = self.resourcesReady;
}

#pragma mark - Navigation & Keyboard

- (void)selectTab:(HorizonLauncherTab)tab {
    [self.view endEditing:YES];
    self.activeTab = tab;
    for (NSUInteger i = 0; i < self.tabButtons.count; i++) {
        self.tabButtons[i].activeTab = ((NSInteger)i == tab);
        self.tabScrollViews[i].hidden = ((NSInteger)i != tab);
    }
}

- (void)onTabButtonTapped:(HorizonRailTabButton *)sender {
    [self selectTab:(HorizonLauncherTab)sender.tag];
}

- (void)onSummaryTileTapped:(UIControl *)sender {
    [self selectTab:(HorizonLauncherTab)sender.tag];
}

- (void)onKeyboardChange:(NSNotification *)note {
    CGRect kb = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect kbInView = [self.view convertRect:kb fromView:nil];
    for (UIScrollView *sv in self.tabScrollViews) {
        CGRect svFrame = [self.view convertRect:sv.frame fromView:sv.superview];
        CGFloat overlap = MAX(0.0, CGRectGetMaxY(svFrame) - CGRectGetMinY(kbInView));
        sv.contentInset = UIEdgeInsetsMake(0, 0, overlap + 12.0, 0);
        sv.scrollIndicatorInsets = sv.contentInset;
    }
}

- (void)onKeyboardHide:(NSNotification *)note {
    (void)note;
    for (UIScrollView *sv in self.tabScrollViews) {
        sv.contentInset = UIEdgeInsetsZero;
        sv.scrollIndicatorInsets = UIEdgeInsetsZero;
    }
}

#pragma mark - Nickname Editing

- (void)onNickEdited {
    NSString *live = [self.nickField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (live.length > 0) {
        self.footerNickLabel.text = live;
        NSString *initial = [[live substringToIndex:1] uppercaseString];
        self.footerAvatarLabel.text = initial;
        self.homeAvatarLabel.text = initial;
    }
    self.nickErrorLabel.hidden = YES;
}

- (BOOL)commitPlayerNameShowingError:(BOOL)showErr {
    NSString *candidate = [self.nickField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    char errBuf[256] = {0};
    if (horizon_ios_save_player_name(self.documentsDir.UTF8String, candidate.UTF8String, errBuf, sizeof(errBuf))) {
        self.playerName = candidate;
        self.nickErrorLabel.hidden = YES;
        [self updateProfileUI];
        return YES;
    }
    if (showErr) {
        self.nickErrorLabel.text = (errBuf[0] != '\0')
            ? [NSString stringWithUTF8String:errBuf]
            : @"Никнейм: 1–16 ASCII символов без пробелов";
        self.nickErrorLabel.hidden = NO;
    }
    return NO;
}

- (void)onNickCommit {
    [self commitPlayerNameShowingError:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - Server Editor & Actions

- (void)presentServerEditorAtIndex:(NSInteger)index {
    HorizonServerEditorViewController *editor = [[HorizonServerEditorViewController alloc] init];
    editor.serverIndex = index;
    editor.serversDatPath = self.serversDatPath;
    if (index >= 0 && (NSUInteger)index < self.servers.count) {
        NSDictionary *srv = self.servers[(NSUInteger)index];
        editor.initialName = srv[@"name"] ?: @"";
        editor.initialAddress = srv[@"ip"] ?: @"";
    }
    __weak typeof(self) weakSelf = self;
    void (^reload)(void) = ^{
        typeof(self) s = weakSelf;
        if (s == nil) return;
        [s reloadServers];
        [s updateTabBadges];
        [s pingAllServers];
    };
    editor.onSaved = reload;
    editor.onDeleted = reload;
    [self presentViewController:editor animated:YES completion:nil];
}

- (void)onAddServerTapped {
    [self presentServerEditorAtIndex:-1];
}

- (void)onEditServerTapped:(UIButton *)sender {
    [self presentServerEditorAtIndex:sender.tag];
}

#pragma mark - Launch Handoff

- (void)triggerLaunchWithQuickServer:(nullable NSString *)server quickWorld:(nullable NSString *)world {
    if (self.launching) return;
    [self.view endEditing:YES];

    if (!self.resourcesReady) {
        [self selectTab:HorizonLauncherTabFiles];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Ресурсы не найдены"
                                                                       message:@"Для запуска Horizon требуется папка Documents/resources/ с файлом horizon-resources.json. Импортируйте папку или .zip архив во вкладке «Файлы»."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Понятно" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    // Persist any pending nickname / graphics / control changes cleanly before launching.
    [self commitPlayerNameShowingError:NO];
    [self saveOptionsToDisk];
    [HorizonSettings.shared syncToBridge];
    if (server.length > 0) {
        HorizonSettings.shared.lastQuickServerAddress = server;
    }

    self.launching = YES;
    self.view.userInteractionEnabled = NO;
    self.playButton.hidden = YES;
    self.launchingLabel.hidden = NO;
    [self.launchSpinner startAnimating];

    [HorizonPreLauncherAppDelegate launchGameWithPlayerName:self.playerName
                                                quickServer:server
                                                 quickWorld:world];
}

- (void)onPlayButtonTapped {
    if (!self.resourcesReady) {
        [self selectTab:HorizonLauncherTabFiles];
        return;
    }
    [self triggerLaunchWithQuickServer:nil quickWorld:nil];
}

- (void)onJoinServerTapped:(UIButton *)sender {
    NSString *ip = sender.accessibilityIdentifier;
    if (ip.length == 0) return;
    [self triggerLaunchWithQuickServer:ip quickWorld:nil];
}

- (void)onOpenWorldTapped:(UIButton *)sender {
    NSString *folder = sender.accessibilityIdentifier;
    if (folder.length == 0) return;
    [self triggerLaunchWithQuickServer:nil quickWorld:folder];
}

#pragma mark - Files Import & Logs

- (void)onImportResourcesTapped:(UIButton *)sender {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Импорт ресурсов Horizon"
                                                                   message:@"Выберите папку с horizon-resources.json или .zip архив."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Выбрать папку" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        (void)action;
        [weakSelf presentDocumentPickerForPurpose:HorizonPickerPurposeResourcesFolder];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Выбрать .zip архив" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        (void)action;
        [weakSelf presentDocumentPickerForPurpose:HorizonPickerPurposeResourcesZip];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController != nil) {
        sheet.popoverPresentationController.sourceView = sender;
        sheet.popoverPresentationController.sourceRect = sender.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)onImportResourcePackTapped {
    [self presentDocumentPickerForPurpose:HorizonPickerPurposeResourcePackZip];
}

- (void)onImportShaderPackTapped {
    [self presentDocumentPickerForPurpose:HorizonPickerPurposeShaderPackZip];
}

- (void)presentDocumentPickerForPurpose:(HorizonPickerPurpose)purpose {
    self.pickerPurpose = purpose;
    UIDocumentPickerViewController *picker = nil;
    if (purpose == HorizonPickerPurposeResourcesFolder) {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP] asCopy:YES];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)setImportBusy:(BOOL)busy message:(nullable NSString *)message {
    self.importBusyBanner.hidden = !busy;
    if (message.length > 0) {
        self.importBusyLabel.text = message;
    }
}

- (void)showAlertTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"ОК" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (nullable NSString *)findResourcesRootInsideFolder:(NSString *)folderPath depth:(int)depth {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *candidate = [folderPath stringByAppendingPathComponent:@"horizon-resources.json"];
    if ([fm fileExistsAtPath:candidate]) {
        return folderPath;
    }
    if (depth >= 3) return nil;
    NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:folderPath error:nil];
    for (NSString *name in children) {
        if ([name hasPrefix:@"."] || [name isEqualToString:@"__MACOSX"]) continue;
        NSString *sub = [folderPath stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:sub isDirectory:&isDir] && isDir) {
            NSString *found = [self findResourcesRootInsideFolder:sub depth:depth + 1];
            if (found != nil) return found;
        }
    }
    return nil;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *picked = urls.firstObject;
    if (picked == nil) return;

    HorizonPickerPurpose purpose = self.pickerPurpose;
    if (purpose == HorizonPickerPurposeResourcePackZip || purpose == HorizonPickerPurposeShaderPackZip) {
        NSString *destFolder = (purpose == HorizonPickerPurposeResourcePackZip) ? self.resourcePacksDir : self.shaderPacksDir;
        [NSFileManager.defaultManager createDirectoryAtPath:destFolder withIntermediateDirectories:YES attributes:nil error:nil];
        BOOL scoped = [picked startAccessingSecurityScopedResource];
        NSString *destPath = [destFolder stringByAppendingPathComponent:picked.lastPathComponent];
        [NSFileManager.defaultManager removeItemAtPath:destPath error:nil];
        NSError *err = nil;
        BOOL ok = [NSFileManager.defaultManager copyItemAtURL:picked toURL:[NSURL fileURLWithPath:destPath] error:&err];
        if (scoped) [picked stopAccessingSecurityScopedResource];
        if (!ok) {
            [self showAlertTitle:@"Ошибка импорта" message:err.localizedDescription ?: @"Не удалось скопировать файл"];
        } else {
            [self rebuildFilesTab];
            [self showAlertTitle:@"Импорт завершён" message:[NSString stringWithFormat:@"Файл %@ добавлен.", picked.lastPathComponent]];
        }
        return;
    }

    if (purpose == HorizonPickerPurposeResourcesZip) {
        [self setImportBusy:YES message:@"Распаковка архива ресурсов…"];
        NSString *destDir = self.resourcesDir;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            BOOL scoped = [picked startAccessingSecurityScopedResource];
            char errBuf[256] = {0};
            int32_t count = horizon_ios_extract_resources_zip(
                picked.path.UTF8String,
                destDir.UTF8String,
                errBuf,
                sizeof(errBuf)
            );
            if (scoped) [picked stopAccessingSecurityScopedResource];
            NSString *errMsg = (errBuf[0] != '\0') ? [NSString stringWithUTF8String:errBuf] : @"Не удалось распаковать архив";
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) s = weakSelf;
                if (s == nil) return;
                [s setImportBusy:NO message:nil];
                if (count < 0) {
                    [s showAlertTitle:@"Ошибка импорта" message:errMsg];
                } else {
                    s.resourcesSizeCalculated = NO;
                    [s refreshResourcesSizeAsync];
                    [s showAlertTitle:@"Ресурсы импортированы"
                              message:[NSString stringWithFormat:@"Распаковано файлов: %d.", (int)count]];
                }
            });
        });
        return;
    }

    if (purpose == HorizonPickerPurposeResourcesFolder) {
        [self setImportBusy:YES message:@"Копирование папки ресурсов…"];
        NSString *destDir = self.resourcesDir;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            BOOL scoped = [picked startAccessingSecurityScopedResource];
            NSString *srcRoot = [weakSelf findResourcesRootInsideFolder:picked.path depth:0];
            NSError *err = nil;
            BOOL ok = NO;
            if (srcRoot != nil) {
                NSFileManager *fm = NSFileManager.defaultManager;
                [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
                NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:srcRoot error:&err];
                ok = (err == nil);
                for (NSString *name in items) {
                    if ([name hasPrefix:@"."]) continue;
                    NSString *srcItem = [srcRoot stringByAppendingPathComponent:name];
                    NSString *dstItem = [destDir stringByAppendingPathComponent:name];
                    [fm removeItemAtPath:dstItem error:nil];
                    if (![fm copyItemAtPath:srcItem toPath:dstItem error:&err]) {
                        ok = NO;
                        break;
                    }
                }
            }
            if (scoped) [picked stopAccessingSecurityScopedResource];
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) s = weakSelf;
                if (s == nil) return;
                [s setImportBusy:NO message:nil];
                if (srcRoot == nil) {
                    [s showAlertTitle:@"Ресурсы не найдены"
                              message:@"В выбранной папке (и вложенных папках) не найден файл horizon-resources.json."];
                } else if (!ok) {
                    [s showAlertTitle:@"Ошибка копирования" message:err.localizedDescription ?: @"Не удалось скопировать ресурсы"];
                } else {
                    s.resourcesSizeCalculated = NO;
                    [s refreshResourcesSizeAsync];
                    [s showAlertTitle:@"Ресурсы импортированы" message:@"Папка resources готова к запуску."];
                }
            });
        });
    }
}

- (void)onOpenLogsTapped {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSArray<NSURL *> *urls = [self availableLogURLsWithTitles:titles];
    if (urls.count == 0) return;

    HorizonLogViewerViewController *vc = [[HorizonLogViewerViewController alloc] init];
    vc.titles = titles;
    vc.fileURLs = urls;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)onShareLogsTapped:(UIButton *)sender {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSArray<NSURL *> *urls = [self availableLogURLsWithTitles:titles];
    if (urls.count == 0) return;

    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:urls
                                                                      applicationActivities:nil];
    if (avc.popoverPresentationController != nil) {
        avc.popoverPresentationController.sourceView = sender;
        avc.popoverPresentationController.sourceRect = sender.bounds;
    }
    [self presentViewController:avc animated:YES completion:nil];
}

@end
