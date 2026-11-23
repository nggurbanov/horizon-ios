// horizon-ios: native UIKit Pre-Launcher app delegate and zero-flash handoff into winit.
#import "HorizonPreLauncherAppDelegate.h"
#import "HorizonOverlayViewController.h"
#import "HorizonPreLauncherViewController.h"
#import "HorizonSettings.h"
#include "horizon_bridge.h"
#include <stdlib.h>

extern int *_NSGetArgc(void);
extern char ***_NSGetArgv(void);

typedef void (*HorizonLaunchCallback)(void);

static HorizonLaunchCallback sLaunchCallback = NULL;
static UIWindow *sPreLauncherWindow = nil;
static BOOL sLaunchTriggered = NO;
static BOOL sWindowDismissed = NO;

static NSString *horizon_documentsDir(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count > 0) return paths.firstObject;
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
}

static BOOL horizon_resourcesManifestExists(void) {
    NSString *manifest = [[horizon_documentsDir() stringByAppendingPathComponent:@"resources"]
                          stringByAppendingPathComponent:@"horizon-resources.json"];
    return [NSFileManager.defaultManager fileExistsAtPath:manifest];
}

@implementation HorizonPreLauncherAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;

    CGRect bounds = UIScreen.mainScreen.bounds;
    UIWindow *win = [[UIWindow alloc] initWithFrame:bounds];
    win.backgroundColor = [UIColor colorWithRed:16.0/255.0 green:21.0/255.0 blue:27.0/255.0 alpha:1.0];
    HorizonPreLauncherViewController *vc = [[HorizonPreLauncherViewController alloc] init];
    win.rootViewController = vc;
    [win makeKeyAndVisible];

    self.window = win;
    sPreLauncherWindow = win;
    sWindowDismissed = NO;
    return YES;
}

- (UIInterfaceOrientationMask)application:(UIApplication *)application
  supportedInterfaceOrientationsForWindow:(nullable UIWindow *)window {
    (void)application;
    (void)window;
    return UIInterfaceOrientationMaskLandscape;
}

+ (void)launchGameWithPlayerName:(nullable NSString *)playerName
                     quickServer:(nullable NSString *)quickServer
                      quickWorld:(nullable NSString *)quickWorld {
    if (sLaunchTriggered || sLaunchCallback == NULL) return;
    sLaunchTriggered = YES;

    // Apply player name and optional 1-tap quick-launch targets before horizon_game parses options.
    if (playerName.length > 0) {
        setenv("HORIZON_PLAYER_NAME", playerName.UTF8String, 1);
    }
    if (quickServer.length > 0) {
        setenv("HORIZON_IOS_QUICK_SERVER", quickServer.UTF8String, 1);
        unsetenv("HORIZON_IOS_QUICK_WORLD");
    } else if (quickWorld.length > 0) {
        setenv("HORIZON_IOS_QUICK_WORLD", quickWorld.UTF8String, 1);
        unsetenv("HORIZON_IOS_QUICK_SERVER");
    } else {
        unsetenv("HORIZON_IOS_QUICK_SERVER");
        unsetenv("HORIZON_IOS_QUICK_WORLD");
    }

    // Keep the pre-launcher window visually above the newly created WinitUIWindow until
    // horizon_ios_attach_overlay triggers a smooth cross-fade (prevents any black flash).
    if (sPreLauncherWindow != nil) {
        sPreLauncherWindow.windowLevel = UIWindowLevelNormal + 1.0;
    }

    HorizonLaunchCallback cb = sLaunchCallback;
    // Allow CoreAnimation one frame to render the "Launching Horizon…" spinner before starting Rust.
    // CRITICAL: NEVER invoke `cb()` inside `dispatch_get_main_queue()`! `cb()` enters winit's
    // `CFRunLoopRun()` loop and never returns; running it from a GCD main-queue block leaves
    // libdispatch's serial main queue permanently draining (and sets CFRunLoop's
    // `__CFTSDKeyIsInGCDMainQ` TSD flag), which permanently blocks every future
    // `dispatch_async(dispatch_get_main_queue(), ...)` — including UIKit's software keyboard
    // (`UIKeyboardTaskQueue` / `RTIInputSystemClient`), GameController handlers, and `dispatch_after`.
    // Scheduling via `NSTimer` on `NSRunLoop.mainRunLoop` executes outside GCD's main-queue drain
    // so nested `CFRunLoopRun()` keeps servicing `_dispatch_main_queue_callback_4CF` normally.
    NSTimer *launchTimer = [NSTimer timerWithTimeInterval:0.04
                                                  repeats:NO
                                                    block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        cb();
    }];
    [NSRunLoop.mainRunLoop addTimer:launchTimer forMode:NSRunLoopCommonModes];
}

