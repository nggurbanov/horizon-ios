// horizon-ios: per-server auto-login secure password storage.
// Primary: iOS Keychain (`kSecClassGenericPassword`, service `io.github.nggurbanov.horizon-ios.autologin`).
// Fallback (sideload / LiveContainer missing Keychain entitlement -34018):
//   Library/Application Support/horizon-autologin.plist (0600, CompleteUntilFirstUserAuthentication).
// STRICT SECURITY: NEVER logs passwords or rendered commands anywhere.
#import "HorizonAutoLoginStore.h"
#import <Security/Security.h>
#include "horizon_bridge.h"
#include <string.h>
#include <sys/stat.h>

static NSString * const kAutoLoginService     = @"io.github.nggurbanov.horizon-ios.autologin";
static NSString * const kAutoLoginDefaultsKey = @"horizon.autologin.meta.v1";
static NSString * const kDefaultTemplate      = @"/l {password}";
static const uint64_t   kDefaultDelayMs       = 1000;

@implementation HorizonAutoLoginConfig
- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _enabled = NO;
        _templateString = kDefaultTemplate;
        _delayMs = kDefaultDelayMs;
        _hasPassword = NO;
    }
    return self;
}
@end

@implementation HorizonAutoLoginStore

+ (instancetype)shared {
    static HorizonAutoLoginStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[HorizonAutoLoginStore alloc] init];
    });
    return instance;
}

+ (nullable NSString *)normalizeAddress:(NSString *)address {
    if (address.length == 0) return nil;
    char *raw = horizon_ios_normalize_server_address(address.UTF8String);
    if (raw == NULL) return nil;
    NSString *result = [NSString stringWithUTF8String:raw];
    horizon_ios_free_string(raw);
    return result;
}

#pragma mark - App-Private Fallback File (Library/Application Support, NEVER Documents/)

- (nullable NSURL *)fallbackFileURLCreatingDirectory:(BOOL)createDir {
    NSArray<NSURL *> *dirs = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                                  inDomains:NSUserDomainMask];
    NSURL *base = dirs.firstObject;
    if (base == nil) return nil;
    if (createDir) {
        NSError *err = nil;
        [NSFileManager.defaultManager createDirectoryAtURL:base
                               withIntermediateDirectories:YES
                                                attributes:@{NSFilePosixPermissions: @(0700)}
                                                     error:&err];
    }
    return [base URLByAppendingPathComponent:@"horizon-autologin.plist"];
}

- (NSMutableDictionary<NSString *, NSString *> *)loadFallbackPasswords {
    NSURL *url = [self fallbackFileURLCreatingDirectory:NO];
    if (url == nil) return [NSMutableDictionary dictionary];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (data.length == 0) return [NSMutableDictionary dictionary];
    id obj = [NSPropertyListSerialization propertyListWithData:data
                                                       options:NSPropertyListMutableContainers
                                                        format:NULL
                                                         error:nil];
    if ([obj isKindOfClass:NSMutableDictionary.class]) {
        return (NSMutableDictionary *)obj;
    }
    return [NSMutableDictionary dictionary];
}

- (void)writeFallbackPasswords:(NSDictionary<NSString *, NSString *> *)dict {
    NSURL *url = [self fallbackFileURLCreatingDirectory:YES];
    if (url == nil) return;
    if (dict.count == 0) {
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        return;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dict
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:nil];
    if (data == nil) return;
    [data writeToURL:url
             options:(NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication)
               error:nil];
    chmod(url.fileSystemRepresentation, 0600);
}

#pragma mark - Keychain + Fallback Password Accessors

- (BOOL)savePasswordToKeychain:(NSString *)password forNormalizedKey:(NSString *)key {
    NSData *pwData = [password dataUsingEncoding:NSUTF8StringEncoding];
    if (pwData == nil) return NO;

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kAutoLoginService,
        (__bridge id)kSecAttrAccount: key,
    };
    NSDictionary *updateAttrs = @{
        (__bridge id)kSecValueData: pwData,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    };
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)updateAttrs);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *addQuery = [query mutableCopy];
        addQuery[(__bridge id)kSecValueData] = pwData;
        addQuery[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
    }
    return status == errSecSuccess;
}

