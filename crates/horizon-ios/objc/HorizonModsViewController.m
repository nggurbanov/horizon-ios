// horizon-ios: native UIKit Mod & Pack Browser / Manager (Horizon Registry + Modrinth v2).
// Runs all network requests, checksum verification, and file I/O on background GCD queues
// so the UI stays 60-120 fps and never blocks the main thread or trips HangWatchdog.
// Trademark note: Modrinth is identified in plain text ("Modrinth") only; no logo artwork.

#import "HorizonModsViewController.h"
#import "HorizonIcons.h"
#import "HorizonL10n.h"
#include "horizon_bridge.h"

typedef NS_ENUM(NSInteger, HorizonModsSubtab) {
    HorizonModsSubtabMods = 0,
    HorizonModsSubtabResourcePacks = 1,
    HorizonModsSubtabShaders = 2,
    HorizonModsSubtabDataPacks = 3,
    HorizonModsSubtabInstalled = 4,
};

#pragma mark - Shared Dark Slate + Emerald Palette

static UIColor *hm_rgb(uint8_t r, uint8_t g, uint8_t b, CGFloat a) {
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

static UIColor *hm_stageBg(void)      { return hm_rgb(20, 25, 32, 1.0); }
static UIColor *hm_cardBg(void)       { return hm_rgb(27, 34, 44, 1.0); }
static UIColor *hm_elevatedBg(void)   { return hm_rgb(34, 43, 55, 1.0); }
static UIColor *hm_emerald(void)      { return hm_rgb(51, 189, 102, 1.0); }
static UIColor *hm_emeraldSoft(void)  { return hm_rgb(51, 189, 102, 0.16); }
static UIColor *hm_teal(void)         { return hm_rgb(56, 189, 248, 1.0); }
static UIColor *hm_tealSoft(void)     { return hm_rgb(56, 189, 248, 0.16); }
static UIColor *hm_amber(void)        { return hm_rgb(242, 169, 59, 1.0); }
static UIColor *hm_amberSoft(void)    { return hm_rgb(242, 169, 59, 0.16); }
static UIColor *hm_danger(void)       { return hm_rgb(229, 83, 75, 1.0); }
static UIColor *hm_dangerSoft(void)   { return hm_rgb(229, 83, 75, 0.16); }
static UIColor *hm_textPrimary(void)  { return hm_rgb(242, 246, 250, 1.0); }
static UIColor *hm_textSec(void)      { return hm_rgb(152, 166, 184, 1.0); }
static UIColor *hm_textMuted(void)    { return hm_rgb(109, 123, 142, 1.0); }
static UIColor *hm_hairline(void)     { return [UIColor colorWithWhite:1.0 alpha:0.08]; }

static NSString *hm_formatCount(uint64_t n) {
    if (n >= 1000000ULL) {
        return [NSString stringWithFormat:HL(@"%.1fM", @"%.1f млн"), n / 1000000.0];
    }
    if (n >= 1000ULL) {
        return [NSString stringWithFormat:HL(@"%.1fK", @"%.1f тыс."), n / 1000.0];
    }
    return [NSString stringWithFormat:@"%llu", (unsigned long long)n];
}

static NSString *hm_formatBytes(uint64_t bytes) {
    if (bytes >= 1024ULL * 1024ULL) {
        return [NSString stringWithFormat:HL(@"%.1f MB", @"%.1f МБ"), bytes / (1024.0 * 1024.0)];
    }
    if (bytes >= 1024ULL) {
        return [NSString stringWithFormat:HL(@"%.0f KB", @"%.0f КБ"), bytes / 1024.0];
    }
    if (bytes == 0) {
        return @"—";
    }
    return [NSString stringWithFormat:HL(@"%llu B", @"%llu Б"), (unsigned long long)bytes];
}

static NSString *hm_localizedCategory(NSString *raw) {
    if (raw.length == 0) return HL(@"All", @"Все");
    static NSDictionary<NSString *, NSArray<NSString *> *> *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"adventure": @[@"Adventure", @"Приключения"],
            @"decoration": @[@"Decoration", @"Декор"],
            @"economy": @[@"Economy", @"Экономика"],
            @"equipment": @[@"Equipment", @"Снаряжение"],
            @"food": @[@"Food", @"Еда"],
            @"game-mechanics": @[@"Mechanics", @"Механики"],
            @"library": @[@"Library", @"Библиотека"],
            @"magic": @[@"Magic", @"Магия"],
            @"management": @[@"Management", @"Управление"],
            @"minigame": @[@"Minigame", @"Мини-игры"],
            @"mobs": @[@"Mobs", @"Мобы"],
            @"optimization": @[@"Optimization", @"Оптимизация"],
            @"social": @[@"Social", @"Социальные"],
            @"storage": @[@"Storage", @"Хранение"],
            @"technology": @[@"Technology", @"Технологии"],
            @"transportation": @[@"Transport", @"Транспорт"],
            @"utility": @[@"Utility", @"Утилиты"],
            @"worldgen": @[@"Worldgen", @"Генерация"],
            @"vanilla-like": @[@"Vanilla-like", @"В стиле ваниллы"],
            @"realistic": @[@"Realistic", @"Реализм"],
            @"semi-realistic": @[@"Semi-realistic", @"Полуреализм"],
            @"simplistic": @[@"Simplistic", @"Простые"],
            @"cartoon": @[@"Cartoon", @"Мультяшные"],
            @"fantasy": @[@"Fantasy", @"Фэнтези"],
            @"themed": @[@"Themed", @"Тематические"],
            @"tweaks": @[@"Tweaks", @"Твики"],
            @"audio": @[@"Audio", @"Звуки"],
            @"blocks": @[@"Blocks", @"Блоки"],
            @"combat": @[@"Combat", @"Бой"],
            @"entities": @[@"Entities", @"Сущности"],
            @"environment": @[@"Environment", @"Окружение"],
            @"fonts": @[@"Fonts", @"Шрифты"],
            @"gui": @[@"GUI", @"Интерфейс"],
            @"items": @[@"Items", @"Предметы"],
            @"models": @[@"Models", @"Модели"],
            @"atmosphere": @[@"Atmosphere", @"Атмосфера"],
            @"bloom": @[@"Bloom", @"Свечение"],
            @"colored-lighting": @[@"Colored Light", @"Цветной свет"],
            @"foliage": @[@"Foliage", @"Листва"],
            @"path-tracing": @[@"Ray Tracing", @"Трассировка"],
            @"pbr": @[@"PBR", @"PBR"],
            @"reflections": @[@"Reflections", @"Отражения"],
            @"shadows": @[@"Shadows", @"Тени"],
            @"potato": @[@"Potato", @"Лёгкие"],
            @"low": @[@"Low", @"Низкие"],
            @"medium": @[@"Medium", @"Средние"],
            @"high": @[@"High", @"Высокие"],
            @"screenshot": @[@"Screenshot", @"Скриншотные"],
        };
    });
    NSArray<NSString *> *pair = map[raw.lowercaseString];
    if (pair != nil) {
        return HorizonIsRussian() ? pair[1] : pair[0];
    }
    return [[raw stringByReplacingOccurrencesOfString:@"-" withString:@" "] capitalizedString];
}

static NSString *hm_localizedSortTitle(NSString *sortKey) {
    if ([sortKey isEqualToString:@"relevance"]) return HL(@"Relevance", @"Релевантность");
    if ([sortKey isEqualToString:@"newest"])    return HL(@"Newest", @"Новые");
    if ([sortKey isEqualToString:@"updated"])   return HL(@"Updated", @"Обновлённые");
    return HL(@"Downloads", @"Популярные");
}

static NSString *hm_cleanMarkdown(NSString *raw) {
    if (raw.length == 0) return @"";
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *line in [raw componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *s = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        while ([s hasPrefix:@"#"]) {
            s = [[s substringFromIndex:1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        }
        s = [s stringByReplacingOccurrencesOfString:@"**" withString:@""];
        s = [s stringByReplacingOccurrencesOfString:@"__" withString:@""];
        s = [s stringByReplacingOccurrencesOfString:@"`" withString:@""];
        [out addObject:s];
    }
    return [out componentsJoinedByString:@"\n"];
}

static id _Nullable hm_parseOwnedCStringJSON(char *raw) {
    if (raw == NULL) return nil;
    NSData *data = [NSData dataWithBytes:raw length:strlen(raw)];
    horizon_ios_free_string(raw);
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

static NSString *hm_toJSONString(id obj) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (data == nil) return @"{}";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{}";
}

static UILabel *hm_makeBadge(NSString *text, UIColor *fg, UIColor *bg) {
    UILabel *lbl = [[UILabel alloc] init];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.text = [NSString stringWithFormat:@" %@ ", text];
    lbl.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    lbl.textColor = fg;
    lbl.backgroundColor = bg;
    lbl.layer.cornerRadius = 5.0;
    lbl.clipsToBounds = YES;
    [lbl setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [lbl setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return lbl;
}

#pragma mark - Async Cached Icon Loader

@interface HorizonModIconCache : NSObject
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *memCache;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) NSString *documentsDir;
- (instancetype)initWithDocumentsDir:(NSString *)documentsDir;
- (void)loadIconURL:(NSString *)url
      intoImageView:(UIImageView *)imageView
   placeholderLabel:(UILabel *)placeholderLabel
       fallbackChar:(NSString *)fallbackChar;
@end

@implementation HorizonModIconCache

- (instancetype)initWithDocumentsDir:(NSString *)documentsDir {
    self = [super init];
    if (self != nil) {
        _documentsDir = [documentsDir copy];
        _memCache = [[NSCache alloc] init];
        _memCache.countLimit = 180;
        _queue = dispatch_queue_create("dev.horizon.ios.mod-icons", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (void)loadIconURL:(NSString *)url
      intoImageView:(UIImageView *)imageView
   placeholderLabel:(UILabel *)placeholderLabel
       fallbackChar:(NSString *)fallbackChar {
    imageView.accessibilityIdentifier = url ?: @"";
    placeholderLabel.text = fallbackChar.length > 0 ? fallbackChar : @"?";

    if (url.length == 0) {
        imageView.image = nil;
        placeholderLabel.hidden = NO;
        return;
    }

    UIImage *cached = [self.memCache objectForKey:url];
    if (cached != nil) {
        imageView.image = cached;
        placeholderLabel.hidden = YES;
        return;
    }

    imageView.image = nil;
    placeholderLabel.hidden = NO;

    NSString *dir = self.documentsDir;
    NSString *targetURL = [url copy];
    __weak UIImageView *weakIV = imageView;
    __weak UILabel *weakPH = placeholderLabel;
    __weak typeof(self) weakSelf = self;

    dispatch_async(self.queue, ^{
        char *rawPath = horizon_ios_mods_icon_path(dir.UTF8String, targetURL.UTF8String);
        if (rawPath == NULL) return;
        NSString *path = [NSString stringWithUTF8String:rawPath];
        horizon_ios_free_string(rawPath);
        if (path.length == 0) return;

        UIImage *img = [UIImage imageWithContentsOfFile:path];
        if (img == nil) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = weakSelf;
            if (s != nil) {
                [s.memCache setObject:img forKey:targetURL];
            }
            UIImageView *iv = weakIV;
            UILabel *ph = weakPH;
            if (iv == nil || ph == nil) return;
            if ([iv.accessibilityIdentifier isEqualToString:targetURL]) {
                iv.image = img;
                ph.hidden = YES;
            }
        });
    });
}

@end

#pragma mark - Project Detail Modal Sheet

@interface HorizonModDetailViewController : UIViewController

@property (nonatomic, copy) NSString *documentsDir;
@property (nonatomic, copy) NSDictionary *seedItem;
@property (nonatomic, copy) NSString *selectedWorld;
@property (nonatomic, strong) HorizonModIconCache *iconCache;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@property (nonatomic, copy, nullable) void (^onInstallAction)(NSDictionary *item, void (^done)(BOOL ok, NSString * _Nullable err));
@property (nonatomic, copy, nullable) void (^onRemoveAction)(NSDictionary *item, void (^done)(BOOL ok, NSString * _Nullable err));

@property (nonatomic, strong) NSDictionary *details;
@property (nonatomic, strong) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, strong) UIStackView *bodyStack;
@property (nonatomic, strong) UIButton *primaryBtn;
@property (nonatomic, strong) UIButton *removeBtn;
@property (nonatomic, strong) UIActivityIndicatorView *actionSpinner;
@property (nonatomic, assign) BOOL actionBusy;

@end

@implementation HorizonModDetailViewController

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = hm_stageBg();

    // Top Header Bar
    UIView *header = [[UIView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.backgroundColor = hm_cardBg();
    [self.view addSubview:header];

    UILabel *titleLbl = [[UILabel alloc] init];
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
    titleLbl.text = self.seedItem[@"name"] ?: @"";
    titleLbl.font = [UIFont systemFontOfSize:16.5 weight:UIFontWeightBold];
    titleLbl.textColor = hm_textPrimary();
    titleLbl.lineBreakMode = NSLineBreakByTruncatingTail;
    [header addSubview:titleLbl];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [closeBtn setTitle:HL(@"Close", @"Закрыть") forState:UIControlStateNormal];
    [closeBtn setTitleColor:hm_textPrimary() forState:UIControlStateNormal];
    closeBtn.backgroundColor = hm_elevatedBg();
    closeBtn.layer.cornerRadius = 8.0;
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    closeBtn.contentEdgeInsets = UIEdgeInsetsMake(6.0, 12.0, 6.0, 12.0);
    [closeBtn addTarget:self action:@selector(onCloseTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:closeBtn];

    // Scrollable Body
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];

    self.bodyStack = [[UIStackView alloc] init];
    self.bodyStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.bodyStack.axis = UILayoutConstraintAxisVertical;
    self.bodyStack.spacing = 12.0;
    [scroll addSubview:self.bodyStack];

    self.loadingSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.loadingSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingSpinner.color = hm_emerald();
    self.loadingSpinner.hidesWhenStopped = YES;
    [header addSubview:self.loadingSpinner];

    // Bottom Action Bar
    UIView *footer = [[UIView alloc] init];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    footer.backgroundColor = hm_cardBg();
    [self.view addSubview:footer];

    UIView *footerLine = [[UIView alloc] init];
    footerLine.translatesAutoresizingMaskIntoConstraints = NO;
    footerLine.backgroundColor = hm_hairline();
    [footer addSubview:footerLine];

    self.removeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.removeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.removeBtn setTitle:HL(@"Remove", @"Удалить") forState:UIControlStateNormal];
    [self.removeBtn setTitleColor:hm_danger() forState:UIControlStateNormal];
    self.removeBtn.backgroundColor = hm_dangerSoft();
    self.removeBtn.layer.cornerRadius = 9.0;
    self.removeBtn.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    self.removeBtn.contentEdgeInsets = UIEdgeInsetsMake(8.0, 16.0, 8.0, 16.0);
    [self.removeBtn addTarget:self action:@selector(onRemoveTapped) forControlEvents:UIControlEventTouchUpInside];
    self.removeBtn.hidden = YES;
    [footer addSubview:self.removeBtn];

    self.primaryBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.primaryBtn.translatesAutoresizingMaskIntoConstraints = NO;
    self.primaryBtn.layer.cornerRadius = 9.0;
    self.primaryBtn.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightBold];
    self.primaryBtn.contentEdgeInsets = UIEdgeInsetsMake(8.0, 20.0, 8.0, 20.0);
    [self.primaryBtn addTarget:self action:@selector(onPrimaryTapped) forControlEvents:UIControlEventTouchUpInside];
    [footer addSubview:self.primaryBtn];

    self.actionSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.actionSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.actionSpinner.color = hm_emerald();
    self.actionSpinner.hidesWhenStopped = YES;
    [footer addSubview:self.actionSpinner];

    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:52.0],

        [titleLbl.leadingAnchor constraintEqualToAnchor:header.safeAreaLayoutGuide.leadingAnchor constant:16.0],
        [titleLbl.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [titleLbl.trailingAnchor constraintLessThanOrEqualToAnchor:self.loadingSpinner.leadingAnchor constant:-10.0],

        [self.loadingSpinner.trailingAnchor constraintEqualToAnchor:closeBtn.leadingAnchor constant:-10.0],
        [self.loadingSpinner.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [closeBtn.trailingAnchor constraintEqualToAnchor:header.safeAreaLayoutGuide.trailingAnchor constant:-14.0],
        [closeBtn.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:footer.topAnchor],

        [self.bodyStack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:14.0],
        [self.bodyStack.leadingAnchor constraintEqualToAnchor:scroll.safeAreaLayoutGuide.leadingAnchor constant:16.0],
        [self.bodyStack.trailingAnchor constraintEqualToAnchor:scroll.safeAreaLayoutGuide.trailingAnchor constant:-16.0],
        [self.bodyStack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-18.0],

        [footer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [footer.heightAnchor constraintEqualToConstant:56.0],

        [footerLine.topAnchor constraintEqualToAnchor:footer.topAnchor],
        [footerLine.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor],
        [footerLine.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor],
        [footerLine.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],

        [self.removeBtn.leadingAnchor constraintEqualToAnchor:footer.safeAreaLayoutGuide.leadingAnchor constant:16.0],
        [self.removeBtn.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],

        [self.primaryBtn.trailingAnchor constraintEqualToAnchor:footer.safeAreaLayoutGuide.trailingAnchor constant:-16.0],
        [self.primaryBtn.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],

        [self.actionSpinner.trailingAnchor constraintEqualToAnchor:self.primaryBtn.leadingAnchor constant:-10.0],
        [self.actionSpinner.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
    ]];

    self.details = self.seedItem;
    [self renderBody];
    [self fetchFullDetails];
}

- (void)fetchFullDetails {
    NSString *source = self.seedItem[@"source"] ?: @"horizon";
    NSString *projectId = self.seedItem[@"id"] ?: @"";
    NSString *kind = self.seedItem[@"kind"] ?: @"mod";
    if (projectId.length == 0) return;

    [self.loadingSpinner startAnimating];
    NSString *dir = self.documentsDir;
    NSString *world = self.selectedWorld ?: @"";
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        char *raw = horizon_ios_mods_details_json(
            dir.UTF8String,
            source.UTF8String,
            projectId.UTF8String,
            kind.UTF8String,
            world.UTF8String
        );
        id parsed = hm_parseOwnedCStringJSON(raw);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = weakSelf;
            if (s == nil) return;
            [s.loadingSpinner stopAnimating];
            if ([parsed isKindOfClass:NSDictionary.class] && [parsed[@"ok"] boolValue] && [parsed[@"details"] isKindOfClass:NSDictionary.class]) {
                s.details = parsed[@"details"];
                [s renderBody];
            }
        });
    });
}

