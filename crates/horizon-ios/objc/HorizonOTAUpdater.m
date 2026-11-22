// horizon-ios: native OTA updater supporting Feather, SideStore, AltStore, and Safari fallback
// backed by an AltStore/Feather Source v2 JSON manifest.
#import "HorizonOTAUpdater.h"
#import "HorizonL10n.h"
#include "horizon_bridge.h"

NSNotificationName const HorizonOTAStateDidChangeNotification = @"HorizonOTAStateDidChangeNotification";

static NSString * const kDefaultBundleID = @"io.github.nggurbanov.horizon-ios";

@implementation HorizonOTARelease
@end

@interface HorizonOTAUpdater ()
@property (nonatomic, assign, readwrite) HorizonOTAStatus status;
@property (nonatomic, strong, readwrite, nullable) HorizonOTARelease *latestRelease;
@property (nonatomic, copy, readwrite, nullable) NSString *lastErrorMessage;
@property (nonatomic, strong, readwrite, nullable) NSDate *lastCheckedAt;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *activeTask;
@property (nonatomic, assign) NSUInteger checkGeneration;
@end

@implementation HorizonOTAUpdater

+ (instancetype)shared {
    static HorizonOTAUpdater *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[HorizonOTAUpdater alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.timeoutIntervalForRequest = 8.0;
        cfg.timeoutIntervalForResource = 10.0;
        cfg.URLCache = nil;
        _session = [NSURLSession sessionWithConfiguration:cfg];
        _status = HorizonOTAStatusIdle;
    }
    return self;
}

- (NSString *)currentVersion {
    id val = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"];
    if ([val isKindOfClass:NSString.class] && [(NSString *)val length] > 0) {
        return (NSString *)val;
    }
    return @"0.1.0";
}

- (NSString *)currentBuildVersion {
    id val = NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"];
    if ([val isKindOfClass:NSString.class] && [(NSString *)val length] > 0) {
        return (NSString *)val;
    }
    return @"";
}

- (BOOL)isUpdateAvailable {
    return self.status == HorizonOTAStatusUpdateAvailable &&
           self.latestRelease != nil &&
           self.latestRelease.downloadURL.length > 0;
}

+ (nullable NSURL *)installURLForInstaller:(HorizonOTAInstaller)installer ipaURL:(NSString *)ipaURL {
    if (ipaURL.length == 0) return nil;
    char *raw = horizon_ios_ota_install_url((uint8_t)installer, ipaURL.UTF8String);
    if (raw == NULL) return nil;
    NSString *str = [NSString stringWithUTF8String:raw];
    horizon_ios_free_string(raw);
    return (str.length > 0) ? [NSURL URLWithString:str] : nil;
}

+ (nullable NSURL *)sourceURLForInstaller:(HorizonOTAInstaller)installer sourceURL:(NSString *)sourceURL {
    if (sourceURL.length == 0) return nil;
    char *raw = horizon_ios_ota_source_url((uint8_t)installer, sourceURL.UTF8String);
    if (raw == NULL) return nil;
    NSString *str = [NSString stringWithUTF8String:raw];
    horizon_ios_free_string(raw);
    return (str.length > 0) ? [NSURL URLWithString:str] : nil;
}

+ (BOOL)isInstallerAvailable:(HorizonOTAInstaller)installer {
    NSString *probe = nil;
    switch (installer) {
        case HorizonOTAInstallerFeather:   probe = @"feather://"; break;
        case HorizonOTAInstallerSideStore: probe = @"sidestore://"; break;
        case HorizonOTAInstallerAltStore:  probe = @"altstore://"; break;
        case HorizonOTAInstallerDirect:    return YES;
        case HorizonOTAInstallerAuto:
        default:                           return NO;
    }
    NSURL *url = [NSURL URLWithString:probe];
    if (url == nil) return NO;
    return [UIApplication.sharedApplication canOpenURL:url];
}