@end

static void horizon_activateGameWindow(UIWindow * _Nullable gameWindow, UIWindow * _Nullable preWin) {
    if (gameWindow == nil) return;

    if (@available(iOS 13.0, *)) {
        if (gameWindow.windowScene == nil) {
            UIWindowScene *scene = preWin.windowScene;
            if (scene == nil) {
                for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                    if ([s isKindOfClass:UIWindowScene.class]) {
                        UIWindowScene *ws = (UIWindowScene *)s;
                        if (ws.activationState == UISceneActivationStateForegroundActive ||
                            scene == nil) {
                            scene = ws;
                        }
                    }
                }
            }
            if (scene != nil) {
                gameWindow.windowScene = scene;
            }
        }
    }

    id<UIApplicationDelegate> del = UIApplication.sharedApplication.delegate;
    if ([del isKindOfClass:HorizonPreLauncherAppDelegate.class]) {
        ((HorizonPreLauncherAppDelegate *)del).window = gameWindow;
    }
    [gameWindow makeKeyAndVisible];
}

#pragma mark - C entry points

void horizon_ios_run_prelauncher_or_launch(void (*launch_cb)(void)) {
    if (launch_cb == NULL) return;
    @autoreleasepool {
        BOOL skip = HorizonSettings.shared.skipLauncher;
        BOOL hasResources = horizon_resourcesManifestExists();
        if (skip && hasResources) {
            NSLog(@"horizon-ios: skipLauncher enabled & resources present; launching game directly");
            launch_cb();
            return;
        }
        sLaunchCallback = launch_cb;
        sLaunchTriggered = NO;
        sWindowDismissed = NO;
        NSLog(@"horizon-ios: starting native UIKit pre-launcher (skip=%d, resources=%d)",
              skip ? 1 : 0, hasResources ? 1 : 0);
        int argc = *_NSGetArgc();
        char **argv = *_NSGetArgv();
        UIApplicationMain(argc, argv, nil, NSStringFromClass(HorizonPreLauncherAppDelegate.class));
    }
}

void horizon_ios_dismiss_prelauncher_window(void *game_window_ptr) {
    UIWindow *gameWindow = (__bridge UIWindow *)game_window_ptr;
    dispatch_block_t dismissBlock = ^{
        UIWindow *win = sPreLauncherWindow;
        // Hand windowScene, delegate.window, and key-window ownership to the game window
        // immediately so UIKit text fields and the software keyboard work from frame 1.
        horizon_activateGameWindow(gameWindow, win);

        if (sWindowDismissed || win == nil) {
            [HorizonOverlayViewController.current reassertFirstResponderIfNeeded];
            return;
        }
        sWindowDismissed = YES;
        win.userInteractionEnabled = NO;
        [HorizonOverlayViewController.current reassertFirstResponderIfNeeded];
        [UIView animateWithDuration:0.24
                              delay:0.06
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            win.alpha = 0.0;
        } completion:^(BOOL finished) {
            (void)finished;
            win.hidden = YES;
            win.rootViewController = nil;
            if (sPreLauncherWindow == win) {
                sPreLauncherWindow = nil;
            }
            horizon_activateGameWindow(gameWindow, nil);
            [HorizonOverlayViewController.current reassertFirstResponderIfNeeded];
        }];
    };
    if (NSThread.isMainThread) {
        dismissBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), dismissBlock);
    }
}
