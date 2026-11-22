// horizon-ios: per-server auto-login metadata (NSUserDefaults) and secure password storage
// (iOS Keychain primary, app-private Library/Application Support fallback for sideload/LiveContainer).
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HorizonAutoLoginConfig : NSObject
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, copy) NSString *templateString; // default @"/l {password}"
@property (nonatomic, assign) uint64_t delayMs;       // 500, 1000, 2000, 3000 (default 1000)
@property (nonatomic, assign) BOOL hasPassword;
@end

@interface HorizonAutoLoginStore : NSObject

+ (instancetype)shared;

/// Normalizes a server address via Rust's `horizon_ios_normalize_server_address`.
+ (nullable NSString *)normalizeAddress:(NSString *)address;

/// Loads config metadata and whether a non-empty password is stored for `address`.
- (HorizonAutoLoginConfig *)configForAddress:(NSString *)address;

/// Saves config metadata; if `newPassword` is non-nil (non-empty), updates the stored password.
/// If `clearPassword` is YES, removes the stored password.
- (void)saveConfig:(HorizonAutoLoginConfig *)config
       newPassword:(nullable NSString *)newPassword
     clearPassword:(BOOL)clearPassword
        forAddress:(NSString *)address;

/// Migrates auto-login metadata & password when a server's address is edited.
- (void)migrateFromAddress:(NSString *)oldAddress toAddress:(NSString *)newAddress;

/// Deletes both metadata and stored password for `address`.
- (void)deleteForAddress:(NSString *)address;

@end

NS_ASSUME_NONNULL_END