+ (NSString *)displayNameForInstaller:(HorizonOTAInstaller)installer {
    switch (installer) {
        case HorizonOTAInstallerFeather:   return @"Feather";
        case HorizonOTAInstallerSideStore: return @"SideStore";
        case HorizonOTAInstallerAltStore:  return @"AltStore";
        case HorizonOTAInstallerDirect:    return @"Safari";
        case HorizonOTAInstallerAuto:
        default:                           return HL(@"Auto", @"Авто");
    }
}

- (void)postStateChanged {
    dispatch_block_t block = ^{
        [NSNotificationCenter.defaultCenter postNotificationName:HorizonOTAStateDidChangeNotification object:self];
    };
    if (NSThread.isMainThread) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

- (void)checkForUpdatesForce:(BOOL)force {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self checkForUpdatesForce:force];
        });
        return;
    }

    if (self.status == HorizonOTAStatusChecking && !force) {
        return;
    }
    [self.activeTask cancel];
    self.activeTask = nil;

    NSString *rawURL = [HorizonSettings.shared.otaSourceURL
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURL *url = [NSURL URLWithString:rawURL];
    if (url == nil || (![url.scheme.lowercaseString isEqualToString:@"https"] &&
                       ![url.scheme.lowercaseString isEqualToString:@"http"])) {
        self.status = HorizonOTAStatusError;
        self.lastErrorMessage = HL(@"Invalid source.json URL", @"Некорректный URL источника source.json");
        [self postStateChanged];
        return;
    }

    self.checkGeneration += 1;
    NSUInteger gen = self.checkGeneration;
    self.status = HorizonOTAStatusChecking;
    self.lastErrorMessage = nil;
    [self postStateChanged];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:8.0];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [req setValue:[NSString stringWithFormat:@"Horizon-iOS/%@", self.currentVersion]
forHTTPHeaderField:@"User-Agent"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:req
                                                 completionHandler:^(NSData * _Nullable data,
                                                                     NSURLResponse * _Nullable response,
                                                                     NSError * _Nullable error) {
        [weakSelf handleFetchResponse:response data:data error:error generation:gen];
    }];
    self.activeTask = task;
    [task resume];
}

static NSString *ota_stringField(NSDictionary *dict, NSString *key) {
    id v = dict[key];
    if ([v isKindOfClass:NSString.class]) {
        return [(NSString *)v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    return @"";
}

static uint64_t ota_uint64Field(NSDictionary *dict, NSString *key) {
    id v = dict[key];
    if ([v isKindOfClass:NSNumber.class]) {
        return [(NSNumber *)v unsignedLongLongValue];
    }
    return 0;
}

- (nullable HorizonOTARelease *)parseSourceJSON:(NSData *)data errorMessage:(NSString * _Nullable * _Nonnull)outErr {
    NSError *jsonErr = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
    if (jsonErr != nil || ![root isKindOfClass:NSDictionary.class]) {
        *outErr = HL(@"Invalid source.json manifest", @"Некорректный JSON-манифест source.json");
        return nil;
    }

    NSDictionary *manifest = (NSDictionary *)root;
    NSArray *apps = [manifest[@"apps"] isKindOfClass:NSArray.class] ? manifest[@"apps"] : nil;
    if (apps.count == 0) {
        *outErr = HL(@"No apps found in source.json", @"В source.json отсутствует список приложений");
        return nil;
    }

    NSString *myBundleID = NSBundle.mainBundle.bundleIdentifier ?: kDefaultBundleID;
    NSDictionary *matchedApp = nil;
    for (id item in apps) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *bid = ota_stringField((NSDictionary *)item, @"bundleIdentifier");
        if ([bid isEqualToString:myBundleID] || [bid isEqualToString:kDefaultBundleID]) {
            matchedApp = (NSDictionary *)item;
            break;
        }
    }
    if (matchedApp == nil && [apps.firstObject isKindOfClass:NSDictionary.class]) {
        matchedApp = (NSDictionary *)apps.firstObject;
    }
    if (matchedApp == nil) {
        *outErr = HL(@"Horizon entry not found in source.json", @"Запись Horizon не найдена в source.json");
        return nil;
    }

    // Prefer modern Source v2 `versions[0]`, falling back to legacy top-level fields.
    NSDictionary *latestEntry = nil;
    id versionsObj = matchedApp[@"versions"];
    if ([versionsObj isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)versionsObj) {
            if ([item isKindOfClass:NSDictionary.class]) {
                latestEntry = (NSDictionary *)item;
                break;
            }
        }
    }

    NSString *ver = latestEntry ? ota_stringField(latestEntry, @"version") : @"";
    if (ver.length == 0) ver = ota_stringField(matchedApp, @"version");

    NSString *buildVer = latestEntry ? ota_stringField(latestEntry, @"buildVersion") : @"";
    if (buildVer.length == 0) buildVer = ota_stringField(matchedApp, @"buildVersion");

    NSString *dateStr = latestEntry ? ota_stringField(latestEntry, @"date") : @"";
    if (dateStr.length == 0) dateStr = ota_stringField(matchedApp, @"versionDate");

    NSString *notes = latestEntry ? ota_stringField(latestEntry, @"localizedDescription") : @"";
    if (notes.length == 0) notes = ota_stringField(matchedApp, @"versionDescription");

    NSString *dlURL = latestEntry ? ota_stringField(latestEntry, @"downloadURL") : @"";
    if (dlURL.length == 0) dlURL = ota_stringField(matchedApp, @"downloadURL");

    uint64_t sizeBytes = latestEntry ? ota_uint64Field(latestEntry, @"size") : 0;
    if (sizeBytes == 0) sizeBytes = ota_uint64Field(matchedApp, @"size");

    NSString *minOS = latestEntry ? ota_stringField(latestEntry, @"minOSVersion") : @"";

    if (ver.length == 0 || dlURL.length == 0) {
        *outErr = HL(@"Missing version or downloadURL in source.json", @"В source.json не указаны версия или downloadURL");
        return nil;
    }

    HorizonOTARelease *rel = [[HorizonOTARelease alloc] init];
    rel.version = ver;
    rel.buildVersion = buildVer;
    rel.dateString = dateStr;
    rel.releaseNotes = notes;
    rel.downloadURL = dlURL;
    rel.sizeBytes = sizeBytes;
    rel.minOSVersion = minOS;
    return rel;
}