- (UIView *)cardView {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = hm_cardBg();
    v.layer.cornerRadius = 12.0;
    v.layer.borderWidth = 1.0;
    v.layer.borderColor = hm_hairline().CGColor;
    return v;
}

- (void)renderBody {
    for (UIView *sub in [self.bodyStack.arrangedSubviews copy]) {
        [self.bodyStack removeArrangedSubview:sub];
        [sub removeFromSuperview];
    }

    NSDictionary *d = self.details ?: @{};
    NSString *name = d[@"name"] ?: @"";
    NSString *author = d[@"author"] ?: @"";
    NSString *source = d[@"source"] ?: @"horizon";
    NSString *license = d[@"license"] ?: @"";
    NSString *version = d[@"version"] ?: @"";
    NSString *filename = d[@"filename"] ?: @"";
    NSString *checksumNote = d[@"checksum_note"] ?: @"";
    NSString *published = d[@"published"] ?: @"";
    NSString *summary = d[@"summary"] ?: @"";
    NSString *description = d[@"description"] ?: @"";
    NSString *iconURL = d[@"icon_url"] ?: @"";
    NSString *blockedReason = d[@"blocked_reason"] ?: @"";
    NSString *revokedReason = d[@"revoked_reason"] ?: @"";
    uint64_t downloads = [d[@"downloads"] unsignedLongLongValue];
    uint64_t fileSize = [d[@"file_size"] unsignedLongLongValue];
    BOOL isWasm = [d[@"is_wasm"] boolValue];
    BOOL desktopOnly = [d[@"desktop_only"] boolValue];
    BOOL heavyGpu = [d[@"heavy_gpu"] boolValue];
    BOOL official = [d[@"official"] boolValue];
    BOOL installable = [d[@"installable"] boolValue];
    BOOL installed = [d[@"installed"] boolValue];
    BOOL updateAvailable = [d[@"update_available"] boolValue];
    NSString *kind = d[@"kind"] ?: @"mod";
    NSArray<NSString *> *caps = [d[@"capabilities"] isKindOfClass:NSArray.class] ? d[@"capabilities"] : @[];

    // 1. Hero card
    UIView *hero = [self cardView];
    UIView *iconBox = [[UIView alloc] init];
    iconBox.translatesAutoresizingMaskIntoConstraints = NO;
    iconBox.backgroundColor = hm_elevatedBg();
    iconBox.layer.cornerRadius = 12.0;
    iconBox.clipsToBounds = YES;
    [hero addSubview:iconBox];

    UILabel *iconPH = [[UILabel alloc] init];
    iconPH.translatesAutoresizingMaskIntoConstraints = NO;
    iconPH.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold];
    iconPH.textColor = hm_emerald();
    iconPH.textAlignment = NSTextAlignmentCenter;
    [iconBox addSubview:iconPH];

    UIImageView *iconIV = [[UIImageView alloc] init];
    iconIV.translatesAutoresizingMaskIntoConstraints = NO;
    iconIV.contentMode = UIViewContentModeScaleAspectFill;
    [iconBox addSubview:iconIV];

    NSString *initial = name.length > 0 ? [[name substringToIndex:1] uppercaseString] : @"H";
    [self.iconCache loadIconURL:iconURL intoImageView:iconIV placeholderLabel:iconPH fallbackChar:initial];

    UILabel *nameLbl = [[UILabel alloc] init];
    nameLbl.translatesAutoresizingMaskIntoConstraints = NO;
    nameLbl.text = name;
    nameLbl.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightBold];
    nameLbl.textColor = hm_textPrimary();
    nameLbl.numberOfLines = 2;
    [hero addSubview:nameLbl];

    NSString *sourceLabel = [source isEqualToString:@"modrinth"] ? @"Modrinth" : @"Horizon Registry";
    NSMutableArray<NSString *> *metaParts = [NSMutableArray array];
    if (author.length > 0) [metaParts addObject:[NSString stringWithFormat:HL(@"by %@", @"от %@"), author]];
    [metaParts addObject:sourceLabel];
    if (downloads > 0) [metaParts addObject:[NSString stringWithFormat:HL(@"%@ downloads", @"%@ скач."), hm_formatCount(downloads)]];
    if (license.length > 0) [metaParts addObject:license];

    UILabel *metaLbl = [[UILabel alloc] init];
    metaLbl.translatesAutoresizingMaskIntoConstraints = NO;
    metaLbl.text = [metaParts componentsJoinedByString:@" · "];
    metaLbl.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    metaLbl.textColor = hm_textSec();
    metaLbl.numberOfLines = 2;
    [hero addSubview:metaLbl];

    UIStackView *badges = [[UIStackView alloc] init];
    badges.translatesAutoresizingMaskIntoConstraints = NO;
    badges.axis = UILayoutConstraintAxisHorizontal;
    badges.spacing = 6.0;
    if (desktopOnly) {
        [badges addArrangedSubview:hm_makeBadge(HL(@"Desktop only", @"Только ПК"), hm_amber(), hm_amberSoft())];
    } else if ([kind isEqualToString:@"mod"]) {
        if (isWasm) {
            [badges addArrangedSubview:hm_makeBadge(@"WASM · Pulley", hm_emerald(), hm_emeraldSoft())];
        } else {
            [badges addArrangedSubview:hm_makeBadge(HL(@"Content", @"Контент"), hm_teal(), hm_tealSoft())];
        }
    } else if ([kind isEqualToString:@"shader"]) {
        [badges addArrangedSubview:hm_makeBadge(HL(@"Shader", @"Шейдер"), hm_teal(), hm_tealSoft())];
        if (heavyGpu) {
            [badges addArrangedSubview:hm_makeBadge(HL(@"Heavy GPU", @"Высокая нагрузка GPU"), hm_amber(), hm_amberSoft())];
        }
    }
    if (official) {
        [badges addArrangedSubview:hm_makeBadge(HL(@"Official", @"Официальный"), hm_emerald(), hm_emeraldSoft())];
    }
    UIView *spacer = [[UIView alloc] init];
    [badges addArrangedSubview:spacer];
    [hero addSubview:badges];

    [NSLayoutConstraint activateConstraints:@[
        [iconBox.topAnchor constraintEqualToAnchor:hero.topAnchor constant:14.0],
        [iconBox.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:14.0],
        [iconBox.widthAnchor constraintEqualToConstant:56.0],
        [iconBox.heightAnchor constraintEqualToConstant:56.0],
        [iconBox.bottomAnchor constraintLessThanOrEqualToAnchor:hero.bottomAnchor constant:-14.0],

        [iconPH.centerXAnchor constraintEqualToAnchor:iconBox.centerXAnchor],
        [iconPH.centerYAnchor constraintEqualToAnchor:iconBox.centerYAnchor],
        [iconIV.topAnchor constraintEqualToAnchor:iconBox.topAnchor],
        [iconIV.leadingAnchor constraintEqualToAnchor:iconBox.leadingAnchor],
        [iconIV.trailingAnchor constraintEqualToAnchor:iconBox.trailingAnchor],
        [iconIV.bottomAnchor constraintEqualToAnchor:iconBox.bottomAnchor],

        [nameLbl.topAnchor constraintEqualToAnchor:hero.topAnchor constant:12.0],
        [nameLbl.leadingAnchor constraintEqualToAnchor:iconBox.trailingAnchor constant:12.0],
        [nameLbl.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor constant:-14.0],

        [metaLbl.topAnchor constraintEqualToAnchor:nameLbl.bottomAnchor constant:3.0],
        [metaLbl.leadingAnchor constraintEqualToAnchor:nameLbl.leadingAnchor],
        [metaLbl.trailingAnchor constraintEqualToAnchor:nameLbl.trailingAnchor],

        [badges.topAnchor constraintEqualToAnchor:metaLbl.bottomAnchor constant:7.0],
        [badges.leadingAnchor constraintEqualToAnchor:nameLbl.leadingAnchor],
        [badges.trailingAnchor constraintEqualToAnchor:nameLbl.trailingAnchor],
        [badges.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor constant:-12.0],
    ]];
    [self.bodyStack addArrangedSubview:hero];

    // 2. Takedown / Blocked notice
    if (revokedReason.length > 0 || blockedReason.length > 0) {
        UIView *warn = [[UIView alloc] init];
        warn.backgroundColor = revokedReason.length > 0 ? hm_dangerSoft() : hm_amberSoft();
        warn.layer.cornerRadius = 10.0;
        warn.layer.borderWidth = 1.0;
        warn.layer.borderColor = (revokedReason.length > 0 ? hm_danger() : hm_amber()).CGColor;
        UILabel *wl = [[UILabel alloc] init];
        wl.translatesAutoresizingMaskIntoConstraints = NO;
        wl.text = revokedReason.length > 0
            ? [NSString stringWithFormat:HL(@"Taken down: %@", @"Удалён из реестра: %@"), revokedReason]
            : blockedReason;
        wl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
        wl.textColor = revokedReason.length > 0 ? hm_danger() : hm_amber();
        wl.numberOfLines = 0;
        [warn addSubview:wl];
        [NSLayoutConstraint activateConstraints:@[
            [wl.topAnchor constraintEqualToAnchor:warn.topAnchor constant:10.0],
            [wl.leadingAnchor constraintEqualToAnchor:warn.leadingAnchor constant:12.0],
            [wl.trailingAnchor constraintEqualToAnchor:warn.trailingAnchor constant:-12.0],
            [wl.bottomAnchor constraintEqualToAnchor:warn.bottomAnchor constant:-10.0],
        ]];
        [self.bodyStack addArrangedSubview:warn];
    }

    // 3. Package & Integrity Metadata card
    UIView *infoCard = [self cardView];
    UIStackView *infoStack = [[UIStackView alloc] init];
    infoStack.translatesAutoresizingMaskIntoConstraints = NO;
    infoStack.axis = UILayoutConstraintAxisVertical;
    infoStack.spacing = 6.0;
    [infoCard addSubview:infoStack];
    [NSLayoutConstraint activateConstraints:@[
        [infoStack.topAnchor constraintEqualToAnchor:infoCard.topAnchor constant:12.0],
        [infoStack.leadingAnchor constraintEqualToAnchor:infoCard.leadingAnchor constant:14.0],
        [infoStack.trailingAnchor constraintEqualToAnchor:infoCard.trailingAnchor constant:-14.0],
        [infoStack.bottomAnchor constraintEqualToAnchor:infoCard.bottomAnchor constant:-12.0],
    ]];

    void (^addKV)(NSString *, NSString *) = ^(NSString *k, NSString *v) {
        if (v.length == 0) return;
        UIView *row = [[UIView alloc] init];
        UILabel *kl = [[UILabel alloc] init];
        kl.translatesAutoresizingMaskIntoConstraints = NO;
        kl.text = k;
        kl.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
        kl.textColor = hm_textMuted();
        [row addSubview:kl];

        UILabel *vl = [[UILabel alloc] init];
        vl.translatesAutoresizingMaskIntoConstraints = NO;
        vl.text = v;
        vl.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightSemibold];
        vl.textColor = hm_textPrimary();
        vl.textAlignment = NSTextAlignmentRight;
        vl.numberOfLines = 2;
        [row addSubview:vl];

        [NSLayoutConstraint activateConstraints:@[
            [kl.topAnchor constraintEqualToAnchor:row.topAnchor],
            [kl.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [kl.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor],
            [vl.topAnchor constraintEqualToAnchor:row.topAnchor],
            [vl.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [vl.leadingAnchor constraintGreaterThanOrEqualToAnchor:kl.trailingAnchor constant:12.0],
            [vl.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        ]];
        [infoStack addArrangedSubview:row];
    };

    addKV(HL(@"Version", @"Версия"), version.length > 0 ? version : @"—");
    if (filename.length > 0) addKV(HL(@"File", @"Файл"), filename);
    if (fileSize > 0) addKV(HL(@"Size", @"Размер"), hm_formatBytes(fileSize));
    if (published.length > 0) addKV(HL(@"Published", @"Опубликовано"), published);
    if (checksumNote.length > 0) addKV(HL(@"Integrity", @"Проверка"), checksumNote);
    [self.bodyStack addArrangedSubview:infoCard];

    // 4. WASM / Mod Capabilities card
    if ([kind isEqualToString:@"mod"] && !desktopOnly) {
        UIView *capCard = [self cardView];
        UIStackView *capStack = [[UIStackView alloc] init];
        capStack.translatesAutoresizingMaskIntoConstraints = NO;
        capStack.axis = UILayoutConstraintAxisVertical;
        capStack.spacing = 4.0;
        [capCard addSubview:capStack];
        [NSLayoutConstraint activateConstraints:@[
            [capStack.topAnchor constraintEqualToAnchor:capCard.topAnchor constant:11.0],
            [capStack.leadingAnchor constraintEqualToAnchor:capCard.leadingAnchor constant:14.0],
            [capStack.trailingAnchor constraintEqualToAnchor:capCard.trailingAnchor constant:-14.0],
            [capStack.bottomAnchor constraintEqualToAnchor:capCard.bottomAnchor constant:-11.0],
        ]];
        UILabel *capHead = [[UILabel alloc] init];
        capHead.text = HL(@"PERMISSIONS & RUNTIME", @"ПРАВА И СРЕДА ВЫПОЛНЕНИЯ");
        capHead.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
        capHead.textColor = hm_textMuted();
        [capStack addArrangedSubview:capHead];

        if (isWasm) {
            UILabel *pulleyLbl = [[UILabel alloc] init];
            pulleyLbl.text = HL(@"Runs sandboxed in Wasmtime Pulley64 interpreter (no JIT required on iOS).",
                                @"Работает в песочнице интерпретатора Wasmtime Pulley64 (JIT на iOS не требуется).");
            pulleyLbl.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
            pulleyLbl.textColor = hm_emerald();
            pulleyLbl.numberOfLines = 0;
            [capStack addArrangedSubview:pulleyLbl];
        }
        if (caps.count == 0) {
            UILabel *cl = [[UILabel alloc] init];
            cl.text = HL(@"Asks for no special permissions beyond its own log.",
                         @"Не запрашивает дополнительных разрешений кроме собственного лога.");
            cl.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
            cl.textColor = hm_textSec();
            cl.numberOfLines = 0;
            [capStack addArrangedSubview:cl];
        } else {
            for (NSString *cap in caps) {
                UILabel *cl = [[UILabel alloc] init];
                cl.text = [NSString stringWithFormat:@"• %@", cap];
                cl.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
                cl.textColor = hm_textSec();
                cl.numberOfLines = 0;
                [capStack addArrangedSubview:cl];
            }
        }
        [self.bodyStack addArrangedSubview:capCard];
    }

    // 5. Description Card
    NSString *bodyText = hm_cleanMarkdown(description.length > 0 ? description : summary);
    if (bodyText.length > 0) {
        UIView *descCard = [self cardView];
        UILabel *dl = [[UILabel alloc] init];
        dl.translatesAutoresizingMaskIntoConstraints = NO;
        dl.text = bodyText;
        dl.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
        dl.textColor = hm_textPrimary();
        dl.numberOfLines = 0;
        [descCard addSubview:dl];
        [NSLayoutConstraint activateConstraints:@[
            [dl.topAnchor constraintEqualToAnchor:descCard.topAnchor constant:12.0],
            [dl.leadingAnchor constraintEqualToAnchor:descCard.leadingAnchor constant:14.0],
            [dl.trailingAnchor constraintEqualToAnchor:descCard.trailingAnchor constant:-14.0],
            [dl.bottomAnchor constraintEqualToAnchor:descCard.bottomAnchor constant:-12.0],
        ]];
        [self.bodyStack addArrangedSubview:descCard];
    }

    // Footer buttons state
    self.removeBtn.hidden = !installed;
    self.removeBtn.enabled = !self.actionBusy;

    if (self.actionBusy) {
        [self.primaryBtn setTitle:HL(@"Installing…", @"Установка…") forState:UIControlStateNormal];
        [self.primaryBtn setTitleColor:hm_textSec() forState:UIControlStateNormal];
        self.primaryBtn.backgroundColor = hm_elevatedBg();
        self.primaryBtn.enabled = NO;
        [self.actionSpinner startAnimating];
    } else {
        [self.actionSpinner stopAnimating];
        if (desktopOnly) {
            [self.primaryBtn setTitle:HL(@"Desktop only", @"Только ПК") forState:UIControlStateNormal];
            [self.primaryBtn setTitleColor:hm_amber() forState:UIControlStateNormal];
            self.primaryBtn.backgroundColor = hm_amberSoft();
            self.primaryBtn.enabled = NO;
        } else if (!installable) {
            [self.primaryBtn setTitle:HL(@"Unavailable", @"Недоступно") forState:UIControlStateNormal];
            [self.primaryBtn setTitleColor:hm_textMuted() forState:UIControlStateNormal];
            self.primaryBtn.backgroundColor = hm_elevatedBg();
            self.primaryBtn.enabled = NO;
        } else if (installed && updateAvailable) {
            [self.primaryBtn setTitle:HL(@"Update", @"Обновить") forState:UIControlStateNormal];
            [self.primaryBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            self.primaryBtn.backgroundColor = hm_emerald();
            self.primaryBtn.enabled = YES;
        } else if (installed) {
            [self.primaryBtn setTitle:HL(@"Installed ✓", @"Установлено ✓") forState:UIControlStateNormal];
            [self.primaryBtn setTitleColor:hm_emerald() forState:UIControlStateNormal];
            self.primaryBtn.backgroundColor = hm_emeraldSoft();
            self.primaryBtn.enabled = NO;
        } else {
            [self.primaryBtn setTitle:HL(@"Install", @"Установить") forState:UIControlStateNormal];
            [self.primaryBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            self.primaryBtn.backgroundColor = hm_emerald();
            self.primaryBtn.enabled = YES;
        }
    }
}

- (void)onCloseTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onPrimaryTapped {
    if (self.actionBusy || self.onInstallAction == nil) return;
    self.actionBusy = YES;
    [self renderBody];
    __weak typeof(self) weakSelf = self;
    self.onInstallAction(self.details ?: self.seedItem, ^(BOOL ok, NSString * _Nullable err) {
        typeof(self) s = weakSelf;
        if (s == nil) return;
        s.actionBusy = NO;
        if (ok) {
            NSMutableDictionary *m = [s.details mutableCopy] ?: [NSMutableDictionary dictionary];
            m[@"installed"] = @YES;
            m[@"update_available"] = @NO;
            s.details = m;
            [s renderBody];
        } else {
            [s renderBody];
            UIAlertController *a = [UIAlertController alertControllerWithTitle:HL(@"Install Failed", @"Ошибка установки")
                                                                       message:err ?: HL(@"Could not install pack.", @"Не удалось установить пакет.")
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:HL(@"OK", @"ОК") style:UIAlertActionStyleDefault handler:nil]];
            [s presentViewController:a animated:YES completion:nil];
        }
    });
}

- (void)onRemoveTapped {
    if (self.actionBusy || self.onRemoveAction == nil) return;
    NSString *name = self.details[@"name"] ?: @"";
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:HL(@"Remove Pack?", @"Удалить пакет?")
                                                                     message:[NSString stringWithFormat:HL(@"Remove \"%@\" from your device?", @"Удалить «%@» с устройства?"), name]
                                                              preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:HL(@"Remove", @"Удалить") style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        (void)action;
        typeof(self) s = weakSelf;
        if (s == nil) return;
        s.actionBusy = YES;
        [s renderBody];
        s.onRemoveAction(s.details ?: s.seedItem, ^(BOOL ok, NSString * _Nullable err) {
            typeof(self) s2 = weakSelf;
            if (s2 == nil) return;
            s2.actionBusy = NO;
            if (ok) {
                NSMutableDictionary *m = [s2.details mutableCopy] ?: [NSMutableDictionary dictionary];
                m[@"installed"] = @NO;
                m[@"update_available"] = @NO;
                s2.details = m;
                [s2 renderBody];
            } else {
                [s2 renderBody];
                UIAlertController *a = [UIAlertController alertControllerWithTitle:HL(@"Remove Failed", @"Ошибка удаления")
                                                                           message:err ?: HL(@"Could not remove pack.", @"Не удалось удалить пакет.")
                                                                    preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:HL(@"OK", @"ОК") style:UIAlertActionStyleDefault handler:nil]];
                [s2 presentViewController:a animated:YES completion:nil];
            }
        });
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:HL(@"Cancel", @"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

@end

#pragma mark - Catalog Row Cell

@interface HorizonCatalogCell : UITableViewCell
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIView *iconBox;
@property (nonatomic, strong) UILabel *iconPlaceholder;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UIStackView *badgeStack;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, strong) UIActivityIndicatorView *busySpinner;
@property (nonatomic, copy, nullable) void (^onActionTapped)(void);
@end

@implementation HorizonCatalogCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self != nil) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _card = [[UIView alloc] init];
        _card.translatesAutoresizingMaskIntoConstraints = NO;
        _card.backgroundColor = hm_cardBg();
        _card.layer.cornerRadius = 12.0;
        _card.layer.borderWidth = 1.0;
        _card.layer.borderColor = hm_hairline().CGColor;
        [self.contentView addSubview:_card];

        _iconBox = [[UIView alloc] init];
        _iconBox.translatesAutoresizingMaskIntoConstraints = NO;
        _iconBox.backgroundColor = hm_elevatedBg();
        _iconBox.layer.cornerRadius = 10.0;
        _iconBox.clipsToBounds = YES;
        [_card addSubview:_iconBox];

        _iconPlaceholder = [[UILabel alloc] init];
        _iconPlaceholder.translatesAutoresizingMaskIntoConstraints = NO;
        _iconPlaceholder.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightBold];
        _iconPlaceholder.textColor = hm_emerald();
        _iconPlaceholder.textAlignment = NSTextAlignmentCenter;
        [_iconBox addSubview:_iconPlaceholder];

        _iconView = [[UIImageView alloc] init];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _iconView.contentMode = UIViewContentModeScaleAspectFill;
        [_iconBox addSubview:_iconView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
        _titleLabel.textColor = hm_textPrimary();
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_card addSubview:_titleLabel];

        _metaLabel = [[UILabel alloc] init];
        _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _metaLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightMedium];
        _metaLabel.textColor = hm_textMuted();
        _metaLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_card addSubview:_metaLabel];

        _summaryLabel = [[UILabel alloc] init];
        _summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _summaryLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
        _summaryLabel.textColor = hm_textSec();
        _summaryLabel.numberOfLines = 2;
        [_card addSubview:_summaryLabel];

        _badgeStack = [[UIStackView alloc] init];
        _badgeStack.translatesAutoresizingMaskIntoConstraints = NO;
        _badgeStack.axis = UILayoutConstraintAxisHorizontal;
        _badgeStack.spacing = 5.0;
        [_card addSubview:_badgeStack];

        _actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _actionButton.translatesAutoresizingMaskIntoConstraints = NO;
        _actionButton.layer.cornerRadius = 8.0;
        _actionButton.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
        _actionButton.contentEdgeInsets = UIEdgeInsetsMake(7.0, 12.0, 7.0, 12.0);
        [_actionButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_actionButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_actionButton addTarget:self action:@selector(handleActionTap) forControlEvents:UIControlEventTouchUpInside];
        [_card addSubview:_actionButton];

        _busySpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _busySpinner.translatesAutoresizingMaskIntoConstraints = NO;
        _busySpinner.color = hm_emerald();
        _busySpinner.hidesWhenStopped = YES;
        [_card addSubview:_busySpinner];

        [NSLayoutConstraint activateConstraints:@[
            [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4.0],
            [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4.0],

            [_iconBox.topAnchor constraintEqualToAnchor:_card.topAnchor constant:11.0],
            [_iconBox.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:12.0],
            [_iconBox.widthAnchor constraintEqualToConstant:44.0],
            [_iconBox.heightAnchor constraintEqualToConstant:44.0],
            [_iconBox.bottomAnchor constraintLessThanOrEqualToAnchor:_card.bottomAnchor constant:-11.0],

            [_iconPlaceholder.centerXAnchor constraintEqualToAnchor:_iconBox.centerXAnchor],
            [_iconPlaceholder.centerYAnchor constraintEqualToAnchor:_iconBox.centerYAnchor],
            [_iconView.topAnchor constraintEqualToAnchor:_iconBox.topAnchor],
            [_iconView.leadingAnchor constraintEqualToAnchor:_iconBox.leadingAnchor],
            [_iconView.trailingAnchor constraintEqualToAnchor:_iconBox.trailingAnchor],
            [_iconView.bottomAnchor constraintEqualToAnchor:_iconBox.bottomAnchor],

            [_titleLabel.topAnchor constraintEqualToAnchor:_card.topAnchor constant:9.0],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconBox.trailingAnchor constant:11.0],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_actionButton.leadingAnchor constant:-10.0],

            [_metaLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:1.0],
            [_metaLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_metaLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_actionButton.leadingAnchor constant:-10.0],

            [_summaryLabel.topAnchor constraintEqualToAnchor:_metaLabel.bottomAnchor constant:3.0],
            [_summaryLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_summaryLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_actionButton.leadingAnchor constant:-10.0],

            [_badgeStack.topAnchor constraintEqualToAnchor:_summaryLabel.bottomAnchor constant:5.0],
            [_badgeStack.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_badgeStack.trailingAnchor constraintLessThanOrEqualToAnchor:_actionButton.leadingAnchor constant:-10.0],
            [_badgeStack.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-9.0],

            [_actionButton.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-12.0],
            [_actionButton.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],

            [_busySpinner.centerXAnchor constraintEqualToAnchor:_actionButton.centerXAnchor],
            [_busySpinner.centerYAnchor constraintEqualToAnchor:_actionButton.centerYAnchor],
        ]];
    }
    return self;
}

