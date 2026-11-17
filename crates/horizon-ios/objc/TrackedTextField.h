// horizon-ios: adapted from Amethyst-iOS (https://github.com/AngelAuraMC/Amethyst-iOS), Natives/TrackedTextField.h.
// Amethyst-iOS is free software under the GNU General Public License v3.0; this file is distributed
// under the same licence. Changes for horizon-ios are marked "horizon-ios:".

#import <UIKit/UIKit.h>

#include <stdint.h>

@interface TrackedTextField : UITextField

// horizon-ios: codepoints are uint32_t (full Unicode) instead of JNI's jchar.
@property(nonatomic, copy) void(^sendChar)(uint32_t codepoint);
@property(nonatomic, copy) void(^sendCharMods)(uint32_t codepoint, int mods);
@property(nonatomic, copy) void(^sendKey)(int key, int scancode, int action, int mods);

@end
