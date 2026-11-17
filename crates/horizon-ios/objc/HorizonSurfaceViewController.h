// horizon-ios: adapted from Amethyst-iOS (https://github.com/AngelAuraMC/Amethyst-iOS),
// Natives/SurfaceViewController.h. Amethyst-iOS is free software under the GNU General Public License v3.0;
// this file is distributed under the same licence.
//
// The touch-controls overlay put over winit's Metal view by horizon_ios_attach_overlay (horizon_bridge.h).
// Unlike Amethyst's SurfaceViewController it owns no game surface: it is a transparent child controller
// whose view covers the game view and takes every touch.
#pragma once

#import <UIKit/UIKit.h>

#import "customcontrols/ControlLayout.h"

@interface HorizonSurfaceViewController : UIViewController

// The overlay currently attached (there is at most one), or nil before the first attach.
@property(class, nonatomic, readonly) HorizonSurfaceViewController *current;

// winit's view the overlay covers. Its contentScaleFactor converts points to the game's pixels.
@property(nonatomic, weak, readonly) UIView *gameView;

@property(nonatomic) ControlLayout *ctrlView;
@property(nonatomic) UIView *touchView;
@property(nonatomic) UIImageView *mousePointerView;
@property(nonatomic) UIPanGestureRecognizer *scrollPanGesture;

// Puts the overlay over `gameView` (moving it from a previous game view if needed) and makes it the
// first responder.
- (void)attachToGameView:(UIView *)gameView;

- (void)sendTouchPoint:(CGPoint)location withEvent:(int)event;
- (void)updateSavedResolution;
- (void)updateGrabState;
// Re-reads the control.* prefs.
- (void)updatePreferenceChanges;
// Reloads the layout named by the control.default_ctrl pref from $AME_HOME/controlmap/.
- (void)loadCustomControls;

@end
