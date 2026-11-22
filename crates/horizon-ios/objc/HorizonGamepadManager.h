// horizon-ios: native Apple GCController + CoreHaptics controller manager.
#pragma once

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#include "horizon_bridge.h"

NS_ASSUME_NONNULL_BEGIN

@protocol HorizonGamepadManagerDelegate <NSObject>
- (void)gamepadManagerDidDetectActivity:(GCController *)controller;
@end

@interface HorizonGamepadManager : NSObject

@property (nonatomic, weak, nullable) id<HorizonGamepadManagerDelegate> delegate;
@property (nonatomic, readonly) BOOL hasConnectedController;

- (void)start;
- (void)stop;
- (void)tick;
- (void)playRumble:(HorizonRumbleEvent)rumble;

@end

NS_ASSUME_NONNULL_END
