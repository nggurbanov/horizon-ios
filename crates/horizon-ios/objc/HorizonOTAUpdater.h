// horizon-ios: native OTA updater supporting Feather, SideStore, AltStore, and Safari fallback
// backed by an AltStore/Feather Source v2 JSON manifest.
#pragma once

#import "HorizonSettings.h"
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const HorizonOTAStateDidChangeNotification;

typedef NS_ENUM(NSInteger, HorizonOTAStatus) {
    HorizonOTAStatusIdle = 0,
    HorizonOTAStatusChecking = 1,
    HorizonOTAStatusUpToDate = 2,
    HorizonOTAStatusUpdateAvailable = 3,
    HorizonOTAStatusError = 4,
};

@interface HorizonOTARelease : NSObject
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *buildVersion;
@property (nonatomic, copy) NSString *dateString;
@property (nonatomic, copy) NSString *releaseNotes;
@property (nonatomic, copy) NSString *downloadURL;
@property (nonatomic, assign) uint64_t sizeBytes;
@property (nonatomic, copy) NSString *minOSVersion;
@end

@interface HorizonOTAUpdater : NSObject

+ (instancetype)shared;

@property (nonatomic, assign, readonly) HorizonOTAStatus status;
@property (nonatomic, strong, readonly, nullable) HorizonOTARelease *latestRelease;
@property (nonatomic, copy, readonly, nullable) NSString *lastErrorMessage;
@property (nonatomic, strong, readonly, nullable) NSDate *lastCheckedAt;

- (NSString *)currentVersion;
- (NSString *)currentBuildVersion;
- (BOOL)isUpdateAvailable;

/// Starts an asynchronous non-cached check against `HorizonSettings.shared.otaSourceURL`.
- (void)checkForUpdatesForce:(BOOL)force;

/// Verified deep-link URL builders (delegated to Rust FFI `horizon_ios_ota_*`).
+ (nullable NSURL *)installURLForInstaller:(HorizonOTAInstaller)installer ipaURL:(NSString *)ipaURL;
+ (nullable NSURL *)sourceURLForInstaller:(HorizonOTAInstaller)installer sourceURL:(NSString *)sourceURL;
+ (BOOL)isInstallerAvailable:(HorizonOTAInstaller)installer;
+ (NSString *)displayNameForInstaller:(HorizonOTAInstaller)installer;

/// Launches the configured installer (or smart auto-detect / action sheet in Auto mode).
- (void)installUpdateFromViewController:(UIViewController *)vc sourceView:(nullable UIView *)sourceView;

/// Opens the Feather / SideStore / AltStore add-repo-source deep link.
- (void)addRepoSourceWithInstaller:(HorizonOTAInstaller)installer
                fromViewController:(UIViewController *)vc;

@end

NS_ASSUME_NONNULL_END