- (nullable NSString *)readPasswordFromKeychainForNormalizedKey:(NSString *)key outStatus:(OSStatus *)outStatus {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kAutoLoginService,
        (__bridge id)kSecAttrAccount: key,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (outStatus != NULL) *outStatus = status;
    if (status != errSecSuccess || result == NULL) {
        return nil;
    }
    NSData *data = (__bridge_transfer NSData *)result;
    if (![data isKindOfClass:NSData.class] || data.length == 0) {
        return nil;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (void)deletePasswordFromKeychainForNormalizedKey:(NSString *)key {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kAutoLoginService,
        (__bridge id)kSecAttrAccount: key,
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
}

- (void)storePassword:(NSString *)password forNormalizedKey:(NSString *)key {
    if (key.length == 0 || password.length == 0) return;
    if ([self savePasswordToKeychain:password forNormalizedKey:key]) {
        // Keychain succeeded: remove any stale fallback entry for this key.
        NSMutableDictionary *fallback = [self loadFallbackPasswords];
        if (fallback[key] != nil) {
            [fallback removeObjectForKey:key];
            [self writeFallbackPasswords:fallback];
        }
        return;
    }
    // Sideload / LiveContainer fallback (e.g. errSecMissingEntitlement -34018).
    NSMutableDictionary *fallback = [self loadFallbackPasswords];
    fallback[key] = password;
    [self writeFallbackPasswords:fallback];
}

- (nullable NSString *)readPasswordForNormalizedKey:(NSString *)key {
    if (key.length == 0) return nil;
    OSStatus status = errSecSuccess;
    NSString *pw = [self readPasswordFromKeychainForNormalizedKey:key outStatus:&status];
    if (pw.length > 0) {
        return pw;
    }
    NSMutableDictionary *fallback = [self loadFallbackPasswords];
    NSString *fb = fallback[key];
    return ([fb isKindOfClass:NSString.class] && fb.length > 0) ? fb : nil;
}

- (void)deletePasswordForNormalizedKey:(NSString *)key {
    if (key.length == 0) return;
    [self deletePasswordFromKeychainForNormalizedKey:key];
    NSMutableDictionary *fallback = [self loadFallbackPasswords];
    if (fallback[key] != nil) {
        [fallback removeObjectForKey:key];
        [self writeFallbackPasswords:fallback];
    }
}

#pragma mark - Metadata (NSUserDefaults)

- (NSMutableDictionary<NSString *, NSDictionary *> *)loadMetaMap {
    NSDictionary *raw = [NSUserDefaults.standardUserDefaults dictionaryForKey:kAutoLoginDefaultsKey];
    if ([raw isKindOfClass:NSDictionary.class]) {
        return [raw mutableCopy];
    }
    return [NSMutableDictionary dictionary];
}

- (void)saveMetaMap:(NSDictionary<NSString *, NSDictionary *> *)map {
    [NSUserDefaults.standardUserDefaults setObject:map forKey:kAutoLoginDefaultsKey];
}

- (HorizonAutoLoginConfig *)configForNormalizedKey:(NSString *)key {
    HorizonAutoLoginConfig *cfg = [[HorizonAutoLoginConfig alloc] init];
    if (key.length == 0) return cfg;
    NSDictionary *map = [self loadMetaMap];
    NSDictionary *entry = map[key];
    if ([entry isKindOfClass:NSDictionary.class]) {
        cfg.enabled = [entry[@"enabled"] boolValue];
        NSString *tmpl = entry[@"template"];
        if ([tmpl isKindOfClass:NSString.class] && tmpl.length > 0) {
            cfg.templateString = tmpl;
        }
        NSNumber *delay = entry[@"delayMs"];
        if ([delay isKindOfClass:NSNumber.class]) {
            uint64_t d = delay.unsignedLongLongValue;
            if (d == 500 || d == 1000 || d == 2000 || d == 3000) {
                cfg.delayMs = d;
            }
        }
    }
    cfg.hasPassword = ([self readPasswordForNormalizedKey:key].length > 0);
    return cfg;
}

- (HorizonAutoLoginConfig *)configForAddress:(NSString *)address {
    NSString *key = [HorizonAutoLoginStore normalizeAddress:address];
    if (key == nil) return [[HorizonAutoLoginConfig alloc] init];
    return [self configForNormalizedKey:key];
}

- (void)saveConfig:(HorizonAutoLoginConfig *)config
       newPassword:(nullable NSString *)newPassword
     clearPassword:(BOOL)clearPassword
        forAddress:(NSString *)address {
    NSString *key = [HorizonAutoLoginStore normalizeAddress:address];
    if (key == nil) return;

    NSString *tmpl = [config.templateString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (tmpl.length == 0) tmpl = kDefaultTemplate;
    uint64_t delay = config.delayMs;
    if (delay != 500 && delay != 1000 && delay != 2000 && delay != 3000) {
        delay = kDefaultDelayMs;
    }

    NSMutableDictionary *map = [self loadMetaMap];
    map[key] = @{
        @"enabled": @(config.enabled),
        @"template": tmpl,
        @"delayMs": @(delay),
    };
    [self saveMetaMap:map];

    if (clearPassword) {
        [self deletePasswordForNormalizedKey:key];
    } else if (newPassword != nil && newPassword.length > 0) {
        [self storePassword:newPassword forNormalizedKey:key];
    }
}

- (void)migrateFromAddress:(NSString *)oldAddress toAddress:(NSString *)newAddress {
    NSString *oldKey = [HorizonAutoLoginStore normalizeAddress:oldAddress];
    NSString *newKey = [HorizonAutoLoginStore normalizeAddress:newAddress];
    if (oldKey == nil || newKey == nil || [oldKey isEqualToString:newKey]) return;

    NSMutableDictionary *map = [self loadMetaMap];
    NSDictionary *oldMeta = map[oldKey];
    if (oldMeta != nil) {
        map[newKey] = oldMeta;
        [map removeObjectForKey:oldKey];
        [self saveMetaMap:map];
    }
    NSString *pw = [self readPasswordForNormalizedKey:oldKey];
    if (pw.length > 0) {
        [self storePassword:pw forNormalizedKey:newKey];
        [self deletePasswordForNormalizedKey:oldKey];
    }
}

- (void)deleteForAddress:(NSString *)address {
    NSString *key = [HorizonAutoLoginStore normalizeAddress:address];
    if (key == nil) return;
    NSMutableDictionary *map = [self loadMetaMap];
    if (map[key] != nil) {
        [map removeObjectForKey:key];
        [self saveMetaMap:map];
    }
    [self deletePasswordForNormalizedKey:key];
}

@end

#pragma mark - C FFI lookup called from Rust `host.rs`

static void horizon_copy_cstr(NSString *src, char *dst, size_t dstLen) {
    if (dst == NULL || dstLen == 0) return;
    if (src.length == 0) {
        dst[0] = '\0';
        return;
    }
    const char *utf8 = src.UTF8String;
    if (utf8 == NULL) {
        dst[0] = '\0';
        return;
    }
    size_t n = strlen(utf8);
    if (n >= dstLen) n = dstLen - 1;
    memcpy(dst, utf8, n);
    dst[n] = '\0';
}

bool horizon_ios_lookup_autologin_parts(
    const char *normalized_addr,
    char *tmpl_buf,
    size_t tmpl_buf_len,
    char *pass_buf,
    size_t pass_buf_len,
    uint64_t *out_delay_ms
) {
    if (normalized_addr == NULL || tmpl_buf == NULL || pass_buf == NULL) {
        return false;
    }
    @autoreleasepool {
        NSString *key = [NSString stringWithUTF8String:normalized_addr];
        if (key.length == 0) return false;

        HorizonAutoLoginStore *store = HorizonAutoLoginStore.shared;
        HorizonAutoLoginConfig *cfg = [store configForNormalizedKey:key];
        if (!cfg.enabled) {
            return false;
        }
        NSString *pw = [store readPasswordForNormalizedKey:key];
        if (pw.length == 0) {
            return false;
        }
        horizon_copy_cstr(cfg.templateString, tmpl_buf, tmpl_buf_len);
        horizon_copy_cstr(pw, pass_buf, pass_buf_len);
        if (out_delay_ms != NULL) {
            *out_delay_ms = cfg.delayMs;
        }
        return true;
    }
}