- (void)handleActionTap {
    if (self.onActionTapped != nil) {
        self.onActionTapped();
    }
}

@end

#pragma mark - Main HorizonModsViewController

@interface HorizonModsViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>

@property (nonatomic, copy) NSString *documentsDir;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@property (nonatomic, strong) HorizonModIconCache *iconCache;
@property (nonatomic, assign) BOOL hasActivatedOnce;

// Navigation & filter state
@property (nonatomic, assign) HorizonModsSubtab activeSubtab;
@property (nonatomic, copy) NSString *sourceForMods;
@property (nonatomic, copy) NSString *sourceForRP;
@property (nonatomic, copy) NSString *sourceForDP;
@property (nonatomic, copy) NSString *searchText;
@property (nonatomic, copy) NSString *selectedCategory;
@property (nonatomic, copy) NSString *selectedSort;
@property (nonatomic, assign) BOOL showDesktopOnly;
@property (nonatomic, copy) NSString *selectedWorld;

// Catalog data
@property (nonatomic, assign) NSUInteger searchGeneration;
@property (nonatomic, assign) BOOL catalogLoading;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *catalogItems;
@property (nonatomic, assign) NSUInteger catalogTotal;
@property (nonatomic, copy) NSArray<NSString *> *availableCategories;
@property (nonatomic, copy) NSString *catalogBanner;
@property (nonatomic, copy) NSString *catalogError;
@property (nonatomic, strong) NSMutableSet<NSString *> *busyProjectKeys;

// Installed data
@property (nonatomic, copy) NSDictionary *installedOverview;
@property (nonatomic, copy) NSArray<NSDictionary *> *availableUpdates;
@property (nonatomic, assign) BOOL checkingUpdates;
@property (nonatomic, assign) BOOL updatingAll;

// UI
@property (nonatomic, strong) UILabel *headerTitleLabel;
@property (nonatomic, strong) NSArray<UIButton *> *subtabButtons;

// Catalog UI
@property (nonatomic, strong) UIView *catalogContainer;
@property (nonatomic, strong) UISegmentedControl *sourceSegmented;
@property (nonatomic, strong) UILabel *sourceStaticPill;
@property (nonatomic, strong) UIButton *desktopToggleBtn;
@property (nonatomic, strong) UIButton *worldSelectorBtn;
@property (nonatomic, strong) UITextField *searchField;
@property (nonatomic, strong) UIButton *sortButton;
@property (nonatomic, strong) UIScrollView *categoryScroll;
@property (nonatomic, strong) UIStackView *categoryStack;
@property (nonatomic, strong) UIView *bannerBox;
@property (nonatomic, strong) UILabel *bannerLabel;
@property (nonatomic, strong) UIButton *bannerActionBtn;
@property (nonatomic, strong) UITableView *catalogTable;
@property (nonatomic, strong) UIRefreshControl *refreshControl;
@property (nonatomic, strong) UIActivityIndicatorView *catalogSpinner;
@property (nonatomic, strong) UILabel *emptyStateLabel;

// Installed UI
@property (nonatomic, strong) UIScrollView *installedScroll;
@property (nonatomic, strong) UIStackView *installedStack;

@end

@implementation HorizonModsViewController

