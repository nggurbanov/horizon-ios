// horizon-ios: adapted from Amethyst-iOS (https://github.com/AngelAuraMC/Amethyst-iOS), Natives/input/GyroInput.h.
// Amethyst-iOS is free software under the GNU General Public License v3.0; this file is distributed
// under the same licence. Changes for horizon-ios are marked "horizon-ios:".

#import <Foundation/Foundation.h>

@interface GyroInput : NSObject

+ (void)updateOrientation;
+ (void)updateSensitivity:(int)sensitivity invertXAxis:(BOOL)invertX;
+ (void)tick;

@end