- (void)handleFetchResponse:(nullable NSURLResponse *)response
                       data:(nullable NSData *)data
                      error:(nullable NSError *)error
                 generation:(NSUInteger)gen {
    if (error != nil && error.code == NSURLErrorCancelled) {
        return;
    }

    HorizonOTARelease *parsed = nil;
    NSString *errText = nil;

    if (error != nil) {
        errText = error.localizedDescription ?: HL(@"Unable to reach update server", @"Нет соединения с сервером");
    } else if ([response isKindOfClass:NSHTTPURLResponse.class]) {
        NSInteger code = ((NSHTTPURLResponse *)response).statusCode;
        if (code < 200 || code >= 300) {
            errText = [NSString stringWithFormat:HL(@"Server returned HTTP %ld", @"Сервер вернул HTTP %ld"), (long)code];
        }
    }

    if (errText == nil) {
        if (data.length == 0) {
            errText = HL(@"Empty response from update server", @"Пустой ответ от сервера обновлений");
        } else {
            parsed = [self parseSourceJSON:data errorMessage:&errText];
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.checkGeneration != gen) return;
        self.activeTask = nil;
        self.lastCheckedAt = NSDate.date;

        if (parsed == nil) {
            self.status = HorizonOTAStatusError;
            self.lastErrorMessage = errText ?: HL(@"Failed to check for updates", @"Не удалось проверить обновления");
            [self postStateChanged];
            return;
        }

        self.latestRelease = parsed;
        self.lastErrorMessage = nil;
        BOOL newer = horizon_ios_ota_is_newer(
            self.currentVersion.UTF8String,
            self.currentBuildVersion.UTF8String,
            parsed.version.UTF8String,
            parsed.buildVersion.UTF8String
        );
        self.status = newer ? HorizonOTAStatusUpdateAvailable : HorizonOTAStatusUpToDate;
        [self postStateChanged];
    });
}

#pragma mark - Install & Repo Deep-Link Actions

