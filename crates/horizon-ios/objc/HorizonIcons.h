// horizon-ios: crisp CoreGraphics vector icon renderer for Bedrock touch HUD controls.
#pragma once

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, HorizonIconKind) {
    HorizonIconJump = 0,
    HorizonIconFlyUp,
    HorizonIconFlyDown,
    HorizonIconSwimUp,
    HorizonIconSwimDown,
    HorizonIconSneak,
    HorizonIconDismount,
    HorizonIconElytra,
    HorizonIconSprintLock,

    HorizonIconSword,
    HorizonIconPickaxe,
    HorizonIconCube,
    HorizonIconOpenChest,
    HorizonIconHand,
    HorizonIconApple,
    HorizonIconPotion,
    HorizonIconBow,
    HorizonIconTrident,
    HorizonIconShield,
    HorizonIconTrade,
    HorizonIconFeedHeart,
    HorizonIconRideSaddle,
    HorizonIconFishingRod,
    HorizonIconSpyglass,
    HorizonIconFirework,
    HorizonIconEquipArmor,

    HorizonIconDpadUp,
    HorizonIconDpadDown,
    HorizonIconDpadLeft,
    HorizonIconDpadRight,
    HorizonIconDpadDiagUpLeft,
    HorizonIconDpadDiagUpRight,

    HorizonIconPause,
    HorizonIconChat,
    HorizonIconPerspective,
    HorizonIconSettings,
    HorizonIconInventoryDots,
    HorizonIconClose,
    HorizonIconBack,
    HorizonIconQuickMove,
    HorizonIconDrop,
};

NS_ASSUME_NONNULL_BEGIN

@interface HorizonIcons : NSObject

+ (UIImage *)iconForKind:(HorizonIconKind)kind pointSize:(CGFloat)pointSize;
+ (HorizonIconKind)iconForUseVerb:(uint8_t)useVerb activeUse:(uint8_t)activeUse;
+ (NSString * _Nullable)labelForUseVerb:(uint8_t)useVerb activeUse:(uint8_t)activeUse;

@end

NS_ASSUME_NONNULL_END