- (instancetype)initWithDocumentsDir:(NSString *)documentsDir {
    self = [super initWithNibName:nil bundle:nil];
    if (self != nil) {
        _documentsDir = [documentsDir copy];
        _ioQueue = dispatch_queue_create("dev.horizon.ios.mods-io", DISPATCH_QUEUE_SERIAL);
        _iconCache = [[HorizonModIconCache alloc] initWithDocumentsDir:_documentsDir];
        _activeSubtab = HorizonModsSubtabMods;
        _sourceForMods = @"horizon";
        _sourceForRP = @"horizon";
        _sourceForDP = @"horizon";
        _searchText = @"";
        _selectedCategory = @"";
        _selectedSort = @"downloads";
        _selectedWorld = @"";
        _catalogItems = [NSMutableArray array];
        _availableCategories = @[];
        _busyProjectKeys = [NSMutableSet set];
        _availableUpdates = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = hm_stageBg();
    [self buildUI];
    [self updateSubtabPills];
    [self updateControlsVisibility];
    [self refreshInstalledAndCheckUpdates:NO];
}

- (void)activateIfNeeded {
    if (!self.hasActivatedOnce) {
        self.hasActivatedOnce = YES;
        [self refreshInstalledAndCheckUpdates:YES];
        [self runSearchReset:YES forceRefresh:NO];
    }
}

#pragma mark - Helpers for active subtab

- (NSString *)activeKindString {
    switch (self.activeSubtab) {
        case HorizonModsSubtabMods:          return @"mod";
        case HorizonModsSubtabResourcePacks: return @"resourcepack";
        case HorizonModsSubtabShaders:       return @"shader";
        case HorizonModsSubtabDataPacks:     return @"datapack";
        case HorizonModsSubtabInstalled:
        default:                             return @"mod";
    }
}

- (NSString *)activeSourceString {
    switch (self.activeSubtab) {
        case HorizonModsSubtabMods:          return self.sourceForMods;
        case HorizonModsSubtabResourcePacks: return self.sourceForRP;
        case HorizonModsSubtabShaders:       return @"horizon";
        case HorizonModsSubtabDataPacks:     return self.sourceForDP;
        case HorizonModsSubtabInstalled:
        default:                             return @"horizon";
    }
}

- (void)setActiveSourceString:(NSString *)src {
    switch (self.activeSubtab) {
        case HorizonModsSubtabMods:          self.sourceForMods = src; break;
        case HorizonModsSubtabResourcePacks: self.sourceForRP = src; break;
        case HorizonModsSubtabDataPacks:     self.sourceForDP = src; break;
        default: break;
    }
}

- (NSString *)busyKeyForSource:(NSString *)source projectId:(NSString *)projectId {
    return [NSString stringWithFormat:@"%@:%@", source ?: @"", projectId ?: @""];
}

#pragma mark - Build Layout

- (void)buildUI {
    // 1. Header + 5 Subtabs Pill Strip
    self.headerTitleLabel = [[UILabel alloc] init];
    self.headerTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerTitleLabel.text = HL(@"Mods & Packs", @"Моды и паки");
    self.headerTitleLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
    self.headerTitleLabel.textColor = hm_textPrimary();
    [self.view addSubview:self.headerTitleLabel];

    UIScrollView *subtabScroll = [[UIScrollView alloc] init];
    subtabScroll.translatesAutoresizingMaskIntoConstraints = NO;
    subtabScroll.showsHorizontalScrollIndicator = NO;
    [self.view addSubview:subtabScroll];

    UIStackView *subtabStack = [[UIStackView alloc] init];
    subtabStack.translatesAutoresizingMaskIntoConstraints = NO;
    subtabStack.axis = UILayoutConstraintAxisHorizontal;
    subtabStack.spacing = 6.0;
    [subtabScroll addSubview:subtabStack];

    NSMutableArray<UIButton *> *tabs = [NSMutableArray array];
    for (NSInteger i = 0; i < 5; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        btn.tag = i;
        btn.layer.cornerRadius = 8.0;
        btn.layer.borderWidth = 1.0;
        btn.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
        btn.contentEdgeInsets = UIEdgeInsetsMake(6.0, 12.0, 6.0, 12.0);
        [btn addTarget:self action:@selector(onSubtabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [subtabStack addArrangedSubview:btn];
        [tabs addObject:btn];
    }
    self.subtabButtons = tabs;

    // 2. Catalog Container (Subtabs 0..3)
    self.catalogContainer = [[UIView alloc] init];
    self.catalogContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.catalogContainer];

    // Top filter bar: Source switcher + Search + Sort + Desktop-only/World controls
    UIStackView *topControls = [[UIStackView alloc] init];
    topControls.translatesAutoresizingMaskIntoConstraints = NO;
    topControls.axis = UILayoutConstraintAxisHorizontal;
    topControls.spacing = 8.0;
    topControls.alignment = UIStackViewAlignmentCenter;
    [self.catalogContainer addSubview:topControls];

    self.sourceSegmented = [[UISegmentedControl alloc] initWithItems:@[@"Horizon", @"Modrinth"]];
    self.sourceSegmented.selectedSegmentTintColor = hm_emerald();
    self.sourceSegmented.backgroundColor = hm_cardBg();
    [self.sourceSegmented setTitleTextAttributes:@{
        NSForegroundColorAttributeName: hm_textSec(),
        NSFontAttributeName: [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium],
    } forState:UIControlStateNormal];
    [self.sourceSegmented setTitleTextAttributes:@{
        NSForegroundColorAttributeName: UIColor.whiteColor,
        NSFontAttributeName: [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold],
    } forState:UIControlStateSelected];
    [self.sourceSegmented addTarget:self action:@selector(onSourceChanged:) forControlEvents:UIControlEventValueChanged];
    [self.sourceSegmented setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.sourceSegmented setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [topControls addArrangedSubview:self.sourceSegmented];

    self.sourceStaticPill = [[UILabel alloc] init];
    self.sourceStaticPill.text = @"  Horizon Registry  ";
    self.sourceStaticPill.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    self.sourceStaticPill.textColor = hm_emerald();
    self.sourceStaticPill.backgroundColor = hm_emeraldSoft();
    self.sourceStaticPill.layer.cornerRadius = 8.0;
    self.sourceStaticPill.clipsToBounds = YES;
    self.sourceStaticPill.hidden = YES;
    [self.sourceStaticPill setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.sourceStaticPill.heightAnchor constraintEqualToConstant:30.0].active = YES;
    [topControls addArrangedSubview:self.sourceStaticPill];

    // Search field
    UIView *searchBox = [[UIView alloc] init];
    searchBox.backgroundColor = hm_cardBg();
    searchBox.layer.cornerRadius = 8.0;
    searchBox.layer.borderWidth = 1.0;
    searchBox.layer.borderColor = hm_hairline().CGColor;
    [searchBox.heightAnchor constraintEqualToConstant:32.0].active = YES;

    UIImageView *searchIv = [[UIImageView alloc] initWithImage:[HorizonIcons iconForKind:HorizonIconSearch pointSize:14.0]];
    searchIv.translatesAutoresizingMaskIntoConstraints = NO;
    searchIv.tintColor = hm_textMuted();
    [searchBox addSubview:searchIv];

    self.searchField = [[UITextField alloc] init];
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchField.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    self.searchField.textColor = hm_textPrimary();
    self.searchField.tintColor = hm_emerald();
    self.searchField.returnKeyType = UIReturnKeySearch;
    self.searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.searchField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchField.delegate = self;
    [searchBox addSubview:self.searchField];
    [NSLayoutConstraint activateConstraints:@[
        [searchIv.leadingAnchor constraintEqualToAnchor:searchBox.leadingAnchor constant:9.0],
        [searchIv.centerYAnchor constraintEqualToAnchor:searchBox.centerYAnchor],
        [searchIv.widthAnchor constraintEqualToConstant:14.0],
        [searchIv.heightAnchor constraintEqualToConstant:14.0],
        [self.searchField.leadingAnchor constraintEqualToAnchor:searchIv.trailingAnchor constant:6.0],
        [self.searchField.trailingAnchor constraintEqualToAnchor:searchBox.trailingAnchor constant:-6.0],
        [self.searchField.topAnchor constraintEqualToAnchor:searchBox.topAnchor],
        [self.searchField.bottomAnchor constraintEqualToAnchor:searchBox.bottomAnchor],
    ]];
    [topControls addArrangedSubview:searchBox];

    self.sortButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sortButton.backgroundColor = hm_cardBg();
    self.sortButton.layer.cornerRadius = 8.0;
    self.sortButton.layer.borderWidth = 1.0;
    self.sortButton.layer.borderColor = hm_hairline().CGColor;
    [self.sortButton setTitleColor:hm_textPrimary() forState:UIControlStateNormal];
    self.sortButton.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    self.sortButton.contentEdgeInsets = UIEdgeInsetsMake(6.0, 10.0, 6.0, 10.0);
    [self.sortButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.sortButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.sortButton addTarget:self action:@selector(onSortButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [topControls addArrangedSubview:self.sortButton];

    self.desktopToggleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.desktopToggleBtn.layer.cornerRadius = 8.0;
    self.desktopToggleBtn.layer.borderWidth = 1.0;
    self.desktopToggleBtn.titleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold];
    self.desktopToggleBtn.contentEdgeInsets = UIEdgeInsetsMake(6.0, 9.0, 6.0, 9.0);
    [self.desktopToggleBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.desktopToggleBtn setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.desktopToggleBtn addTarget:self action:@selector(onToggleDesktopOnly) forControlEvents:UIControlEventTouchUpInside];
    [topControls addArrangedSubview:self.desktopToggleBtn];

    self.worldSelectorBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.worldSelectorBtn.backgroundColor = hm_emeraldSoft();
    self.worldSelectorBtn.layer.cornerRadius = 8.0;
    self.worldSelectorBtn.layer.borderWidth = 1.0;
    self.worldSelectorBtn.layer.borderColor = hm_rgb(51, 189, 102, 0.35).CGColor;
    [self.worldSelectorBtn setTitleColor:hm_emerald() forState:UIControlStateNormal];
    self.worldSelectorBtn.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    self.worldSelectorBtn.contentEdgeInsets = UIEdgeInsetsMake(6.0, 10.0, 6.0, 10.0);
    [self.worldSelectorBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.worldSelectorBtn setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.worldSelectorBtn addTarget:self action:@selector(onWorldPickerTapped:) forControlEvents:UIControlEventTouchUpInside];
    self.worldSelectorBtn.hidden = YES;
    [topControls addArrangedSubview:self.worldSelectorBtn];

    // Category chips strip
    self.categoryScroll = [[UIScrollView alloc] init];
    self.categoryScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.categoryScroll.showsHorizontalScrollIndicator = NO;
    [self.catalogContainer addSubview:self.categoryScroll];

    self.categoryStack = [[UIStackView alloc] init];
    self.categoryStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.categoryStack.axis = UILayoutConstraintAxisHorizontal;
    self.categoryStack.spacing = 6.0;
    [self.categoryScroll addSubview:self.categoryStack];

    // Optional info / offline / Modrinth-mods banner
    self.bannerBox = [[UIView alloc] init];
    self.bannerBox.translatesAutoresizingMaskIntoConstraints = NO;
    self.bannerBox.backgroundColor = hm_cardBg();
    self.bannerBox.layer.cornerRadius = 10.0;
    self.bannerBox.layer.borderWidth = 1.0;
    self.bannerBox.layer.borderColor = hm_rgb(242, 169, 59, 0.35).CGColor;
    self.bannerBox.hidden = YES;
    [self.catalogContainer addSubview:self.bannerBox];

    self.bannerLabel = [[UILabel alloc] init];
    self.bannerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.bannerLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    self.bannerLabel.textColor = hm_textSec();
    self.bannerLabel.numberOfLines = 0;
    [self.bannerBox addSubview:self.bannerLabel];

    self.bannerActionBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.bannerActionBtn.translatesAutoresizingMaskIntoConstraints = NO;
    self.bannerActionBtn.backgroundColor = hm_emeraldSoft();
    [self.bannerActionBtn setTitleColor:hm_emerald() forState:UIControlStateNormal];
    self.bannerActionBtn.layer.cornerRadius = 7.0;
    self.bannerActionBtn.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    self.bannerActionBtn.contentEdgeInsets = UIEdgeInsetsMake(5.0, 10.0, 5.0, 10.0);
    [self.bannerActionBtn setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.bannerActionBtn addTarget:self action:@selector(onBannerActionTapped) forControlEvents:UIControlEventTouchUpInside];
    self.bannerActionBtn.hidden = YES;
    [self.bannerBox addSubview:self.bannerActionBtn];

    // Catalog UITableView
    self.catalogTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.catalogTable.translatesAutoresizingMaskIntoConstraints = NO;
    self.catalogTable.backgroundColor = UIColor.clearColor;
    self.catalogTable.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.catalogTable.rowHeight = UITableViewAutomaticDimension;
    self.catalogTable.estimatedRowHeight = 96.0;
    self.catalogTable.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.catalogTable.dataSource = self;
    self.catalogTable.delegate = self;
    [self.catalogTable registerClass:HorizonCatalogCell.class forCellReuseIdentifier:@"CatalogCell"];
    [self.catalogContainer addSubview:self.catalogTable];

    self.refreshControl = [[UIRefreshControl alloc] init];
    self.refreshControl.tintColor = hm_emerald();
    [self.refreshControl addTarget:self action:@selector(onPullToRefresh) forControlEvents:UIControlEventValueChanged];
    self.catalogTable.refreshControl = self.refreshControl;

    self.catalogSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.catalogSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.catalogSpinner.color = hm_emerald();
    self.catalogSpinner.hidesWhenStopped = YES;
    [self.catalogContainer addSubview:self.catalogSpinner];

    self.emptyStateLabel = [[UILabel alloc] init];
    self.emptyStateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
    self.emptyStateLabel.textColor = hm_textMuted();
    self.emptyStateLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyStateLabel.numberOfLines = 0;
    self.emptyStateLabel.hidden = YES;
    [self.catalogContainer addSubview:self.emptyStateLabel];

    // 3. Installed Container (Subtab 4)
    self.installedScroll = [[UIScrollView alloc] init];
    self.installedScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.installedScroll.alwaysBounceVertical = YES;
    self.installedScroll.hidden = YES;
    [self.view addSubview:self.installedScroll];

    self.installedStack = [[UIStackView alloc] init];
    self.installedStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.installedStack.axis = UILayoutConstraintAxisVertical;
    self.installedStack.spacing = 10.0;
    [self.installedScroll addSubview:self.installedStack];

    // Layout constraints
    [NSLayoutConstraint activateConstraints:@[
        [self.headerTitleLabel.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:14.0],
        [self.headerTitleLabel.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:18.0],

        [subtabScroll.topAnchor constraintEqualToAnchor:self.headerTitleLabel.bottomAnchor constant:8.0],
        [subtabScroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:18.0],
        [subtabScroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-18.0],
        [subtabScroll.heightAnchor constraintEqualToConstant:34.0],

        [subtabStack.topAnchor constraintEqualToAnchor:subtabScroll.contentLayoutGuide.topAnchor],
        [subtabStack.leadingAnchor constraintEqualToAnchor:subtabScroll.contentLayoutGuide.leadingAnchor],
        [subtabStack.trailingAnchor constraintEqualToAnchor:subtabScroll.contentLayoutGuide.trailingAnchor],
        [subtabStack.bottomAnchor constraintEqualToAnchor:subtabScroll.contentLayoutGuide.bottomAnchor],
        [subtabStack.heightAnchor constraintEqualToAnchor:subtabScroll.frameLayoutGuide.heightAnchor],

        // Catalog container
        [self.catalogContainer.topAnchor constraintEqualToAnchor:subtabScroll.bottomAnchor constant:8.0],
        [self.catalogContainer.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:18.0],
        [self.catalogContainer.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-18.0],
        [self.catalogContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [topControls.topAnchor constraintEqualToAnchor:self.catalogContainer.topAnchor],
        [topControls.leadingAnchor constraintEqualToAnchor:self.catalogContainer.leadingAnchor],
        [topControls.trailingAnchor constraintEqualToAnchor:self.catalogContainer.trailingAnchor],
        [topControls.heightAnchor constraintEqualToConstant:34.0],

        [self.categoryScroll.topAnchor constraintEqualToAnchor:topControls.bottomAnchor constant:6.0],
        [self.categoryScroll.leadingAnchor constraintEqualToAnchor:self.catalogContainer.leadingAnchor],
        [self.categoryScroll.trailingAnchor constraintEqualToAnchor:self.catalogContainer.trailingAnchor],
        [self.categoryScroll.heightAnchor constraintEqualToConstant:28.0],

        [self.categoryStack.topAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.topAnchor],
        [self.categoryStack.leadingAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.leadingAnchor],
        [self.categoryStack.trailingAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.trailingAnchor],
        [self.categoryStack.bottomAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.bottomAnchor],
        [self.categoryStack.heightAnchor constraintEqualToAnchor:self.categoryScroll.frameLayoutGuide.heightAnchor],

        [self.bannerBox.topAnchor constraintEqualToAnchor:self.categoryScroll.bottomAnchor constant:6.0],
        [self.bannerBox.leadingAnchor constraintEqualToAnchor:self.catalogContainer.leadingAnchor],
        [self.bannerBox.trailingAnchor constraintEqualToAnchor:self.catalogContainer.trailingAnchor],

        [self.bannerLabel.topAnchor constraintEqualToAnchor:self.bannerBox.topAnchor constant:8.0],
        [self.bannerLabel.leadingAnchor constraintEqualToAnchor:self.bannerBox.leadingAnchor constant:12.0],
        [self.bannerLabel.bottomAnchor constraintEqualToAnchor:self.bannerBox.bottomAnchor constant:-8.0],
        [self.bannerLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.bannerActionBtn.leadingAnchor constant:-10.0],

        [self.bannerActionBtn.trailingAnchor constraintEqualToAnchor:self.bannerBox.trailingAnchor constant:-10.0],
        [self.bannerActionBtn.centerYAnchor constraintEqualToAnchor:self.bannerBox.centerYAnchor],

        [self.catalogTable.topAnchor constraintEqualToAnchor:self.categoryScroll.bottomAnchor constant:8.0],
        [self.catalogTable.leadingAnchor constraintEqualToAnchor:self.catalogContainer.leadingAnchor],
        [self.catalogTable.trailingAnchor constraintEqualToAnchor:self.catalogContainer.trailingAnchor],
        [self.catalogTable.bottomAnchor constraintEqualToAnchor:self.catalogContainer.bottomAnchor],

        [self.catalogSpinner.centerXAnchor constraintEqualToAnchor:self.catalogTable.centerXAnchor],
        [self.catalogSpinner.centerYAnchor constraintEqualToAnchor:self.catalogTable.centerYAnchor],

        [self.emptyStateLabel.centerXAnchor constraintEqualToAnchor:self.catalogTable.centerXAnchor],
        [self.emptyStateLabel.centerYAnchor constraintEqualToAnchor:self.catalogTable.centerYAnchor],
        [self.emptyStateLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.catalogTable.leadingAnchor constant:24.0],
        [self.emptyStateLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.catalogTable.trailingAnchor constant:-24.0],

        // Installed scroll
        [self.installedScroll.topAnchor constraintEqualToAnchor:subtabScroll.bottomAnchor constant:8.0],
        [self.installedScroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.installedScroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.installedScroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.installedStack.topAnchor constraintEqualToAnchor:self.installedScroll.contentLayoutGuide.topAnchor constant:4.0],
        [self.installedStack.leadingAnchor constraintEqualToAnchor:self.installedScroll.safeAreaLayoutGuide.leadingAnchor constant:18.0],
        [self.installedStack.trailingAnchor constraintEqualToAnchor:self.installedScroll.safeAreaLayoutGuide.trailingAnchor constant:-18.0],
        [self.installedStack.bottomAnchor constraintEqualToAnchor:self.installedScroll.contentLayoutGuide.bottomAnchor constant:-20.0],
    ]];

    [self applyLocalizedStaticStrings];
}

- (void)applyLocalizedStaticStrings {
    self.headerTitleLabel.text = HL(@"Mods & Packs", @"Моды и паки");
    self.searchField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:HL(@"Search…", @"Поиск…")
                                                                             attributes:@{NSForegroundColorAttributeName: hm_textMuted()}];
    [self.sortButton setTitle:[NSString stringWithFormat:@"%@ ▾", hm_localizedSortTitle(self.selectedSort)] forState:UIControlStateNormal];
    [self updateDesktopToggleAppearance];
    [self updateSubtabPills];
    [self updateWorldSelectorLabel];
    [self rebuildCategoryChips];
}

- (void)rebuildForLanguageChange {
    [self applyLocalizedStaticStrings];
    [self updateBannerUI];
    [self.catalogTable reloadData];
    [self rebuildInstalledTab];
}

- (void)updateDesktopToggleAppearance {
    [self.desktopToggleBtn setTitle:HL(@"Desktop only", @"Только ПК") forState:UIControlStateNormal];
    if (self.showDesktopOnly) {
        [self.desktopToggleBtn setTitleColor:hm_amber() forState:UIControlStateNormal];
        self.desktopToggleBtn.backgroundColor = hm_amberSoft();
        self.desktopToggleBtn.layer.borderColor = hm_amber().CGColor;
    } else {
        [self.desktopToggleBtn setTitleColor:hm_textMuted() forState:UIControlStateNormal];
        self.desktopToggleBtn.backgroundColor = hm_cardBg();
        self.desktopToggleBtn.layer.borderColor = hm_hairline().CGColor;
    }
}

- (void)updateSubtabPills {
    NSUInteger totalCount = [self.installedOverview[@"total_count"] unsignedIntegerValue];
    NSUInteger updCount = [self.installedOverview[@"updates_count"] unsignedIntegerValue];
    NSString *instTitle = HL(@"Installed", @"Установлено");
    if (updCount > 0) {
        instTitle = [NSString stringWithFormat:@"%@ (%lu · ↑%lu)", instTitle, (unsigned long)totalCount, (unsigned long)updCount];
    } else if (totalCount > 0) {
        instTitle = [NSString stringWithFormat:@"%@ (%lu)", instTitle, (unsigned long)totalCount];
    }

    NSArray<NSString *> *titles = @[
        HL(@"Mods", @"Моды"),
        HL(@"Resource Packs", @"Ресурспаки"),
        HL(@"Shaders", @"Шейдеры"),
        HL(@"Data Packs", @"Датапаки"),
        instTitle,
    ];
    for (NSUInteger i = 0; i < self.subtabButtons.count && i < titles.count; i++) {
        UIButton *btn = self.subtabButtons[i];
        BOOL active = ((NSInteger)i == self.activeSubtab);
        [btn setTitle:titles[i] forState:UIControlStateNormal];
        if (active) {
            btn.backgroundColor = hm_emeraldSoft();
            btn.layer.borderColor = hm_emerald().CGColor;
            [btn setTitleColor:hm_emerald() forState:UIControlStateNormal];
        } else {
            btn.backgroundColor = hm_cardBg();
            btn.layer.borderColor = hm_hairline().CGColor;
            [btn setTitleColor:hm_textSec() forState:UIControlStateNormal];
        }
    }
}

- (void)updateWorldSelectorLabel {
    NSArray<NSDictionary *> *worlds = [self.installedOverview[@"worlds"] isKindOfClass:NSArray.class]
        ? self.installedOverview[@"worlds"]
        : @[];
    NSString *display = HL(@"No worlds", @"Нет миров");
    for (NSDictionary *w in worlds) {
        if ([w[@"folder"] isEqualToString:self.selectedWorld]) {
            display = w[@"name"] ?: self.selectedWorld;
            break;
        }
    }
    if (worlds.count > 0 && self.selectedWorld.length == 0) {
        self.selectedWorld = worlds.firstObject[@"folder"] ?: @"";
        display = worlds.firstObject[@"name"] ?: self.selectedWorld;
    }
    [self.worldSelectorBtn setTitle:[NSString stringWithFormat:HL(@"World: %@ ▾", @"Мир: %@ ▾"), display]
                           forState:UIControlStateNormal];
}

- (void)updateControlsVisibility {
    BOOL isInstalled = (self.activeSubtab == HorizonModsSubtabInstalled);
    self.catalogContainer.hidden = isInstalled;
    self.installedScroll.hidden = !isInstalled;
    if (isInstalled) return;

    BOOL isShaders = (self.activeSubtab == HorizonModsSubtabShaders);
    BOOL isMods = (self.activeSubtab == HorizonModsSubtabMods);
    BOOL isDataPacks = (self.activeSubtab == HorizonModsSubtabDataPacks);

    self.sourceSegmented.hidden = isShaders;
    self.sourceStaticPill.hidden = !isShaders;
    if (!isShaders) {
        self.sourceSegmented.selectedSegmentIndex = [[self activeSourceString] isEqualToString:@"modrinth"] ? 1 : 0;
    }
    self.desktopToggleBtn.hidden = !(isMods && [[self activeSourceString] isEqualToString:@"horizon"]);
    self.worldSelectorBtn.hidden = !isDataPacks;
    [self updateWorldSelectorLabel];
}

- (void)rebuildCategoryChips {
    for (UIView *sub in [self.categoryStack.arrangedSubviews copy]) {
        [self.categoryStack removeArrangedSubview:sub];
        [sub removeFromSuperview];
    }

    NSMutableArray<NSString *> *cats = [NSMutableArray arrayWithObject:@""];
    for (NSString *c in self.availableCategories) {
        if (c.length > 0 && ![cats containsObject:c]) {
            [cats addObject:c];
        }
    }

    for (NSString *cat in cats) {
        UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
        chip.accessibilityIdentifier = cat;
        BOOL selected = [cat isEqualToString:self.selectedCategory];
        [chip setTitle:hm_localizedCategory(cat) forState:UIControlStateNormal];
        chip.titleLabel.font = [UIFont systemFontOfSize:11.5 weight:selected ? UIFontWeightSemibold : UIFontWeightMedium];
        chip.layer.cornerRadius = 7.0;
        chip.layer.borderWidth = 1.0;
        chip.contentEdgeInsets = UIEdgeInsetsMake(3.0, 9.0, 3.0, 9.0);
        if (selected) {
            chip.backgroundColor = hm_emeraldSoft();
            chip.layer.borderColor = hm_emerald().CGColor;
            [chip setTitleColor:hm_emerald() forState:UIControlStateNormal];
        } else {
            chip.backgroundColor = hm_cardBg();
            chip.layer.borderColor = hm_hairline().CGColor;
            [chip setTitleColor:hm_textSec() forState:UIControlStateNormal];
        }
        [chip addTarget:self action:@selector(onCategoryChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.categoryStack addArrangedSubview:chip];
    }
}

- (void)updateBannerUI {
    BOOL isModrinthMods = (self.activeSubtab == HorizonModsSubtabMods && [[self activeSourceString] isEqualToString:@"modrinth"]);
    BOOL isDataPacksNoWorld = (self.activeSubtab == HorizonModsSubtabDataPacks && self.selectedWorld.length == 0);

    NSString *msg = nil;
    BOOL showSwitchBtn = NO;
    if (isModrinthMods) {
        msg = HL(@"Horizon .hmod & WASM (Pulley64) mods live in Horizon Registry. Automatic Java mod porting from Modrinth is planned for Stage 2.",
                 @"Моды Horizon (.hmod и WASM Pulley64) находятся в Horizon Registry. Автоматический перенос Java-модов с Modrinth запланирован на этап 2.");
        showSwitchBtn = YES;
    } else if (self.catalogError.length > 0) {
        msg = self.catalogError;
    } else if (self.catalogBanner.length > 0) {
        msg = [self.catalogBanner containsString:@"Offline"]
            ? HL(@"Offline mode: showing cached Horizon Registry index.", @"Офлайн-режим: показан сохранённый каталог Horizon Registry.")
            : self.catalogBanner;
    } else if (isDataPacksNoWorld) {
        msg = HL(@"No local worlds yet. Create a singleplayer world in Horizon first, then return here to install Data Packs into it.",
                 @"Локальных миров пока нет. Сначала создайте одиночный мир в Horizon, затем вернитесь сюда для установки датапаков.");
    }

    if (msg.length > 0) {
        self.bannerLabel.text = msg;
        self.bannerBox.hidden = NO;
        self.bannerActionBtn.hidden = !showSwitchBtn;
        if (showSwitchBtn) {
            [self.bannerActionBtn setTitle:HL(@"Open Horizon Registry", @"Открыть Horizon Registry") forState:UIControlStateNormal];
        }
        self.catalogTable.contentInset = UIEdgeInsetsMake(54.0, 0, 14.0, 0);
    } else {
        self.bannerBox.hidden = YES;
        self.bannerActionBtn.hidden = YES;
        self.catalogTable.contentInset = UIEdgeInsetsMake(0, 0, 14.0, 0);
    }
}

#pragma mark - Subtab & Filter Actions

- (void)onSubtabTapped:(UIButton *)sender {
    HorizonModsSubtab target = (HorizonModsSubtab)sender.tag;
    if (target == self.activeSubtab) return;
    [self.view endEditing:YES];
    self.activeSubtab = target;
    self.selectedCategory = @"";
    [self updateSubtabPills];
    [self updateControlsVisibility];

    if (target == HorizonModsSubtabInstalled) {
        [self refreshInstalledAndCheckUpdates:NO];
    } else {
        [self runSearchReset:YES forceRefresh:NO];
    }
}

- (void)onSourceChanged:(UISegmentedControl *)sender {
    NSString *src = (sender.selectedSegmentIndex == 1) ? @"modrinth" : @"horizon";
    [self setActiveSourceString:src];
    self.selectedCategory = @"";
    [self updateControlsVisibility];
    [self runSearchReset:YES forceRefresh:NO];
}

- (void)onBannerActionTapped {
    if (self.activeSubtab == HorizonModsSubtabMods) {
        self.sourceForMods = @"horizon";
        [self updateControlsVisibility];
        [self runSearchReset:YES forceRefresh:NO];
    }
}

- (void)onToggleDesktopOnly {
    self.showDesktopOnly = !self.showDesktopOnly;
    [self updateDesktopToggleAppearance];
    [self runSearchReset:YES forceRefresh:NO];
}

- (void)onCategoryChipTapped:(UIButton *)sender {
    NSString *cat = sender.accessibilityIdentifier ?: @"";
    self.selectedCategory = [cat isEqualToString:self.selectedCategory] ? @"" : cat;
    [self rebuildCategoryChips];
    [self runSearchReset:YES forceRefresh:NO];
}

- (void)onSortButtonTapped:(UIButton *)sender {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:HL(@"Sort By", @"Сортировка")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSString *> *sorts = @[@"downloads", @"relevance", @"newest", @"updated"];
    __weak typeof(self) weakSelf = self;
    for (NSString *key in sorts) {
        NSString *title = hm_localizedSortTitle(key);
        if ([key isEqualToString:self.selectedSort]) {
            title = [NSString stringWithFormat:@"✓ %@", title];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            (void)action;
            typeof(self) s = weakSelf;
            if (s == nil) return;
            s.selectedSort = key;
            [s.sortButton setTitle:[NSString stringWithFormat:@"%@ ▾", hm_localizedSortTitle(key)] forState:UIControlStateNormal];
            [s runSearchReset:YES forceRefresh:NO];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:HL(@"Cancel", @"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController != nil) {
        sheet.popoverPresentationController.sourceView = sender;
        sheet.popoverPresentationController.sourceRect = sender.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)onWorldPickerTapped:(UIButton *)sender {
    NSArray<NSDictionary *> *worlds = [self.installedOverview[@"worlds"] isKindOfClass:NSArray.class]
        ? self.installedOverview[@"worlds"]
        : @[];
    if (worlds.count == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:HL(@"No Local Worlds", @"Нет локальных миров")
                                                                   message:HL(@"Create a singleplayer world in Horizon first to manage its Data Packs.",
                                                                              @"Сначала создайте одиночный мир в Horizon, чтобы управлять его датапаками.")
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:HL(@"OK", @"ОК") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:HL(@"Select World", @"Выберите мир")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSDictionary *w in worlds) {
        NSString *folder = w[@"folder"] ?: @"";
        NSString *name = w[@"name"] ?: folder;
        NSString *label = [folder isEqualToString:self.selectedWorld] ? [NSString stringWithFormat:@"✓ %@", name] : name;
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            (void)action;
            typeof(self) s = weakSelf;
            if (s == nil) return;
            s.selectedWorld = folder;
            [s updateWorldSelectorLabel];
            [s refreshInstalledAndCheckUpdates:NO];
            if (s.activeSubtab == HorizonModsSubtabDataPacks) {
                [s runSearchReset:YES forceRefresh:NO];
            }
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:HL(@"Cancel", @"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController != nil) {
        sheet.popoverPresentationController.sourceView = sender;
        sheet.popoverPresentationController.sourceRect = sender.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)onPullToRefresh {
    [self runSearchReset:YES forceRefresh:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    self.searchText = [textField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    [self runSearchReset:YES forceRefresh:NO];
    return YES;
}

- (BOOL)textFieldShouldClear:(UITextField *)textField {
    (void)textField;
    self.searchText = @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        [self runSearchReset:YES forceRefresh:NO];
    });
    return YES;
}

#pragma mark - Background Search

- (void)runSearchReset:(BOOL)reset forceRefresh:(BOOL)forceRefresh {
    self.searchGeneration += 1;
    NSUInteger gen = self.searchGeneration;
    NSUInteger offset = reset ? 0 : self.catalogItems.count;
    if (reset) {
        [self.catalogItems removeAllObjects];
        self.catalogTotal = 0;
        self.catalogError = @"";
        self.catalogBanner = @"";
        [self.catalogTable reloadData];
    }
    self.catalogLoading = YES;
    self.emptyStateLabel.hidden = YES;
    if (reset && !self.refreshControl.isRefreshing) {
        [self.catalogSpinner startAnimating];
    }

    NSString *source = [self activeSourceString];
    NSString *kind = [self activeKindString];
    NSDictionary *reqObj = @{
        @"source": source,
        @"kind": kind,
        @"query": self.searchText ?: @"",
        @"category": self.selectedCategory ?: @"",
        @"sort": self.selectedSort ?: @"downloads",
        @"offset": @(offset),
        @"limit": @(25),
        @"show_desktop_only": @(self.showDesktopOnly),
        @"all_versions": @NO,
        @"force_refresh": @(forceRefresh),
        @"world": self.selectedWorld ?: @"",
    };
    NSString *reqJSON = hm_toJSONString(reqObj);
    NSString *dir = self.documentsDir;

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        char *raw = horizon_ios_mods_search_json(dir.UTF8String, reqJSON.UTF8String);
        id parsed = hm_parseOwnedCStringJSON(raw);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = weakSelf;
            if (s == nil || s.searchGeneration != gen) return;
            s.catalogLoading = NO;
            [s.catalogSpinner stopAnimating];
            [s.refreshControl endRefreshing];

            if (![parsed isKindOfClass:NSDictionary.class]) {
                s.catalogError = HL(@"Failed to load catalog.", @"Не удалось загрузить каталог.");
                [s updateBannerUI];
                return;
            }
            NSDictionary *d = (NSDictionary *)parsed;
            s.catalogBanner = [d[@"banner"] isKindOfClass:NSString.class] ? d[@"banner"] : @"";
            s.catalogError = [d[@"error"] isKindOfClass:NSString.class] ? d[@"error"] : @"";
            if ([d[@"categories"] isKindOfClass:NSArray.class]) {
                s.availableCategories = d[@"categories"];
                [s rebuildCategoryChips];
            }
            NSArray *items = [d[@"items"] isKindOfClass:NSArray.class] ? d[@"items"] : @[];
            s.catalogTotal = [d[@"total"] unsignedIntegerValue];
            if (reset) {
                [s.catalogItems setArray:items];
            } else {
                [s.catalogItems addObjectsFromArray:items];
            }
            [s updateBannerUI];
            [s updateCatalogTableFooter];
            [s.catalogTable reloadData];

            if (s.catalogItems.count == 0 && s.bannerBox.hidden) {
                s.emptyStateLabel.text = HL(@"No packs match your search.", @"По вашему запросу ничего не найдено.");
                s.emptyStateLabel.hidden = NO;
            } else {
                s.emptyStateLabel.hidden = YES;
            }
        });
    });
}

- (void)updateCatalogTableFooter {
    if (self.catalogItems.count > 0 && self.catalogItems.count < self.catalogTotal) {
        UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 48)];
        UIButton *more = [UIButton buttonWithType:UIButtonTypeSystem];
        more.translatesAutoresizingMaskIntoConstraints = NO;
        [more setTitle:[NSString stringWithFormat:HL(@"Load More (%lu / %lu)", @"Загрузить ещё (%lu / %lu)"),
                        (unsigned long)self.catalogItems.count, (unsigned long)self.catalogTotal]
              forState:UIControlStateNormal];
        [more setTitleColor:hm_emerald() forState:UIControlStateNormal];
        more.backgroundColor = hm_emeraldSoft();
        more.layer.cornerRadius = 9.0;
        more.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        more.contentEdgeInsets = UIEdgeInsetsMake(7.0, 18.0, 7.0, 18.0);
        [more addTarget:self action:@selector(onLoadMoreTapped) forControlEvents:UIControlEventTouchUpInside];
        [footer addSubview:more];
        [NSLayoutConstraint activateConstraints:@[
            [more.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor],
            [more.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        ]];
        self.catalogTable.tableFooterView = footer;
    } else {
        self.catalogTable.tableFooterView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 12)];
    }
}

- (void)onLoadMoreTapped {
    if (!self.catalogLoading) {
        [self runSearchReset:NO forceRefresh:NO];
    }
}

#pragma mark - Install / Update / Remove Backend Actions

- (void)installCatalogItem:(NSDictionary *)item completion:(void (^ _Nullable)(BOOL ok, NSString * _Nullable err))completion {
    NSString *source = item[@"source"] ?: @"horizon";
    NSString *projectId = item[@"id"] ?: @"";
    NSString *kind = item[@"kind"] ?: @"mod";
    if (projectId.length == 0) return;

    if ([kind isEqualToString:@"datapack"] && self.selectedWorld.length == 0) {
        NSString *msg = HL(@"Select or create a local world first.", @"Сначала выберите или создайте локальный мир.");
        if (completion != nil) {
            completion(NO, msg);
        } else {
            [self showAlertTitle:HL(@"No World Selected", @"Мир не выбран") message:msg];
        }
        return;
    }

    NSString *bkey = [self busyKeyForSource:source projectId:projectId];
    [self.busyProjectKeys addObject:bkey];
    [self.catalogTable reloadData];

    NSDictionary *req = @{
        @"source": source,
        @"project_id": projectId,
        @"kind": kind,
        @"world": self.selectedWorld ?: @"",
        @"allow_older": @YES,
    };
    NSString *reqJSON = hm_toJSONString(req);
    NSString *dir = self.documentsDir;

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        char *raw = horizon_ios_mods_install_json(dir.UTF8String, reqJSON.UTF8String);
        id parsed = hm_parseOwnedCStringJSON(raw);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = weakSelf;
            if (s == nil) return;
            [s.busyProjectKeys removeObject:bkey];
            BOOL ok = [parsed isKindOfClass:NSDictionary.class] && [parsed[@"ok"] boolValue];
            NSString *err = [parsed isKindOfClass:NSDictionary.class] && [parsed[@"error"] isKindOfClass:NSString.class]
                ? parsed[@"error"]
                : HL(@"Installation failed.", @"Ошибка установки.");
            if (ok) {
                for (NSUInteger i = 0; i < s.catalogItems.count; i++) {
                    NSDictionary *cur = s.catalogItems[i];
                    if ([cur[@"source"] isEqualToString:source] && [cur[@"id"] isEqualToString:projectId]) {
                        NSMutableDictionary *upd = [cur mutableCopy];
                        upd[@"installed"] = @YES;
                        upd[@"update_available"] = @NO;
                        s.catalogItems[i] = upd;
                        break;
                    }
                }
                [s.catalogTable reloadData];
                [s refreshInstalledAndCheckUpdates:NO];
            } else {
                [s.catalogTable reloadData];
                if (completion == nil) {
                    [s showAlertTitle:HL(@"Install Failed", @"Ошибка установки") message:err];
                }
            }
            if (completion != nil) {
                completion(ok, ok ? nil : err);
            }
        });
    });
}

