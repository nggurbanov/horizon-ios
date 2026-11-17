// horizon-ios: adapted from Amethyst-iOS (https://github.com/AngelAuraMC/Amethyst-iOS), Natives/utils.h
// and Natives/environ.h. Amethyst-iOS is free software under the GNU General Public License v3.0; this
// file is distributed under the same licence.
//
// A shim: only what the ported touch controls use. The JVM, JNI, JIT, dyld and launcher parts are gone.
// The input callbacks come from horizon_bridge.h (implemented in Rust); the globals that Amethyst
// declared as tentative definitions in headers are extern here and defined once in utils.m.
#pragma once

#import <UIKit/UIKit.h>

#include <stdbool.h>
#include "horizon_bridge.h"

// Control button actions
#define ACTION_DOWN 0
#define ACTION_UP 1
#define ACTION_MOVE 2
#define ACTION_MOVE_MOTION 3

#define SPECIALBTN_KEYBOARD -1
#define SPECIALBTN_TOGGLECTRL -2
#define SPECIALBTN_MOUSEPRI -3
#define SPECIALBTN_MOUSESEC -4
#define SPECIALBTN_VIRTUALMOUSE -5
#define SPECIALBTN_MOUSEMID -6
#define SPECIALBTN_SCROLLUP -7
#define SPECIALBTN_SCROLLDOWN -8
#define SPECIALBTN_MENU -9

// Amethyst compared its JNI `isGrabbing` against JNI_TRUE; Horizon answers through the bridge.
#define JNI_TRUE 1
#define JNI_FALSE 0
#define isGrabbing (horizon_ios_is_grabbing())

// From environ.h (defined in utils.m)
extern float resolutionScale; // always 1 in horizon-ios
extern BOOL virtualMouseEnabled, isControlModifiable;
extern int windowWidth, windowHeight;
extern int physicalWidth, physicalHeight;

// The overlay's controller (HorizonSurfaceViewController), or nil before the first attach.
UIViewController* currentVC(void);
// The window the overlay sits in, falling back to the key window of a foreground scene.
UIWindow* horizon_keyWindow(void);

NSString* localize(NSString* key, NSString* comment);
NSMutableDictionary* parseJSONFromFile(NSString *path);

static inline CGFloat clamp(CGFloat x, CGFloat lower, CGFloat upper) {
    return fmin(upper, fmax(x, lower));
}
CGFloat MathUtils_dist(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2);
CGFloat MathUtils_map(CGFloat x, CGFloat in_min, CGFloat in_max, CGFloat out_min, CGFloat out_max);
CGFloat dpToPx(CGFloat dp);
CGFloat pxToDp(CGFloat px);
