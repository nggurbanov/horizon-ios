// horizon-ios: native UIKit Mod & Pack Browser/Manager view controller embedded in Pre-Launcher.
#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface HorizonModsViewController : UIViewController

/// Called on the main queue whenever installed count or available updates count changes.
@property (nonatomic, copy, nullable) void (^onInstalledSummaryChanged)(NSUInteger installedCount, NSUInteger updatesCount);

- (instancetype)initWithDocumentsDir:(NSString *)documentsDir NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Reloads installed mods/packs/shaders/datapacks from disk; optionally checks for remote updates.
- (void)refreshInstalledAndCheckUpdates:(BOOL)checkNetwork;

/// Updates all localized UI strings immediately after the user switches EN/RU language.
- (void)rebuildForLanguageChange;

/// Ensures the active catalog tab has performed its initial fetch when the Mods tab is opened.
- (void)activateIfNeeded;

@end

NS_ASSUME_NONNULL_END