- (void)removeItemKind:(NSString *)kind
                   key:(NSString *)key
                 world:(NSString *)world
            completion:(void (^ _Nullable)(BOOL ok, NSString * _Nullable err))completion {
    NSString *dir = self.documentsDir;
    NSString *w = world ?: @"";
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        char *raw = horizon_ios_mods_remove_json(dir.UTF8String, kind.UTF8String, key.UTF8String, w.UTF8String);
        id parsed = hm_parseOwnedCStringJSON(raw);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = weakSelf;
            if (s == nil) return;
            BOOL ok = [parsed isKindOfClass:NSDictionary.class] && [parsed[@"ok"] boolValue];
            NSString *err = [parsed isKindOfClass:NSDictionary.class] && [parsed[@"error"] isKindOfClass:NSString.class]
                ? parsed[@"error"]
                : HL(@"Could not remove item.", @"Не удалось удалить элемент.");
            if (ok) {
                [s refreshInstalledAndCheckUpdates:NO];
                if (s.activeSubtab != HorizonModsSubtabInstalled) {
                    [s runSearchReset:YES forceRefresh:NO];
                }
            } else if (completion == nil) {
                [s showAlertTitle:HL(@"Remove Failed", @"Ошибка удаления") message:err];
            }
            if (completion != nil) {
                completion(ok, ok ? nil : err);
            }
        });
    });
}

