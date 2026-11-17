// horizon-ios: adapted from Amethyst-iOS (https://github.com/AngelAuraMC/Amethyst-iOS), Natives/customcontrols/CustomControlsUtils.h.
// Amethyst-iOS is free software under the GNU General Public License v3.0; this file is distributed
// under the same licence. Changes for horizon-ios are marked "horizon-ios:".

#import <UIKit/UIKit.h>
#import "ControlButton.h"

#define BTN_RECT 80.0, 30.0
#define BTN_SQUARE 50.0, 50.0

NSMutableDictionary* createButton(NSString* name, int* keycodes, NSString* dynamicX, NSString* dynamicY, CGFloat width, CGFloat height);
NSMutableDictionary* createGamepadButton(NSString* name, int gamepad_button, int keycode);
UIColor* convertARGB2UIColor(int argb);
int convertUIColor2ARGB(UIColor* color);
int convertUIColor2RGB(UIColor* color);
BOOL convertLayoutIfNecessary(NSMutableDictionary* dict);
void generateAndSaveDefaultControl();
void generateAndSaveDefaultControlForGamepad();
void loadControlObject(UIView* targetView, NSMutableDictionary* controlDictionary);

void initKeycodeTable(NSMutableArray* keyCodeMap, NSMutableArray* keyValueMap);
