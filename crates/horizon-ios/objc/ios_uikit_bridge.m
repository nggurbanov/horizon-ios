// horizon-ios: adapted from Amethyst-iOS (https://github.com/AngelAuraMC/Amethyst-iOS),
// Natives/ios_uikit_bridge.m (showDialog). Amethyst-iOS is free software under the GNU General Public
// License v3.0; this file is distributed under the same licence.
//
// Changes for horizon-ios: presented from the overlay controller (or the top of its window) instead of
// a separate alert window.

#import "ios_uikit_bridge.h"
#import "utils.h"

static void internal_showDialog(NSString* title, NSString* message) {
    NSLog(@"[UI] Dialog shown: %@: %@", title, message);

    UIAlertController* alert = [UIAlertController alertControllerWithTitle:title
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];

    UIViewController *presenter = currentVC();
    if (presenter == nil || presenter.viewIfLoaded.window == nil) {
        presenter = horizon_keyWindow().rootViewController;
    }
    // Present over whatever is already shown.
    while (presenter.presentedViewController != nil && !presenter.presentedViewController.isBeingDismissed) {
        presenter = presenter.presentedViewController;
    }
    if (presenter == nil) {
        return;
    }
    [presenter presentViewController:alert animated:YES completion:nil];
}

void showDialog(NSString* title, NSString* message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        internal_showDialog(title, message);
    });
}