#pragma mark - Installed Tab State & Actions

- (void)refreshInstalledAndCheckUpdates:(BOOL)checkNetwork {
    NSString *dir = self.documentsDir;
    NSString *world = self.selectedWorld ?: @"";
    NSString *updJSON = self.availableUpdates.count > 0 ? hm_toJSONString(self.availableUpdates) : @"";

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        char *raw = horizon_ios_mods_list_installed_json(
            dir.UTF8String,
            world.UTF8String,
            updJSON.length > 0 ? updJSON.UTF8String : NULL
        );
        id parsed = hm_parseOwnedCStringJSON(raw);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = weakSelf;
            if (s == nil) return;
            if ([parsed isKindOfClass:NSDictionary.class]) {
                s.installedOverview = (NSDictionary *)parsed;
                NSString *selW = s.installedOverview[@"selected_world"];
                if ([selW isKindOfClass:NSString.class] && selW.length > 0) {
                    s.selectedWorld = selW;
                }
                [s updateWorldSelectorLabel];
                [s updateSubtabPills];
                [s rebuildInstalledTab];
                if (s.onInstalledSummaryChanged != nil) {
                    NSUInteger total = [s.installedOverview[@"total_count"] unsignedIntegerValue];
                    NSUInteger upd = [s.installedOverview[@"updates_count"] unsignedIntegerValue];
                    s.onInstalledSummaryChanged(total, upd);
                }
            }
        });
    });

    if (checkNetwork && !self.checkingUpdates) {
        self.checkingUpdates = YES;
        [self rebuildInstalledTab];
        dispatch_async(self.ioQueue, ^{
            char *raw = horizon_ios_mods_check_updates_json(dir.UTF8String, false);
            id parsed = hm_parseOwnedCStringJSON(raw);
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) s = weakSelf;
                if (s == nil) return;
                s.checkingUpdates = NO;
                if ([parsed isKindOfClass:NSDictionary.class] && [parsed[@"updates"] isKindOfClass:NSArray.class]) {
                    s.availableUpdates = parsed[@"updates"];
                }
                [s refreshInstalledAndCheckUpdates:NO];
            });
        });
    }
}

- (void)onCheckUpdatesTapped {
    if (self.checkingUpdates || self.updatingAll) return;
    self.checkingUpdates = YES;
    [self rebuildInstalledTab];
    NSString *dir = self.documentsDir;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        char *raw = horizon_ios_mods_check_updates_json(dir.UTF8String, true);
        id parsed = hm_parseOwnedCStringJSON(raw);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = weakSelf;
            if (s == nil) return;
            s.checkingUpdates = NO;
            if ([parsed isKindOfClass:NSDictionary.class] && [parsed[@"updates"] isKindOfClass:NSArray.class]) {
                s.availableUpdates = parsed[@"updates"];
            }
            [s refreshInstalledAndCheckUpdates:NO];
        });
    });
}

- (void)onUpdateAllTapped {
    if (self.updatingAll) return;
    self.updatingAll = YES;
    [self rebuildInstalledTab];
    NSString *dir = self.documentsDir;
    NSString *reqJSON = hm_toJSONString(@{@"update_all": @YES});
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        char *raw = horizon_ios_mods_update_json(dir.UTF8String, reqJSON.UTF8String);
        id parsed = hm_parseOwnedCStringJSON(raw);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = weakSelf;
            if (s == nil) return;
            s.updatingAll = NO;
            s.availableUpdates = @[];
            [s refreshInstalledAndCheckUpdates:YES];
            if ([parsed isKindOfClass:NSDictionary.class]) {
                NSArray *failed = [parsed[@"failed"] isKindOfClass:NSArray.class] ? parsed[@"failed"] : @[];
                NSArray *updated = [parsed[@"updated"] isKindOfClass:NSArray.class] ? parsed[@"updated"] : @[];
                if (failed.count > 0) {
                    [s showAlertTitle:HL(@"Updates Finished with Errors", @"Обновление завершено с ошибками")
                              message:[failed componentsJoinedByString:@"\n"]];
                } else if (updated.count > 0) {
                    [s showAlertTitle:HL(@"Updated Successfully", @"Обновление завершено")
                              message:[updated componentsJoinedByString:@"\n"]];
                }
            }
        });
    });
}

- (void)toggleInstalledKind:(NSString *)kind key:(NSString *)key world:(NSString *)world enabled:(BOOL)enabled {
    NSString *dir = self.documentsDir;
    NSString *w = world ?: @"";
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        char *raw = horizon_ios_mods_toggle_enabled_json(
            dir.UTF8String,
            kind.UTF8String,
            key.UTF8String,
            w.UTF8String,
            enabled
        );
        id parsed = hm_parseOwnedCStringJSON(raw);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = weakSelf;
            if (s == nil) return;
            BOOL ok = [parsed isKindOfClass:NSDictionary.class] && [parsed[@"ok"] boolValue];
            if (!ok) {
                NSString *err = [parsed isKindOfClass:NSDictionary.class] ? (parsed[@"error"] ?: @"") : @"";
                [s showAlertTitle:HL(@"Error", @"Ошибка") message:err];
            }
            [s refreshInstalledAndCheckUpdates:NO];
        });
    });
}

- (void)reorderResourcePack:(NSString *)fileName moveUp:(BOOL)moveUp {
    NSString *dir = self.documentsDir;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        char *raw = horizon_ios_mods_reorder_rp_json(dir.UTF8String, fileName.UTF8String, moveUp);
        (void)hm_parseOwnedCStringJSON(raw);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf refreshInstalledAndCheckUpdates:NO];
        });
    });
}

- (void)selectShaderKey:(NSString *)shaderKey {
    NSString *dir = self.documentsDir;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        char *raw = horizon_ios_mods_select_shader_json(dir.UTF8String, (shaderKey ?: @"").UTF8String);
        (void)hm_parseOwnedCStringJSON(raw);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf refreshInstalledAndCheckUpdates:NO];
        });
    });
}

#pragma mark - Installed Tab Builder

- (UIView *)makeCard {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = hm_cardBg();
    v.layer.cornerRadius = 11.0;
    v.layer.borderWidth = 1.0;
    v.layer.borderColor = hm_hairline().CGColor;
    return v;
}

- (UILabel *)makeSectionCaption:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightBold];
    l.textColor = hm_textMuted();
    return l;
}