- (void)openInstallWithInstaller:(HorizonOTAInstaller)installer
                          ipaURL:(NSString *)ipaURL
              fromViewController:(UIViewController *)vc
                      sourceView:(nullable UIView *)sourceView {
    NSURL *targetURL = [HorizonOTAUpdater installURLForInstaller:installer ipaURL:ipaURL];
    if (targetURL == nil) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:HL(@"Invalid Link", @"Ошибка ссылки")
                                                                   message:HL(@"Invalid .ipa download URL.", @"Некорректный адрес .ipa для установки.")
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:HL(@"OK", @"ОК") style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
        return;
    }

    __weak typeof(self) weakSelf = self;
    __weak UIViewController *weakVC = vc;
    __weak UIView *weakSource = sourceView;
    [UIApplication.sharedApplication openURL:targetURL options:@{} completionHandler:^(BOOL success) {
        if (success) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *strongVC = weakVC;
            typeof(self) s = weakSelf;
            if (strongVC == nil || s == nil) return;

            NSString *appName = [HorizonOTAUpdater displayNameForInstaller:installer];
            NSString *title = [NSString stringWithFormat:HL(@"Couldn't Open %@", @"Не удалось открыть %@"), appName];
            NSString *msg = (installer == HorizonOTAInstallerDirect)
                ? HL(@"Couldn't open the download link in Safari.", @"Не удалось открыть ссылку загрузки в Safari.")
                : [NSString stringWithFormat:HL(@"Make sure %@ is installed on this device, download the .ipa in Safari, or choose another installer.", @"Убедитесь, что %@ установлен на устройстве, либо скачайте .ipa через Safari или выберите другой установщик."), appName];

            UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                           message:msg
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            if (installer != HorizonOTAInstallerDirect) {
                [alert addAction:[UIAlertAction actionWithTitle:HL(@"Download .ipa in Safari", @"Скачать .ipa (Safari)")
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(UIAlertAction * _Nonnull action) {
                    (void)action;
                    [s openInstallWithInstaller:HorizonOTAInstallerDirect
                                         ipaURL:ipaURL
                             fromViewController:strongVC
                                     sourceView:weakSource];
                }]];
                [alert addAction:[UIAlertAction actionWithTitle:HL(@"Choose Installer", @"Выбрать установщик")
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(UIAlertAction * _Nonnull action) {
                    (void)action;
                    [s presentInstallerSheetForIPAURL:ipaURL
                                   fromViewController:strongVC
                                           sourceView:weakSource];
                }]];
            }
            [alert addAction:[UIAlertAction actionWithTitle:HL(@"Cancel", @"Отмена") style:UIAlertActionStyleCancel handler:nil]];
            [strongVC presentViewController:alert animated:YES completion:nil];
        });
    }];
}

- (void)presentInstallerSheetForIPAURL:(NSString *)ipaURL
                    fromViewController:(UIViewController *)vc
                            sourceView:(nullable UIView *)sourceView {
    NSString *ver = self.latestRelease.version ?: @"";
    NSString *title = (ver.length > 0)
        ? [NSString stringWithFormat:HL(@"Install Horizon %@", @"Установить Horizon %@"), ver]
        : HL(@"Install Horizon Update", @"Установить обновление Horizon");
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:HL(@"Choose how to install the .ipa", @"Выберите способ установки .ipa")
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    __weak UIViewController *weakVC = vc;
    __weak UIView *weakSource = sourceView;

    void (^addChoice)(NSString *, HorizonOTAInstaller) = ^(NSString *label, HorizonOTAInstaller kind) {
        [sheet addAction:[UIAlertAction actionWithTitle:label
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            (void)action;
            UIViewController *strongVC = weakVC;
            if (strongVC == nil) return;
            [weakSelf openInstallWithInstaller:kind
                                        ipaURL:ipaURL
                            fromViewController:strongVC
                                    sourceView:weakSource];
        }]];
    };

    addChoice(HL(@"Install via Feather", @"Установить через Feather"), HorizonOTAInstallerFeather);
    addChoice(HL(@"Install via SideStore", @"Установить через SideStore"), HorizonOTAInstallerSideStore);
    addChoice(HL(@"Install via AltStore", @"Установить через AltStore"), HorizonOTAInstallerAltStore);
    addChoice(HL(@"Download .ipa in Safari", @"Скачать .ipa (Safari)"), HorizonOTAInstallerDirect);
    [sheet addAction:[UIAlertAction actionWithTitle:HL(@"Cancel", @"Отмена") style:UIAlertActionStyleCancel handler:nil]];

    if (sheet.popoverPresentationController != nil) {
        UIView *anchor = sourceView ?: vc.view;
        sheet.popoverPresentationController.sourceView = anchor;
        if (sourceView != nil) {
            sheet.popoverPresentationController.sourceRect = sourceView.bounds;
        } else {
            sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(anchor.bounds), CGRectGetMidY(anchor.bounds), 1.0, 1.0);
        }
    }
    [vc presentViewController:sheet animated:YES completion:nil];
}

