// horizon-ios: adapted from Amethyst-iOS (https://github.com/AngelAuraMC/Amethyst-iOS), Natives/utils.m,
// Natives/UIKit+hook.m (currentVC) and Natives/environ.h (globals). Amethyst-iOS is free software under the
// GNU General Public License v3.0; this file is distributed under the same licence.
//
// Only the helpers the touch controls use; currentVC() returns the overlay controller.

#import "utils.h"
#import "HorizonSurfaceViewController.h"

#include <math.h>

float resolutionScale = 1.0f;
BOOL virtualMouseEnabled = NO, isControlModifiable = NO;
int windowWidth = 0, windowHeight = 0;
int physicalWidth = 0, physicalHeight = 0;

UIViewController* currentVC(void) {
    return HorizonSurfaceViewController.current;
}

UIWindow* horizon_keyWindow(void) {
    UIWindow *window = HorizonSurfaceViewController.current.viewIfLoaded.window;
    if (window != nil) {
        return window;
    }
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) {
                return candidate;
            }
            if (fallback == nil) {
                fallback = candidate;
            }
        }
    }
    return fallback;
}

NSString* localize(NSString* key, NSString* comment) {
    // NSLocalizedString returns the key itself when the app has no translation for it.
    NSString *value = NSLocalizedString(key, nil);
    return value.length > 0 ? value : key;
}

NSMutableDictionary* parseJSONFromFile(NSString *path) {
    NSError *error;

    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (content == nil) {
        NSLog(@"[ParseJSON] Error: could not read %@: %@", path, error.localizedDescription);
        return @{@"NSErrorObject": error}.mutableCopy;
    }

    NSData* data = [content dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
    if (error || ![dict isKindOfClass:NSMutableDictionary.class]) {
        // horizon-ios: also reject a top-level value that is not an object.
        if (error == nil) {
            error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSPropertyListReadCorruptError
                userInfo:@{NSLocalizedDescriptionKey: @"The layout is not a JSON object."}];
        }
        NSLog(@"[ParseJSON] Error: could not parse JSON: %@", error.localizedDescription);
        return @{@"NSErrorObject": error}.mutableCopy;
    }
    return dict;
}

CGFloat MathUtils_dist(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2) {
    const CGFloat x = (x2 - x1);
    const CGFloat y = (y2 - y1);
    return (CGFloat) hypot(x, y);
}

//Ported from https://www.arduino.cc/reference/en/language/functions/math/map/
CGFloat MathUtils_map(CGFloat x, CGFloat in_min, CGFloat in_max, CGFloat out_min, CGFloat out_max) {
    return (x - in_min) * (out_max - out_min) / (in_max - in_min) + out_min;
}

CGFloat dpToPx(CGFloat dp) {
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    return dp * screenScale;
}

CGFloat pxToDp(CGFloat px) {
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    return px / screenScale;
}