- (void)rebuildInstalledTab {
    for (UIView *sub in [self.installedStack.arrangedSubviews copy]) {
        [self.installedStack removeArrangedSubview:sub];
        [sub removeFromSuperview];
    }

    NSDictionary *ov = self.installedOverview ?: @{};
    NSArray<NSDictionary *> *mods = [ov[@"mods"] isKindOfClass:NSArray.class] ? ov[@"mods"] : @[];
    NSArray<NSDictionary *> *rps = [ov[@"resourcepacks"] isKindOfClass:NSArray.class] ? ov[@"resourcepacks"] : @[];
    NSArray<NSDictionary *> *shaders = [ov[@"shaders"] isKindOfClass:NSArray.class] ? ov[@"shaders"] : @[];
    NSArray<NSDictionary *> *dps = [ov[@"datapacks"] isKindOfClass:NSArray.class] ? ov[@"datapacks"] : @[];
    NSString *pickedShader = [ov[@"picked_shader"] isKindOfClass:NSString.class] ? ov[@"picked_shader"] : @"";
    NSUInteger updCount = [ov[@"updates_count"] unsignedIntegerValue];

    // 1. Update All Banner (when updates available)
    if (updCount > 0) {
        UIView *banner = [[UIView alloc] init];
        banner.backgroundColor = hm_rgb(51, 189, 102, 0.14);
        banner.layer.cornerRadius = 12.0;
        banner.layer.borderWidth = 1.0;
        banner.layer.borderColor = hm_rgb(51, 189, 102, 0.4).CGColor;

        UILabel *lbl = [[UILabel alloc] init];
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        lbl.text = [NSString stringWithFormat:HL(@"%lu pack update(s) available", @"Доступно обновлений пакетов: %lu"), (unsigned long)updCount];
        lbl.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
        lbl.textColor = hm_textPrimary();
        [banner addSubview:lbl];

        UIButton *updAllBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        updAllBtn.translatesAutoresizingMaskIntoConstraints = NO;
        NSString *btnTitle = self.updatingAll
            ? HL(@"Updating…", @"Обновление…")
            : [NSString stringWithFormat:HL(@"Update All (%lu)", @"Обновить все (%lu)"), (unsigned long)updCount];
        [updAllBtn setTitle:btnTitle forState:UIControlStateNormal];
        [updAllBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        updAllBtn.backgroundColor = hm_emerald();
        updAllBtn.layer.cornerRadius = 8.0;
        updAllBtn.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightBold];
        updAllBtn.contentEdgeInsets = UIEdgeInsetsMake(7.0, 14.0, 7.0, 14.0);
        updAllBtn.enabled = !self.updatingAll;
        [updAllBtn addTarget:self action:@selector(onUpdateAllTapped) forControlEvents:UIControlEventTouchUpInside];
        [banner addSubview:updAllBtn];

        [NSLayoutConstraint activateConstraints:@[
            [lbl.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:14.0],
            [lbl.centerYAnchor constraintEqualToAnchor:banner.centerYAnchor],
            [lbl.trailingAnchor constraintLessThanOrEqualToAnchor:updAllBtn.leadingAnchor constant:-10.0],
            [updAllBtn.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-12.0],
            [updAllBtn.topAnchor constraintEqualToAnchor:banner.topAnchor constant:9.0],
            [updAllBtn.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-9.0],
        ]];
        [self.installedStack addArrangedSubview:banner];
    }

    // 2. Action Toolbar (Refresh / Check Updates)
    UIStackView *toolbar = [[UIStackView alloc] init];
    toolbar.axis = UILayoutConstraintAxisHorizontal;
    toolbar.spacing = 8.0;
    toolbar.alignment = UIStackViewAlignmentCenter;

    UIButton *checkBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [checkBtn setImage:[HorizonIcons iconForKind:HorizonIconRefresh pointSize:13.0] forState:UIControlStateNormal];
    [checkBtn setTitle:self.checkingUpdates ? HL(@"Checking Updates…", @"Проверка обновлений…") : HL(@"Check Updates", @"Проверить обновления")
              forState:UIControlStateNormal];
    checkBtn.tintColor = hm_emerald();
    [checkBtn setTitleColor:hm_emerald() forState:UIControlStateNormal];
    checkBtn.backgroundColor = hm_emeraldSoft();
    checkBtn.layer.cornerRadius = 8.0;
    checkBtn.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    checkBtn.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 5);
    checkBtn.contentEdgeInsets = UIEdgeInsetsMake(6.0, 12.0, 6.0, 12.0);
    checkBtn.enabled = !self.checkingUpdates && !self.updatingAll;
    [checkBtn addTarget:self action:@selector(onCheckUpdatesTapped) forControlEvents:UIControlEventTouchUpInside];
    [toolbar addArrangedSubview:checkBtn];

    UIView *tbSpacer = [[UIView alloc] init];
    [toolbar addArrangedSubview:tbSpacer];
    [self.installedStack addArrangedSubview:toolbar];

    // 3. MODS section
    [self.installedStack addArrangedSubview:[self makeSectionCaption:[NSString stringWithFormat:HL(@"MODS (%lu) · horizon-mods/", @"МОДЫ (%lu) · horizon-mods/"), (unsigned long)mods.count]]];
    if (mods.count == 0) {
        [self.installedStack addArrangedSubview:[self makeEmptyRow:HL(@"No mods installed yet.", @"Моды пока не установлены.")]];
    } else {
        for (NSDictionary *item in mods) {
            [self.installedStack addArrangedSubview:[self makeInstalledRowForItem:item
                                                                          section:@"mod"
                                                                  enabledRPCount:0]];
        }
    }

    // 4. RESOURCE PACKS section
    NSUInteger enabledRPCount = 0;
    for (NSDictionary *rp in rps) {
        if ([rp[@"enabled"] boolValue]) enabledRPCount += 1;
    }
    [self.installedStack addArrangedSubview:[self makeSectionCaption:[NSString stringWithFormat:HL(@"RESOURCE PACKS (%lu) · Highest priority first", @"РЕСУРСПАКИ (%lu) · Высший приоритет сверху"), (unsigned long)rps.count]]];
    if (rps.count == 0) {
        [self.installedStack addArrangedSubview:[self makeEmptyRow:HL(@"No resource packs installed.", @"Ресурспаки не установлены.")]];
    } else {
        for (NSDictionary *item in rps) {
            [self.installedStack addArrangedSubview:[self makeInstalledRowForItem:item
                                                                          section:@"resourcepack"
                                                                  enabledRPCount:enabledRPCount]];
        }
    }

    // 5. SHADERS section (radio selector + None / Off)
    [self.installedStack addArrangedSubview:[self makeSectionCaption:[NSString stringWithFormat:HL(@"SHADERS (%lu) · horizon-graphics.txt", @"ШЕЙДЕРЫ (%lu) · horizon-graphics.txt"), (unsigned long)shaders.count]]];
    [self.installedStack addArrangedSubview:[self makeShaderNoneRowSelected:(pickedShader.length == 0)]];
    for (NSDictionary *item in shaders) {
        [self.installedStack addArrangedSubview:[self makeInstalledRowForItem:item
                                                                      section:@"shader"
                                                              enabledRPCount:0]];
    }

    // 6. DATA PACKS section (per world)
    UIStackView *dpHeader = [[UIStackView alloc] init];
    dpHeader.axis = UILayoutConstraintAxisHorizontal;
    dpHeader.spacing = 8.0;
    dpHeader.alignment = UIStackViewAlignmentCenter;
    [dpHeader addArrangedSubview:[self makeSectionCaption:[NSString stringWithFormat:HL(@"DATA PACKS (%lu)", @"ДАТАПАКИ (%lu)"), (unsigned long)dps.count]]];
    [dpHeader addArrangedSubview:[[UIView alloc] init]];

    UIButton *wBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    NSString *wName = self.selectedWorld.length > 0 ? self.selectedWorld : HL(@"No worlds", @"Нет миров");
    NSArray *worlds = [ov[@"worlds"] isKindOfClass:NSArray.class] ? ov[@"worlds"] : @[];
    for (NSDictionary *w in worlds) {
        if ([w[@"folder"] isEqualToString:self.selectedWorld]) {
            wName = w[@"name"] ?: self.selectedWorld;
            break;
        }
    }
    [wBtn setTitle:[NSString stringWithFormat:HL(@"World: %@ ▾", @"Мир: %@ ▾"), wName] forState:UIControlStateNormal];
    [wBtn setTitleColor:hm_emerald() forState:UIControlStateNormal];
    wBtn.backgroundColor = hm_emeraldSoft();
    wBtn.layer.cornerRadius = 7.0;
    wBtn.titleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold];
    wBtn.contentEdgeInsets = UIEdgeInsetsMake(4.0, 9.0, 4.0, 9.0);
    [wBtn addTarget:self action:@selector(onWorldPickerTapped:) forControlEvents:UIControlEventTouchUpInside];
    [dpHeader addArrangedSubview:wBtn];
    [self.installedStack addArrangedSubview:dpHeader];

    if (self.selectedWorld.length == 0) {
        [self.installedStack addArrangedSubview:[self makeEmptyRow:HL(@"No local worlds found in Documents/saves/.", @"Локальные миры не найдены в Documents/saves/.")]];
    } else if (dps.count == 0) {
        [self.installedStack addArrangedSubview:[self makeEmptyRow:HL(@"No data packs in this world.", @"В этом мире датапаков нет.")]];
    } else {
        for (NSDictionary *item in dps) {
            [self.installedStack addArrangedSubview:[self makeInstalledRowForItem:item
                                                                          section:@"datapack"
                                                                  enabledRPCount:0]];
        }
    }
}

- (UIView *)makeEmptyRow:(NSString *)text {
    UIView *card = [self makeCard];
    UILabel *l = [[UILabel alloc] init];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.text = text;
    l.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    l.textColor = hm_textMuted();
    [card addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.topAnchor constraintEqualToAnchor:card.topAnchor constant:11.0],
        [l.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
        [l.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
        [l.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-11.0],
    ]];
    return card;
}