- (void)installUpdateFromViewController:(UIViewController *)vc sourceView:(nullable UIView *)sourceView {
    NSString *ipaURL = self.latestRelease.downloadURL;
    if (ipaURL.length == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:HL(@"No Update Info", @"Нет данных об обновлении")
                                                                   message:HL(@"Check for updates first.", @"Сначала выполните проверку обновлений.")
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:HL(@"OK", @"ОК") style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
        return;
    }

    HorizonOTAInstaller pref = HorizonSettings.shared.otaInstaller;
    if (pref != HorizonOTAInstallerAuto) {
        [self openInstallWithInstaller:pref ipaURL:ipaURL fromViewController:vc sourceView:sourceView];
        return;
    }

    // Auto mode: detect installed sideloaders; open immediately if exactly one is found.
    NSMutableArray<NSNumber *> *detected = [NSMutableArray array];
    HorizonOTAInstaller candidates[3] = {
        HorizonOTAInstallerFeather,
        HorizonOTAInstallerSideStore,
        HorizonOTAInstallerAltStore,
    };
    for (int i = 0; i < 3; i++) {
        if ([HorizonOTAUpdater isInstallerAvailable:candidates[i]]) {
            [detected addObject:@(candidates[i])];
        }
    }

    if (detected.count == 1) {
        HorizonOTAInstaller only = (HorizonOTAInstaller)detected.firstObject.integerValue;
        [self openInstallWithInstaller:only ipaURL:ipaURL fromViewController:vc sourceView:sourceView];
    } else {
        [self presentInstallerSheetForIPAURL:ipaURL fromViewController:vc sourceView:sourceView];
    }
}

- (void)addRepoSourceWithInstaller:(HorizonOTAInstaller)installer
                fromViewController:(UIViewController *)vc {
    NSString *srcURL = HorizonSettings.shared.otaSourceURL;
    NSURL *targetURL = [HorizonOTAUpdater sourceURLForInstaller:installer sourceURL:srcURL];
    if (targetURL == nil) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:HL(@"Invalid URL", @"Некорректный URL")
                                                                   message:HL(@"Check the source.json URL in OTA settings.", @"Проверьте адрес source.json в настройках OTA.")
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:HL(@"OK", @"ОК") style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
        return;
    }

    __weak UIViewController *weakVC = vc;
    [UIApplication.sharedApplication openURL:targetURL options:@{} completionHandler:^(BOOL success) {
        if (success) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *strongVC = weakVC;
            if (strongVC == nil) return;
            NSString *name = [HorizonOTAUpdater displayNameForInstaller:installer];
            UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:HL(@"Couldn't Open %@", @"Не удалось открыть %@"), name]
                                                                       message:[NSString stringWithFormat:HL(@"Make sure %@ is installed, or copy the repository URL manually.", @"Убедитесь, что %@ установлен, или скопируйте ссылку репозитория вручную."), name]
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:HL(@"Copy URL", @"Копировать URL")
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
                (void)action;
                UIPasteboard.generalPasteboard.string = srcURL;
            }]];
            [a addAction:[UIAlertAction actionWithTitle:HL(@"Cancel", @"Отмена") style:UIAlertActionStyleCancel handler:nil]];
            [strongVC presentViewController:a animated:YES completion:nil];
        });
    }];
}

@end