- (UIView *)makeShaderNoneRowSelected:(BOOL)selected {
    UIControl *card = [[UIControl alloc] init];
    card.backgroundColor = selected ? hm_emeraldSoft() : hm_cardBg();
    card.layer.cornerRadius = 11.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = (selected ? hm_emerald() : hm_hairline()).CGColor;
    [card addTarget:self action:@selector(onSelectShaderNone) forControlEvents:UIControlEventTouchUpInside];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.text = HL(@"None / Off (Vanilla Rendering)", @"Выкл. / Без шейдеров (ванильный рендер)");
    lbl.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    lbl.textColor = selected ? hm_emerald() : hm_textPrimary();
    [card addSubview:lbl];

    UIImageView *chk = [[UIImageView alloc] initWithImage:[HorizonIcons iconForKind:HorizonIconCheck pointSize:16.0]];
    chk.translatesAutoresizingMaskIntoConstraints = NO;
    chk.tintColor = hm_emerald();
    chk.hidden = !selected;
    [card addSubview:chk];

    [NSLayoutConstraint activateConstraints:@[
        [card.heightAnchor constraintEqualToConstant:44.0],
        [lbl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
        [lbl.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [chk.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
        [chk.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [chk.widthAnchor constraintEqualToConstant:16.0],
        [chk.heightAnchor constraintEqualToConstant:16.0],
    ]];
    return card;
}

- (void)onSelectShaderNone {
    [self selectShaderKey:@""];
}

- (UIView *)makeInstalledRowForItem:(NSDictionary *)item
                            section:(NSString *)section
                    enabledRPCount:(NSUInteger)enabledRPCount {
    BOOL enabled = [item[@"enabled"] boolValue];
    BOOL isShader = [section isEqualToString:@"shader"];
    BOOL isRP = [section isEqualToString:@"resourcepack"];
    BOOL isWasm = [item[@"is_wasm"] boolValue];
    BOOL heavyGpu = [item[@"heavy_gpu"] boolValue];
    BOOL hasUpdate = [item[@"has_update"] boolValue];
    BOOL managed = [item[@"managed"] boolValue];
    NSInteger prioIdx = [item[@"priority_index"] integerValue];
    NSString *key = item[@"key"] ?: @"";
    NSString *file = item[@"file"] ?: key;
    NSString *name = item[@"name"] ?: key;
    NSString *version = item[@"version"] ?: @"";
    NSString *updVer = item[@"update_version"] ?: @"";
    NSString *source = item[@"source"] ?: @"manual";
    NSString *projectId = item[@"project_id"] ?: @"";
    uint64_t sz = [item[@"size_bytes"] unsignedLongLongValue];

    UIView *card = [self makeCard];
    if (isShader && enabled) {
        card.backgroundColor = hm_emeraldSoft();
        card.layer.borderColor = hm_emerald().CGColor;
    }

    UILabel *titleLbl = [[UILabel alloc] init];
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
    titleLbl.text = (isRP && enabled && prioIdx >= 0)
        ? [NSString stringWithFormat:@"#%ld · %@", (long)(prioIdx + 1), name]
        : name;
    titleLbl.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    titleLbl.textColor = hm_textPrimary();
    titleLbl.lineBreakMode = NSLineBreakByTruncatingTail;
    [card addSubview:titleLbl];

    NSMutableArray<NSString *> *subParts = [NSMutableArray array];
    if (version.length > 0) [subParts addObject:[NSString stringWithFormat:@"v%@", version]];
    if ([source isEqualToString:@"horizon"]) [subParts addObject:@"Horizon Registry"];
    else if ([source isEqualToString:@"modrinth"]) [subParts addObject:@"Modrinth"];
    else [subParts addObject:HL(@"Manual", @"Вручную")];
    if (sz > 0) [subParts addObject:hm_formatBytes(sz)];

    UILabel *subLbl = [[UILabel alloc] init];
    subLbl.translatesAutoresizingMaskIntoConstraints = NO;
    subLbl.text = [subParts componentsJoinedByString:@" · "];
    subLbl.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    subLbl.textColor = hm_textSec();
    subLbl.lineBreakMode = NSLineBreakByTruncatingTail;
    [card addSubview:subLbl];

    UIStackView *badges = [[UIStackView alloc] init];
    badges.translatesAutoresizingMaskIntoConstraints = NO;
    badges.axis = UILayoutConstraintAxisHorizontal;
    badges.spacing = 5.0;
    if ([section isEqualToString:@"mod"]) {
        if (isWasm) {
            [badges addArrangedSubview:hm_makeBadge(@"WASM · Pulley", hm_emerald(), hm_emeraldSoft())];
        } else {
            [badges addArrangedSubview:hm_makeBadge(HL(@"Content", @"Контент"), hm_teal(), hm_tealSoft())];
        }
    }
    if (heavyGpu) {
        [badges addArrangedSubview:hm_makeBadge(HL(@"Heavy GPU", @"Высокая нагрузка GPU"), hm_amber(), hm_amberSoft())];
    }
    if (!managed) {
        [badges addArrangedSubview:hm_makeBadge(HL(@"Local file", @"Локальный файл"), hm_textSec(), hm_elevatedBg())];
    }
    [badges addArrangedSubview:[[UIView alloc] init]];
    [card addSubview:badges];

    // Right controls stack
    UIStackView *controls = [[UIStackView alloc] init];
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    controls.axis = UILayoutConstraintAxisHorizontal;
    controls.spacing = 6.0;
    controls.alignment = UIStackViewAlignmentCenter;
    [controls setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [card addSubview:controls];

    // Resource Pack Move Up / Move Down buttons (when enabled)
    if (isRP && enabled && enabledRPCount > 1) {
        UIButton *upBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [upBtn setImage:[HorizonIcons iconForKind:HorizonIconArrowUp pointSize:13.0] forState:UIControlStateNormal];
        upBtn.tintColor = (prioIdx > 0) ? hm_textPrimary() : hm_textMuted();
        upBtn.backgroundColor = hm_elevatedBg();
        upBtn.layer.cornerRadius = 7.0;
        upBtn.enabled = (prioIdx > 0);
        upBtn.accessibilityIdentifier = file;
        [upBtn.widthAnchor constraintEqualToConstant:30.0].active = YES;
        [upBtn.heightAnchor constraintEqualToConstant:30.0].active = YES;
        [upBtn addTarget:self action:@selector(onMoveRPUp:) forControlEvents:UIControlEventTouchUpInside];
        [controls addArrangedSubview:upBtn];

        UIButton *dnBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [dnBtn setImage:[HorizonIcons iconForKind:HorizonIconArrowDown pointSize:13.0] forState:UIControlStateNormal];
        dnBtn.tintColor = (prioIdx + 1 < (NSInteger)enabledRPCount) ? hm_textPrimary() : hm_textMuted();
        dnBtn.backgroundColor = hm_elevatedBg();
        dnBtn.layer.cornerRadius = 7.0;
        dnBtn.enabled = (prioIdx + 1 < (NSInteger)enabledRPCount);
        dnBtn.accessibilityIdentifier = file;
        [dnBtn.widthAnchor constraintEqualToConstant:30.0].active = YES;
        [dnBtn.heightAnchor constraintEqualToConstant:30.0].active = YES;
        [dnBtn addTarget:self action:@selector(onMoveRPDown:) forControlEvents:UIControlEventTouchUpInside];
        [controls addArrangedSubview:dnBtn];
    }

    // Update button (when managed update is available)
    if (hasUpdate && projectId.length > 0) {
        UIButton *updBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [updBtn setTitle:[NSString stringWithFormat:HL(@"Update %@", @"Обновить %@"), updVer] forState:UIControlStateNormal];
        [updBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        updBtn.backgroundColor = hm_emerald();
        updBtn.layer.cornerRadius = 7.0;
        updBtn.titleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightBold];
        updBtn.contentEdgeInsets = UIEdgeInsetsMake(5.0, 9.0, 5.0, 9.0);
        updBtn.accessibilityIdentifier = hm_toJSONString(@{
            @"source": source,
            @"project_id": projectId,
            @"kind": section,
            @"world": self.selectedWorld ?: @"",
            @"name": name,
        });
        [updBtn addTarget:self action:@selector(onUpdateSingleTapped:) forControlEvents:UIControlEventTouchUpInside];
        [controls addArrangedSubview:updBtn];
    }

    // Shader select button vs Enable UISwitch
    if (isShader) {
        UIButton *selBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [selBtn setTitle:enabled ? HL(@"Active ✓", @"Активен ✓") : HL(@"Use", @"Выбрать") forState:UIControlStateNormal];
        [selBtn setTitleColor:enabled ? hm_emerald() : hm_textPrimary() forState:UIControlStateNormal];
        selBtn.backgroundColor = enabled ? hm_emeraldSoft() : hm_elevatedBg();
        selBtn.layer.cornerRadius = 7.0;
        selBtn.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        selBtn.contentEdgeInsets = UIEdgeInsetsMake(5.0, 10.0, 5.0, 10.0);
        selBtn.accessibilityIdentifier = key;
        [selBtn addTarget:self action:@selector(onSelectShaderTapped:) forControlEvents:UIControlEventTouchUpInside];
        [controls addArrangedSubview:selBtn];
    } else {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = enabled;
        sw.onTintColor = hm_emerald();
        sw.accessibilityIdentifier = hm_toJSONString(@{
            @"kind": section,
            @"key": key,
            @"world": self.selectedWorld ?: @"",
        });
        [sw addTarget:self action:@selector(onInstalledSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        [controls addArrangedSubview:sw];
    }

    // Remove button
    UIButton *delBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [delBtn setImage:[HorizonIcons iconForKind:HorizonIconTrash pointSize:14.0] forState:UIControlStateNormal];
    delBtn.tintColor = hm_danger();
    delBtn.backgroundColor = hm_dangerSoft();
    delBtn.layer.cornerRadius = 7.0;
    delBtn.accessibilityIdentifier = hm_toJSONString(@{
        @"kind": section,
        @"key": key,
        @"world": self.selectedWorld ?: @"",
        @"name": name,
    });
    [delBtn.widthAnchor constraintEqualToConstant:30.0].active = YES;
    [delBtn.heightAnchor constraintEqualToConstant:30.0].active = YES;
    [delBtn addTarget:self action:@selector(onRemoveInstalledTapped:) forControlEvents:UIControlEventTouchUpInside];
    [controls addArrangedSubview:delBtn];

    [NSLayoutConstraint activateConstraints:@[
        [titleLbl.topAnchor constraintEqualToAnchor:card.topAnchor constant:9.0],
        [titleLbl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12.0],
        [titleLbl.trailingAnchor constraintLessThanOrEqualToAnchor:controls.leadingAnchor constant:-10.0],

        [subLbl.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:2.0],
        [subLbl.leadingAnchor constraintEqualToAnchor:titleLbl.leadingAnchor],
        [subLbl.trailingAnchor constraintLessThanOrEqualToAnchor:controls.leadingAnchor constant:-10.0],

        [badges.topAnchor constraintEqualToAnchor:subLbl.bottomAnchor constant:5.0],
        [badges.leadingAnchor constraintEqualToAnchor:titleLbl.leadingAnchor],
        [badges.trailingAnchor constraintLessThanOrEqualToAnchor:controls.leadingAnchor constant:-10.0],
        [badges.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-9.0],

        [controls.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10.0],
        [controls.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
    ]];
    return card;
}

- (void)onInstalledSwitchChanged:(UISwitch *)sender {
    NSData *d = [sender.accessibilityIdentifier dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *info = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![info isKindOfClass:NSDictionary.class]) return;
    [self toggleInstalledKind:info[@"kind"] ?: @""
                          key:info[@"key"] ?: @""
                        world:info[@"world"] ?: @""
                      enabled:sender.isOn];
}

- (void)onMoveRPUp:(UIButton *)sender {
    if (sender.accessibilityIdentifier.length > 0) {
        [self reorderResourcePack:sender.accessibilityIdentifier moveUp:YES];
    }
}

- (void)onMoveRPDown:(UIButton *)sender {
    if (sender.accessibilityIdentifier.length > 0) {
        [self reorderResourcePack:sender.accessibilityIdentifier moveUp:NO];
    }
}

- (void)onSelectShaderTapped:(UIButton *)sender {
    if (sender.accessibilityIdentifier.length > 0) {
        [self selectShaderKey:sender.accessibilityIdentifier];
    }
}

- (void)onUpdateSingleTapped:(UIButton *)sender {
    NSData *d = [sender.accessibilityIdentifier dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *info = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![info isKindOfClass:NSDictionary.class]) return;
    sender.enabled = NO;
    [sender setTitle:HL(@"Updating…", @"Обновление…") forState:UIControlStateNormal];

    NSString *dir = self.documentsDir;
    NSString *reqJSON = hm_toJSONString(@{
        @"update_all": @NO,
        @"source": info[@"source"] ?: @"horizon",
        @"project_id": info[@"project_id"] ?: @"",
        @"kind": info[@"kind"] ?: @"mod",
        @"world": info[@"world"] ?: @"",
    });
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        char *raw = horizon_ios_mods_update_json(dir.UTF8String, reqJSON.UTF8String);
        id parsed = hm_parseOwnedCStringJSON(raw);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = weakSelf;
            if (s == nil) return;
            BOOL ok = [parsed isKindOfClass:NSDictionary.class] && [parsed[@"ok"] boolValue];
            if (!ok) {
                NSString *err = [parsed isKindOfClass:NSDictionary.class] ? (parsed[@"error"] ?: @"") : @"";
                [s showAlertTitle:HL(@"Update Failed", @"Ошибка обновления") message:err];
            }
            s.availableUpdates = @[];
            [s refreshInstalledAndCheckUpdates:YES];
        });
    });
}

- (void)onRemoveInstalledTapped:(UIButton *)sender {
    NSData *d = [sender.accessibilityIdentifier dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *info = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![info isKindOfClass:NSDictionary.class]) return;
    NSString *name = info[@"name"] ?: info[@"key"] ?: @"";
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:HL(@"Remove Pack?", @"Удалить пакет?")
                                                                     message:[NSString stringWithFormat:HL(@"Delete \"%@\" from your device?", @"Удалить «%@» с устройства?"), name]
                                                              preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:HL(@"Remove", @"Удалить") style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        (void)action;
        [weakSelf removeItemKind:info[@"kind"] ?: @""
                             key:info[@"key"] ?: @""
                           world:info[@"world"] ?: @""
                      completion:nil];
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:HL(@"Cancel", @"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

#pragma mark - UITableViewDataSource & Delegate (Catalog)

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)self.catalogItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    HorizonCatalogCell *cell = [tableView dequeueReusableCellWithIdentifier:@"CatalogCell" forIndexPath:indexPath];
    NSDictionary *item = self.catalogItems[(NSUInteger)indexPath.row];

    NSString *name = item[@"name"] ?: @"";
    NSString *author = item[@"author"] ?: @"";
    NSString *summary = item[@"summary"] ?: @"";
    NSString *source = item[@"source"] ?: @"horizon";
    NSString *projectId = item[@"id"] ?: @"";
    NSString *kind = item[@"kind"] ?: @"mod";
    NSString *version = item[@"version"] ?: @"";
    NSString *iconURL = item[@"icon_url"] ?: @"";
    NSString *compat = item[@"game_compat"] ?: @"";
    uint64_t downloads = [item[@"downloads"] unsignedLongLongValue];
    BOOL isWasm = [item[@"is_wasm"] boolValue];
    BOOL desktopOnly = [item[@"desktop_only"] boolValue];
    BOOL heavyGpu = [item[@"heavy_gpu"] boolValue];
    BOOL official = [item[@"official"] boolValue];
    BOOL installable = [item[@"installable"] boolValue];
    BOOL installed = [item[@"installed"] boolValue];
    BOOL updateAvailable = [item[@"update_available"] boolValue];
    NSString *blockedReason = item[@"blocked_reason"] ?: @"";

    NSString *initial = name.length > 0 ? [[name substringToIndex:1] uppercaseString] : @"H";
    [self.iconCache loadIconURL:iconURL
                  intoImageView:cell.iconView
               placeholderLabel:cell.iconPlaceholder
                   fallbackChar:initial];

    cell.titleLabel.text = name;
    NSMutableArray<NSString *> *meta = [NSMutableArray array];
    if (author.length > 0) [meta addObject:[NSString stringWithFormat:HL(@"by %@", @"от %@"), author]];
    if (version.length > 0) [meta addObject:[NSString stringWithFormat:@"v%@", version]];
    if (downloads > 0) [meta addObject:hm_formatCount(downloads)];
    [meta addObject:[source isEqualToString:@"modrinth"] ? @"Modrinth" : @"Horizon"];
    cell.metaLabel.text = [meta componentsJoinedByString:@" · "];
    cell.summaryLabel.text = summary;

    // Badges
    for (UIView *sub in [cell.badgeStack.arrangedSubviews copy]) {
        [cell.badgeStack removeArrangedSubview:sub];
        [sub removeFromSuperview];
    }
    if (desktopOnly) {
        [cell.badgeStack addArrangedSubview:hm_makeBadge(HL(@"Desktop only", @"Только ПК"), hm_amber(), hm_amberSoft())];
    } else if ([kind isEqualToString:@"mod"]) {
        if (isWasm) {
            [cell.badgeStack addArrangedSubview:hm_makeBadge(@"WASM · Pulley", hm_emerald(), hm_emeraldSoft())];
        } else {
            [cell.badgeStack addArrangedSubview:hm_makeBadge(HL(@"Content", @"Контент"), hm_teal(), hm_tealSoft())];
        }
    } else if ([kind isEqualToString:@"shader"]) {
        [cell.badgeStack addArrangedSubview:hm_makeBadge(HL(@"Shader", @"Шейдер"), hm_teal(), hm_tealSoft())];
        if (heavyGpu) {
            [cell.badgeStack addArrangedSubview:hm_makeBadge(HL(@"Heavy GPU", @"Нагрузка GPU"), hm_amber(), hm_amberSoft())];
        }
    }
    if (compat.length > 0 && ([kind isEqualToString:@"resourcepack"] || [kind isEqualToString:@"datapack"])) {
        BOOL exact = [compat isEqualToString:@"26.3"];
        [cell.badgeStack addArrangedSubview:hm_makeBadge(compat, exact ? hm_emerald() : hm_amber(), exact ? hm_emeraldSoft() : hm_amberSoft())];
    }
    if (official) {
        [cell.badgeStack addArrangedSubview:hm_makeBadge(HL(@"Official", @"Офиц."), hm_emerald(), hm_emeraldSoft())];
    }
    if (!desktopOnly && blockedReason.length > 0) {
        [cell.badgeStack addArrangedSubview:hm_makeBadge(HL(@"Blocked", @"Недоступно"), hm_danger(), hm_dangerSoft())];
    }
    [cell.badgeStack addArrangedSubview:[[UIView alloc] init]];

    // Action button
    NSString *bkey = [self busyKeyForSource:source projectId:projectId];
    BOOL busy = [self.busyProjectKeys containsObject:bkey];
    if (busy) {
        cell.actionButton.hidden = YES;
        [cell.busySpinner startAnimating];
        cell.onActionTapped = nil;
    } else {
        cell.actionButton.hidden = NO;
        [cell.busySpinner stopAnimating];
        if (desktopOnly) {
            [cell.actionButton setTitle:HL(@"Desktop only", @"Только ПК") forState:UIControlStateNormal];
            [cell.actionButton setTitleColor:hm_amber() forState:UIControlStateNormal];
            cell.actionButton.backgroundColor = hm_amberSoft();
            cell.actionButton.enabled = NO;
            cell.onActionTapped = nil;
        } else if (!installable) {
            [cell.actionButton setTitle:HL(@"Unavailable", @"Недоступно") forState:UIControlStateNormal];
            [cell.actionButton setTitleColor:hm_textMuted() forState:UIControlStateNormal];
            cell.actionButton.backgroundColor = hm_elevatedBg();
            cell.actionButton.enabled = NO;
            cell.onActionTapped = nil;
        } else if (installed && updateAvailable) {
            [cell.actionButton setTitle:HL(@"Update", @"Обновить") forState:UIControlStateNormal];
            [cell.actionButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            cell.actionButton.backgroundColor = hm_emerald();
            cell.actionButton.enabled = YES;
            __weak typeof(self) weakSelf = self;
            cell.onActionTapped = ^{
                [weakSelf installCatalogItem:item completion:nil];
            };
        } else if (installed) {
            [cell.actionButton setTitle:HL(@"Installed ✓", @"Установлено ✓") forState:UIControlStateNormal];
            [cell.actionButton setTitleColor:hm_emerald() forState:UIControlStateNormal];
            cell.actionButton.backgroundColor = hm_emeraldSoft();
            cell.actionButton.enabled = NO;
            cell.onActionTapped = nil;
        } else {
            [cell.actionButton setTitle:HL(@"Install", @"Установить") forState:UIControlStateNormal];
            [cell.actionButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            cell.actionButton.backgroundColor = hm_emerald();
            cell.actionButton.enabled = YES;
            __weak typeof(self) weakSelf = self;
            cell.onActionTapped = ^{
                [weakSelf installCatalogItem:item completion:nil];
            };
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if ((NSUInteger)indexPath.row >= self.catalogItems.count) return;
    NSDictionary *item = self.catalogItems[(NSUInteger)indexPath.row];

    HorizonModDetailViewController *detail = [[HorizonModDetailViewController alloc] init];
    detail.documentsDir = self.documentsDir;
    detail.seedItem = item;
    detail.selectedWorld = self.selectedWorld;
    detail.iconCache = self.iconCache;
    detail.ioQueue = self.ioQueue;
    detail.modalPresentationStyle = UIModalPresentationFormSheet;
    __weak typeof(self) weakSelf = self;
    detail.onInstallAction = ^(NSDictionary *dItem, void (^done)(BOOL, NSString * _Nullable)) {
        [weakSelf installCatalogItem:dItem completion:done];
    };
    detail.onRemoveAction = ^(NSDictionary *dItem, void (^done)(BOOL, NSString * _Nullable)) {
        typeof(self) s = weakSelf;
        if (s == nil) return;
        NSString *kind = dItem[@"kind"] ?: @"mod";
        NSString *key = [kind isEqualToString:@"mod"] ? (dItem[@"id"] ?: @"") : (dItem[@"filename"] ?: dItem[@"id"] ?: @"");
        // For shaders/resourcepacks/datapacks look up installed key by project_id if filename wasn't loaded yet.
        NSString *pid = dItem[@"id"] ?: @"";
        NSString *listKey = [kind isEqualToString:@"mod"] ? @"mods"
            : [kind isEqualToString:@"resourcepack"] ? @"resourcepacks"
            : [kind isEqualToString:@"shader"] ? @"shaders" : @"datapacks";
        NSArray *list = [s.installedOverview[listKey] isKindOfClass:NSArray.class] ? s.installedOverview[listKey] : @[];
        for (NSDictionary *inst in list) {
            if ([inst[@"project_id"] isEqualToString:pid] && [inst[@"key"] isKindOfClass:NSString.class]) {
                key = inst[@"key"];
                break;
            }
        }
        [s removeItemKind:kind key:key world:s.selectedWorld ?: @"" completion:done];
    };
    [self presentViewController:detail animated:YES completion:nil];
}

- (void)showAlertTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:HL(@"OK", @"ОК") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
