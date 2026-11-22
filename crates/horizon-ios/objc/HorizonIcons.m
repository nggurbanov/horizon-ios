// horizon-ios: crisp CoreGraphics vector icon renderer for Bedrock touch HUD controls.
// Every icon is drawn directly on a normalized 24x24 vector grid with rounded strokes and
// crisp silhouettes (zero Unicode/emoji glyph reliance).
#import "HorizonIcons.h"
#include "horizon_bridge.h"
#include <math.h>

@implementation HorizonIcons

+ (NSCache<NSString *, UIImage *> *)cache {
    static NSCache<NSString *, UIImage *> *sCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sCache = [[NSCache alloc] init];
        sCache.countLimit = 128;
    });
    return sCache;
}

+ (HorizonIconKind)iconForUseVerb:(uint8_t)useVerb activeUse:(uint8_t)activeUse {
    if (activeUse == HORIZON_ACTIVE_SHOOT) {
        return HorizonIconBow;
    }
    if (activeUse == HORIZON_ACTIVE_THROW) {
        return HorizonIconTrident;
    }
    switch (useVerb) {
        case HORIZON_VERB_PLACE: return HorizonIconCube;
        case HORIZON_VERB_OPEN:  return HorizonIconOpenChest;
        case HORIZON_VERB_EAT:   return HorizonIconApple;
        case HORIZON_VERB_DRINK: return HorizonIconPotion;
        case HORIZON_VERB_SHOOT:
        case HORIZON_VERB_LOAD:  return HorizonIconBow;
        case HORIZON_VERB_THROW: return HorizonIconTrident;
        case HORIZON_VERB_RAISE: return HorizonIconShield;
        case HORIZON_VERB_TRADE: return HorizonIconTrade;
        case HORIZON_VERB_FEED:  return HorizonIconFeedHeart;
        case HORIZON_VERB_RIDE:  return HorizonIconRideSaddle;
        case HORIZON_VERB_FISH:  return HorizonIconFishingRod;
        case HORIZON_VERB_ZOOM:  return HorizonIconSpyglass;
        case HORIZON_VERB_BOOST: return HorizonIconFirework;
        case HORIZON_VERB_EQUIP: return HorizonIconEquipArmor;
        case HORIZON_VERB_USE:
        default:                 return HorizonIconHand;
    }
}

+ (NSString * _Nullable)labelForUseVerb:(uint8_t)useVerb activeUse:(uint8_t)activeUse {
    if (activeUse == HORIZON_ACTIVE_SHOOT) return @"Release";
    if (activeUse == HORIZON_ACTIVE_THROW) return @"Throw";
    if (activeUse == HORIZON_ACTIVE_STOP)  return @"Stop";
    switch (useVerb) {
        case HORIZON_VERB_OPEN:  return @"Open";
        case HORIZON_VERB_TRADE: return @"Trade";
        case HORIZON_VERB_FEED:  return @"Feed";
        case HORIZON_VERB_RIDE:  return @"Ride";
        case HORIZON_VERB_EAT:   return @"Eat";
        case HORIZON_VERB_DRINK: return @"Drink";
        case HORIZON_VERB_FISH:  return @"Fish";
        case HORIZON_VERB_SHOOT: return @"Shoot";
        case HORIZON_VERB_LOAD:  return @"Load";
        case HORIZON_VERB_RAISE: return @"Shield";
        case HORIZON_VERB_BOOST: return @"Boost";
        case HORIZON_VERB_ZOOM:  return @"Zoom";
        case HORIZON_VERB_EQUIP: return @"Equip";
        case HORIZON_VERB_USE:   return @"Use";
        default:                 return nil;
    }
}

+ (UIImage *)iconForKind:(HorizonIconKind)kind pointSize:(CGFloat)pointSize {
    int rounded = (int)llround(pointSize * 2.0);
    NSString *key = [NSString stringWithFormat:@"%ld_%d", (long)kind, rounded];
    UIImage *cached = [[self cache] objectForKey:key];
    if (cached != nil) {
        return cached;
    }

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(pointSize, pointSize) format:fmt];

    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGFloat s = pointSize / 24.0;
        CGContextScaleCTM(c, s, s);
        CGContextSetLineCap(c, kCGLineCapRound);
        CGContextSetLineJoin(c, kCGLineJoinRound);
        [UIColor.whiteColor setFill];
        [UIColor.whiteColor setStroke];

        [self drawIcon:kind inContext:c];
    }];

    image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [[self cache] setObject:image forKey:key];
    return image;
}

+ (void)drawChevronIn:(CGContextRef)c centerY:(CGFloat)cy up:(BOOL)up halfW:(CGFloat)hw height:(CGFloat)h lineW:(CGFloat)lw {
    CGFloat dy = up ? h : -h;
    CGContextSetLineWidth(c, lw);
    CGContextBeginPath(c);
    CGContextMoveToPoint(c, 12.0 - hw, cy + dy * 0.5);
    CGContextAddLineToPoint(c, 12.0, cy - dy * 0.5);
    CGContextAddLineToPoint(c, 12.0 + hw, cy + dy * 0.5);
    CGContextStrokePath(c);
}

+ (void)drawArrowIn:(CGContextRef)c angleRad:(CGFloat)angle {
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 12.0, 12.0);
    CGContextRotateCTM(c, angle);
    // Filled triangle pointing UP (0 rad = up)
    CGContextBeginPath(c);
    CGContextMoveToPoint(c, 0.0, -7.2);
    CGContextAddLineToPoint(c, 7.2, 4.8);
    CGContextAddLineToPoint(c, -7.2, 4.8);
    CGContextClosePath(c);
    CGContextFillPath(c);
    CGContextRestoreGState(c);
}

+ (void)drawIcon:(HorizonIconKind)kind inContext:(CGContextRef)c {
    switch (kind) {
        case HorizonIconJump: {
            // Bold Bedrock upward arrow with foot bar
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 12.0, 3.5);
            CGContextAddLineToPoint(c, 19.5, 11.8);
            CGContextAddLineToPoint(c, 14.8, 11.8);
            CGContextAddLineToPoint(c, 14.8, 19.8);
            CGContextAddLineToPoint(c, 9.2, 19.8);
            CGContextAddLineToPoint(c, 9.2, 11.8);
            CGContextAddLineToPoint(c, 4.5, 11.8);
            CGContextClosePath(c);
            CGContextFillPath(c);
            break;
        }
        case HorizonIconFlyUp: {
            // Double upward chevrons (Bedrock ascend)
            [self drawChevronIn:c centerY:8.5 up:YES halfW:6.8 height:5.5 lineW:2.8];
            [self drawChevronIn:c centerY:15.5 up:YES halfW:6.8 height:5.5 lineW:2.8];
            break;
        }
        case HorizonIconFlyDown: {
            // Double downward chevrons (Bedrock descend)
            [self drawChevronIn:c centerY:8.5 up:NO halfW:6.8 height:5.5 lineW:2.8];
            [self drawChevronIn:c centerY:15.5 up:NO halfW:6.8 height:5.5 lineW:2.8];
            break;
        }
        case HorizonIconSwimUp: {
            [self drawChevronIn:c centerY:8.2 up:YES halfW:6.2 height:5.2 lineW:2.6];
            // Wave bar underneath
            CGContextSetLineWidth(c, 2.2);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 4.0, 17.2);
            CGContextAddQuadCurveToPoint(c, 8.0, 14.2, 12.0, 17.2);
            CGContextAddQuadCurveToPoint(c, 16.0, 20.2, 20.0, 17.2);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconSwimDown: {
            // Wave bar on top
            CGContextSetLineWidth(c, 2.2);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 4.0, 6.8);
            CGContextAddQuadCurveToPoint(c, 8.0, 3.8, 12.0, 6.8);
            CGContextAddQuadCurveToPoint(c, 16.0, 9.8, 20.0, 6.8);
            CGContextStrokePath(c);
            [self drawChevronIn:c centerY:15.8 up:NO halfW:6.2 height:5.2 lineW:2.6];
            break;
        }
        case HorizonIconSneak: {
            // Bedrock crouching figure silhouette (head + angled torso + bent legs)
            CGContextFillEllipseInRect(c, CGRectMake(12.2, 3.8, 4.6, 4.6));
            CGContextSetLineWidth(c, 2.7);
            CGContextBeginPath(c);
            // Leaning torso
            CGContextMoveToPoint(c, 13.5, 9.5);
            CGContextAddLineToPoint(c, 9.5, 14.0);
            // Bent front leg
            CGContextAddLineToPoint(c, 14.2, 15.8);
            CGContextAddLineToPoint(c, 13.0, 20.4);
            // Rear leg
            CGContextMoveToPoint(c, 9.5, 14.0);
            CGContextAddLineToPoint(c, 6.8, 20.2);
            // Forward arm
            CGContextMoveToPoint(c, 12.6, 10.6);
            CGContextAddLineToPoint(c, 17.4, 13.0);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconDismount: {
            // Saddle/seat base + exit arrow jumping out
            CGContextSetLineWidth(c, 2.4);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 4.5, 17.5);
            CGContextAddLineToPoint(c, 4.5, 20.0);
            CGContextAddLineToPoint(c, 19.5, 20.0);
            CGContextAddLineToPoint(c, 19.5, 17.5);
            CGContextStrokePath(c);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 12.0, 15.8);
            CGContextAddLineToPoint(c, 12.0, 5.0);
            CGContextMoveToPoint(c, 7.2, 9.6);
            CGContextAddLineToPoint(c, 12.0, 4.6);
            CGContextAddLineToPoint(c, 16.8, 9.6);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconElytra: {
            // Spread Elytra wings silhouette
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 12.0, 6.5);
            CGContextAddCurveToPoint(c, 8.5, 4.5, 3.0, 6.5, 2.5, 13.5);
            CGContextAddCurveToPoint(c, 4.8, 18.8, 9.2, 19.0, 11.2, 14.5);
            CGContextAddLineToPoint(c, 12.0, 11.2);
            CGContextAddLineToPoint(c, 12.8, 14.5);
            CGContextAddCurveToPoint(c, 14.8, 19.0, 19.2, 18.8, 21.5, 13.5);
            CGContextAddCurveToPoint(c, 21.0, 6.5, 15.5, 4.5, 12.0, 6.5);
            CGContextClosePath(c);
            CGContextFillPath(c);
            break;
        }
        case HorizonIconSprintLock: {
            // Padlock with speed chevron
            CGContextSetLineWidth(c, 2.2);
            CGContextBeginPath(c);
            CGContextAddArc(c, 12.0, 9.2, 3.6, (CGFloat)M_PI, 0.0, 0);
            CGContextStrokePath(c);
            UIBezierPath *body = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(6.2, 10.2, 11.6, 9.2) cornerRadius:2.2];
            [body fill];
            break;
        }
        case HorizonIconSword: {
            // Crisp diagonal Minecraft sword
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 20.2, 3.8);
            CGContextAddLineToPoint(c, 16.0, 4.5);
            CGContextAddLineToPoint(c, 8.2, 12.3);
            CGContextAddLineToPoint(c, 11.7, 15.8);
            CGContextAddLineToPoint(c, 19.5, 8.0);
            CGContextClosePath(c);
            CGContextFillPath(c);
            // Crossguard & hilt
            CGContextSetLineWidth(c, 2.5);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 6.2, 10.6);
            CGContextAddLineToPoint(c, 13.4, 17.8);
            CGContextMoveToPoint(c, 9.2, 14.8);
            CGContextAddLineToPoint(c, 4.5, 19.5);
            CGContextStrokePath(c);
            CGContextFillEllipseInRect(c, CGRectMake(3.0, 18.0, 3.2, 3.2));
            break;
        }
        case HorizonIconPickaxe: {
            // Classic Minecraft pickaxe head + diagonal handle
            CGContextSetLineWidth(c, 2.6);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 4.8, 19.2);
            CGContextAddLineToPoint(c, 15.8, 8.2);
            CGContextStrokePath(c);
            CGContextSetLineWidth(c, 3.2);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 7.2, 5.2);
            CGContextAddQuadCurveToPoint(c, 15.2, 4.5, 19.2, 12.5);
            CGContextAddQuadCurveToPoint(c, 18.6, 15.0, 17.8, 16.8);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconCube: {
            // Isometric 3D Minecraft block
            CGContextSetLineWidth(c, 2.0);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 12.0, 3.2);
            CGContextAddLineToPoint(c, 20.0, 7.6);
            CGContextAddLineToPoint(c, 20.0, 16.4);
            CGContextAddLineToPoint(c, 12.0, 20.8);
            CGContextAddLineToPoint(c, 4.0, 16.4);
            CGContextAddLineToPoint(c, 4.0, 7.6);
            CGContextClosePath(c);
            CGContextStrokePath(c);
            // Inner edges
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 4.0, 7.6);
            CGContextAddLineToPoint(c, 12.0, 12.0);
            CGContextAddLineToPoint(c, 20.0, 7.6);
            CGContextMoveToPoint(c, 12.0, 12.0);
            CGContextAddLineToPoint(c, 12.0, 20.8);
            CGContextStrokePath(c);
            // Subtle top face fill
            CGContextSaveGState(c);
            [[UIColor colorWithWhite:1.0 alpha:0.35] setFill];
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 12.0, 3.2);
            CGContextAddLineToPoint(c, 20.0, 7.6);
            CGContextAddLineToPoint(c, 12.0, 12.0);
            CGContextAddLineToPoint(c, 4.0, 7.6);
            CGContextClosePath(c);
            CGContextFillPath(c);
            CGContextRestoreGState(c);
            break;
        }
        case HorizonIconOpenChest: {
            // Chest box with latch
            CGContextSetLineWidth(c, 2.1);
            UIBezierPath *box = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(3.8, 5.5, 16.4, 13.0) cornerRadius:2.2];
            box.lineWidth = 2.1;
            [box stroke];
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 3.8, 10.6);
            CGContextAddLineToPoint(c, 20.2, 10.6);
            CGContextStrokePath(c);
            UIBezierPath *latch = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(10.3, 9.0, 3.4, 4.2) cornerRadius:0.8];
            [latch fill];
            break;
        }
        case HorizonIconHand: {
            // Crisp interact pointer hand
            UIBezierPath *palm = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(6.8, 11.2, 10.4, 8.6) cornerRadius:3.5];
            [palm fill];
            CGContextSetLineWidth(c, 2.4);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 10.2, 12.0);
            CGContextAddLineToPoint(c, 10.2, 4.6);
            CGContextMoveToPoint(c, 13.0, 12.0);
            CGContextAddLineToPoint(c, 13.0, 7.5);
            CGContextMoveToPoint(c, 15.8, 12.4);
            CGContextAddLineToPoint(c, 15.8, 9.0);
            CGContextMoveToPoint(c, 7.4, 14.8);
            CGContextAddLineToPoint(c, 5.2, 12.2);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconApple: {
            // Food apple silhouette
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 12.0, 8.2);
            CGContextAddCurveToPoint(c, 8.0, 6.2, 4.8, 9.5, 5.5, 14.2);
            CGContextAddCurveToPoint(c, 6.2, 19.2, 10.0, 20.5, 12.0, 18.8);
            CGContextAddCurveToPoint(c, 14.0, 20.5, 17.8, 19.2, 18.5, 14.2);
            CGContextAddCurveToPoint(c, 19.2, 9.5, 16.0, 6.2, 12.0, 8.2);
            CGContextClosePath(c);
            CGContextFillPath(c);
            CGContextSetLineWidth(c, 2.0);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 12.0, 7.8);
            CGContextAddQuadCurveToPoint(c, 13.2, 4.6, 15.2, 4.0);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconPotion: {
            // Bottle silhouette
            CGContextSetLineWidth(c, 2.0);
            CGContextFillRect(c, CGRectMake(9.6, 3.8, 4.8, 2.6));
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 10.2, 6.4);
            CGContextAddLineToPoint(c, 10.2, 9.2);
            CGContextAddLineToPoint(c, 5.8, 15.0);
            CGContextAddCurveToPoint(c, 5.2, 18.8, 8.0, 20.2, 12.0, 20.2);
            CGContextAddCurveToPoint(c, 16.0, 20.2, 18.8, 18.8, 18.2, 15.0);
            CGContextAddLineToPoint(c, 13.8, 9.2);
            CGContextAddLineToPoint(c, 13.8, 6.4);
            CGContextClosePath(c);
            CGContextFillPath(c);
            break;
        }
        case HorizonIconBow: {
            // Curved bow + string + nocked arrow
            CGContextSetLineWidth(c, 2.5);
            CGContextBeginPath(c);
            CGContextAddArc(c, 10.0, 14.0, 9.2, (CGFloat)(-M_PI_2 * 0.95), (CGFloat)(M_PI_2 * 0.15), 0);
            CGContextStrokePath(c);
            CGContextSetLineWidth(c, 1.5);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 9.6, 4.8);
            CGContextAddLineToPoint(c, 19.0, 15.8);
            CGContextStrokePath(c);
            // Arrow
            CGContextSetLineWidth(c, 2.0);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 6.0, 18.0);
            CGContextAddLineToPoint(c, 19.5, 4.5);
            CGContextMoveToPoint(c, 15.2, 4.5);
            CGContextAddLineToPoint(c, 19.5, 4.5);
            CGContextAddLineToPoint(c, 19.5, 8.8);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconTrident: {
            CGContextSetLineWidth(c, 2.2);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 5.0, 19.0);
            CGContextAddLineToPoint(c, 19.0, 5.0);
            CGContextMoveToPoint(c, 12.5, 5.5);
            CGContextAddLineToPoint(c, 15.5, 8.5);
            CGContextAddLineToPoint(c, 18.5, 11.5);
            CGContextMoveToPoint(c, 12.5, 5.5);
            CGContextAddLineToPoint(c, 15.5, 2.8);
            CGContextMoveToPoint(c, 18.5, 11.5);
            CGContextAddLineToPoint(c, 21.2, 8.5);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconShield: {
            CGContextSetLineWidth(c, 2.2);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 12.0, 3.5);
            CGContextAddLineToPoint(c, 19.0, 6.2);
            CGContextAddLineToPoint(c, 19.0, 12.6);
            CGContextAddCurveToPoint(c, 19.0, 16.8, 15.6, 19.6, 12.0, 21.0);
            CGContextAddCurveToPoint(c, 8.4, 19.6, 5.0, 16.8, 5.0, 12.6);
            CGContextAddLineToPoint(c, 5.0, 6.2);
            CGContextClosePath(c);
            CGContextStrokePath(c);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 12.0, 3.8);
            CGContextAddLineToPoint(c, 12.0, 20.6);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconTrade: {
            // Emerald diamond
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 12.0, 3.2);
            CGContextAddLineToPoint(c, 18.2, 9.0);
            CGContextAddLineToPoint(c, 18.2, 15.0);
            CGContextAddLineToPoint(c, 12.0, 20.8);
            CGContextAddLineToPoint(c, 5.8, 15.0);
            CGContextAddLineToPoint(c, 5.8, 9.0);
            CGContextClosePath(c);
            CGContextFillPath(c);
            break;
        }
        case HorizonIconFeedHeart: {
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 12.0, 20.0);
            CGContextAddCurveToPoint(c, 4.5, 15.0, 3.8, 8.5, 7.6, 5.8);
            CGContextAddCurveToPoint(c, 9.8, 4.2, 11.6, 6.2, 12.0, 7.8);
            CGContextAddCurveToPoint(c, 12.4, 6.2, 14.2, 4.2, 16.4, 5.8);
            CGContextAddCurveToPoint(c, 20.2, 8.5, 19.5, 15.0, 12.0, 20.0);
            CGContextClosePath(c);
            CGContextFillPath(c);
            break;
        }
        case HorizonIconRideSaddle: {
            // Curved saddle arc + stirrup
            CGContextSetLineWidth(c, 2.8);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 4.2, 11.5);
            CGContextAddQuadCurveToPoint(c, 12.0, 17.5, 19.8, 11.5);
            CGContextStrokePath(c);
            CGContextSetLineWidth(c, 2.0);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 12.0, 14.5);
            CGContextAddLineToPoint(c, 12.0, 19.8);
            CGContextMoveToPoint(c, 9.2, 19.8);
            CGContextAddLineToPoint(c, 14.8, 19.8);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconFishingRod: {
            CGContextSetLineWidth(c, 2.2);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 4.5, 19.5);
            CGContextAddQuadCurveToPoint(c, 10.5, 8.5, 17.8, 5.2);
            CGContextStrokePath(c);
            CGContextSetLineWidth(c, 1.6);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 17.8, 5.2);
            CGContextAddLineToPoint(c, 17.8, 15.8);
            CGContextAddArc(c, 16.0, 15.8, 1.8, 0, (CGFloat)M_PI, 0);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconSpyglass: {
            CGContextSetLineWidth(c, 3.0);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 5.0, 19.0);
            CGContextAddLineToPoint(c, 18.6, 5.4);
            CGContextStrokePath(c);
            CGContextSetLineWidth(c, 1.8);
            CGContextStrokeEllipseInRect(c, CGRectMake(14.5, 3.0, 6.2, 6.2));
            break;
        }
        case HorizonIconFirework: {
            CGContextSetLineWidth(c, 2.6);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 6.0, 18.0);
            CGContextAddLineToPoint(c, 15.5, 8.5);
            CGContextStrokePath(c);
            // Spark rays
            CGContextSetLineWidth(c, 1.8);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 17.5, 3.2); CGContextAddLineToPoint(c, 17.5, 6.4);
            CGContextMoveToPoint(c, 20.8, 6.5); CGContextAddLineToPoint(c, 17.8, 6.5);
            CGContextMoveToPoint(c, 19.8, 4.0); CGContextAddLineToPoint(c, 17.6, 6.2);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconEquipArmor: {
            // Chestplate silhouette
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 8.0, 4.5);
            CGContextAddLineToPoint(c, 4.0, 7.5);
            CGContextAddLineToPoint(c, 5.8, 11.8);
            CGContextAddLineToPoint(c, 7.6, 10.6);
            CGContextAddLineToPoint(c, 7.6, 19.6);
            CGContextAddLineToPoint(c, 16.4, 19.6);
            CGContextAddLineToPoint(c, 16.4, 10.6);
            CGContextAddLineToPoint(c, 18.2, 11.8);
            CGContextAddLineToPoint(c, 20.0, 7.5);
            CGContextAddLineToPoint(c, 16.0, 4.5);
            CGContextAddQuadCurveToPoint(c, 12.0, 8.2, 8.0, 4.5);
            CGContextClosePath(c);
            CGContextFillPath(c);
            break;
        }
        case HorizonIconDpadUp:          [self drawArrowIn:c angleRad:0.0]; break;
        case HorizonIconDpadRight:       [self drawArrowIn:c angleRad:(CGFloat)M_PI_2]; break;
        case HorizonIconDpadDown:        [self drawArrowIn:c angleRad:(CGFloat)M_PI]; break;
        case HorizonIconDpadLeft:        [self drawArrowIn:c angleRad:(CGFloat)(-M_PI_2)]; break;
        case HorizonIconDpadDiagUpLeft:  [self drawArrowIn:c angleRad:(CGFloat)(-M_PI_4)]; break;
        case HorizonIconDpadDiagUpRight: [self drawArrowIn:c angleRad:(CGFloat)M_PI_4]; break;

        case HorizonIconPause: {
            UIBezierPath *l = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(6.2, 5.0, 4.0, 14.0) cornerRadius:1.2];
            UIBezierPath *r = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(13.8, 5.0, 4.0, 14.0) cornerRadius:1.2];
            [l fill];
            [r fill];
            break;
        }
        case HorizonIconChat: {
            // Crisp Bedrock speech bubble
            CGContextSetLineWidth(c, 2.0);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 5.5, 5.0);
            CGContextAddLineToPoint(c, 18.5, 5.0);
            CGContextAddQuadCurveToPoint(c, 20.5, 5.0, 20.5, 7.0);
            CGContextAddLineToPoint(c, 20.5, 14.8);
            CGContextAddQuadCurveToPoint(c, 20.5, 16.8, 18.5, 16.8);
            CGContextAddLineToPoint(c, 10.5, 16.8);
            CGContextAddLineToPoint(c, 6.2, 20.4);
            CGContextAddLineToPoint(c, 6.8, 16.8);
            CGContextAddLineToPoint(c, 5.5, 16.8);
            CGContextAddQuadCurveToPoint(c, 3.5, 16.8, 3.5, 14.8);
            CGContextAddLineToPoint(c, 3.5, 7.0);
            CGContextAddQuadCurveToPoint(c, 3.5, 5.0, 5.5, 5.0);
            CGContextClosePath(c);
            CGContextStrokePath(c);
            // Two text bars inside
            CGContextFillRect(c, CGRectMake(7.2, 8.8, 9.6, 1.8));
            CGContextFillRect(c, CGRectMake(7.2, 12.2, 6.6, 1.8));
            break;
        }
        case HorizonIconPerspective: {
            // Eye / camera toggle icon
            CGContextSetLineWidth(c, 2.0);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 2.8, 12.0);
            CGContextAddQuadCurveToPoint(c, 12.0, 4.2, 21.2, 12.0);
            CGContextAddQuadCurveToPoint(c, 12.0, 19.8, 2.8, 12.0);
            CGContextClosePath(c);
            CGContextStrokePath(c);
            CGContextFillEllipseInRect(c, CGRectMake(9.2, 9.2, 5.6, 5.6));
            break;
        }
        case HorizonIconSettings: {
            // Crisp 8-tooth gear
            CGContextSetLineWidth(c, 2.2);
            CGContextStrokeEllipseInRect(c, CGRectMake(8.5, 8.5, 7.0, 7.0));
            for (int i = 0; i < 8; i++) {
                CGFloat a = (CGFloat)(i * M_PI_4);
                CGFloat x0 = 12.0 + cos(a) * 5.6;
                CGFloat y0 = 12.0 + sin(a) * 5.6;
                CGFloat x1 = 12.0 + cos(a) * 8.6;
                CGFloat y1 = 12.0 + sin(a) * 8.6;
                CGContextBeginPath(c);
                CGContextMoveToPoint(c, x0, y0);
                CGContextAddLineToPoint(c, x1, y1);
                CGContextStrokePath(c);
            }
            break;
        }
        case HorizonIconInventoryDots: {
            // Bedrock classic 3 square dots beside hotbar slot 9
            CGContextFillRect(c, CGRectMake(4.0, 10.2, 3.6, 3.6));
            CGContextFillRect(c, CGRectMake(10.2, 10.2, 3.6, 3.6));
            CGContextFillRect(c, CGRectMake(16.4, 10.2, 3.6, 3.6));
            break;
        }
        case HorizonIconClose: {
            CGContextSetLineWidth(c, 2.8);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 6.0, 6.0);
            CGContextAddLineToPoint(c, 18.0, 18.0);
            CGContextMoveToPoint(c, 18.0, 6.0);
            CGContextAddLineToPoint(c, 6.0, 18.0);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconBack: {
            CGContextSetLineWidth(c, 2.8);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 15.2, 5.5);
            CGContextAddLineToPoint(c, 8.2, 12.0);
            CGContextAddLineToPoint(c, 15.2, 18.5);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconQuickMove: {
            // Double upward stack-transfer arrow
            CGContextSetLineWidth(c, 2.4);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 12.0, 19.5);
            CGContextAddLineToPoint(c, 12.0, 6.0);
            CGContextMoveToPoint(c, 6.8, 10.8);
            CGContextAddLineToPoint(c, 12.0, 5.2);
            CGContextAddLineToPoint(c, 17.2, 10.8);
            CGContextMoveToPoint(c, 6.5, 19.8);
            CGContextAddLineToPoint(c, 17.5, 19.8);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconDrop: {
            // Outward drop arrow into tray
            CGContextSetLineWidth(c, 2.3);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 12.0, 4.5);
            CGContextAddLineToPoint(c, 12.0, 15.2);
            CGContextMoveToPoint(c, 7.6, 11.2);
            CGContextAddLineToPoint(c, 12.0, 15.8);
            CGContextAddLineToPoint(c, 16.4, 11.2);
            CGContextMoveToPoint(c, 5.0, 16.5);
            CGContextAddLineToPoint(c, 5.0, 19.6);
            CGContextAddLineToPoint(c, 19.0, 19.6);
            CGContextAddLineToPoint(c, 19.0, 16.5);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconHome: {
            CGContextSetLineWidth(c, 2.0);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 3.5, 11.2);
            CGContextAddLineToPoint(c, 12.0, 4.2);
            CGContextAddLineToPoint(c, 20.5, 11.2);
            CGContextStrokePath(c);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 5.8, 10.2);
            CGContextAddLineToPoint(c, 5.8, 19.4);
            CGContextAddLineToPoint(c, 18.2, 19.4);
            CGContextAddLineToPoint(c, 18.2, 10.2);
            CGContextStrokePath(c);
            CGContextStrokeRectWithWidth(c, CGRectMake(9.8, 13.4, 4.4, 6.0), 1.8);
            break;
        }
        case HorizonIconServers: {
            CGContextSetLineWidth(c, 1.9);
            UIBezierPath *topBox = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(3.5, 4.2, 17.0, 6.4) cornerRadius:2.0];
            UIBezierPath *botBox = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(3.5, 13.4, 17.0, 6.4) cornerRadius:2.0];
            CGContextAddPath(c, topBox.CGPath);
            CGContextAddPath(c, botBox.CGPath);
            CGContextStrokePath(c);
            CGContextFillEllipseInRect(c, CGRectMake(6.2, 6.3, 2.2, 2.2));
            CGContextFillEllipseInRect(c, CGRectMake(6.2, 15.5, 2.2, 2.2));
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 11.2, 7.4);
            CGContextAddLineToPoint(c, 17.6, 7.4);
            CGContextMoveToPoint(c, 11.2, 16.6);
            CGContextAddLineToPoint(c, 17.6, 16.6);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconGamepad: {
            CGContextSetLineWidth(c, 1.9);
            UIBezierPath *body = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(3.0, 6.6, 18.0, 10.8) cornerRadius:4.8];
            CGContextAddPath(c, body.CGPath);
            CGContextStrokePath(c);
            // Left D-pad cross
            CGContextSetLineWidth(c, 2.0);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 8.2, 9.6);
            CGContextAddLineToPoint(c, 8.2, 14.4);
            CGContextMoveToPoint(c, 5.8, 12.0);
            CGContextAddLineToPoint(c, 10.6, 12.0);
            CGContextStrokePath(c);
            // Right face buttons
            CGContextFillEllipseInRect(c, CGRectMake(14.3, 10.2, 2.1, 2.1));
            CGContextFillEllipseInRect(c, CGRectMake(16.7, 12.2, 2.1, 2.1));
            break;
        }
        case HorizonIconSliders: {
            CGContextSetLineWidth(c, 2.0);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 4.0, 6.5);
            CGContextAddLineToPoint(c, 20.0, 6.5);
            CGContextMoveToPoint(c, 4.0, 12.0);
            CGContextAddLineToPoint(c, 20.0, 12.0);
            CGContextMoveToPoint(c, 4.0, 17.5);
            CGContextAddLineToPoint(c, 20.0, 17.5);
            CGContextStrokePath(c);
            CGContextFillEllipseInRect(c, CGRectMake(7.2, 4.4, 4.2, 4.2));
            CGContextFillEllipseInRect(c, CGRectMake(13.2, 9.9, 4.2, 4.2));
            CGContextFillEllipseInRect(c, CGRectMake(8.8, 15.4, 4.2, 4.2));
            break;
        }
        case HorizonIconFolder: {
            CGContextSetLineWidth(c, 1.9);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 3.5, 6.5);
            CGContextAddLineToPoint(c, 9.2, 6.5);
            CGContextAddLineToPoint(c, 11.2, 8.8);
            CGContextAddLineToPoint(c, 20.5, 8.8);
            CGContextAddLineToPoint(c, 20.5, 18.6);
            CGContextAddLineToPoint(c, 3.5, 18.6);
            CGContextClosePath(c);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconPlay: {
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 7.2, 5.0);
            CGContextAddLineToPoint(c, 19.2, 12.0);
            CGContextAddLineToPoint(c, 7.2, 19.0);
            CGContextClosePath(c);
            CGContextFillPath(c);
            break;
        }
        case HorizonIconPlus: {
            CGContextSetLineWidth(c, 2.4);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 12.0, 5.2);
            CGContextAddLineToPoint(c, 12.0, 18.8);
            CGContextMoveToPoint(c, 5.2, 12.0);
            CGContextAddLineToPoint(c, 18.8, 12.0);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconRefresh: {
            CGContextSetLineWidth(c, 2.1);
            CGContextAddArc(c, 12.0, 12.0, 6.8, -0.35 * M_PI, 1.35 * M_PI, 0);
            CGContextStrokePath(c);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 16.5, 4.6);
            CGContextAddLineToPoint(c, 18.0, 8.8);
            CGContextAddLineToPoint(c, 13.6, 8.4);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconKey: {
            CGContextSetLineWidth(c, 2.0);
            CGContextStrokeEllipseInRect(c, CGRectMake(4.0, 7.8, 7.4, 7.4));
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 11.4, 11.5);
            CGContextAddLineToPoint(c, 20.2, 11.5);
            CGContextMoveToPoint(c, 17.0, 11.5);
            CGContextAddLineToPoint(c, 17.0, 15.0);
            CGContextMoveToPoint(c, 20.0, 11.5);
            CGContextAddLineToPoint(c, 20.0, 14.6);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconEye: {
            CGContextSetLineWidth(c, 1.9);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 3.0, 12.0);
            CGContextAddQuadCurveToPoint(c, 12.0, 4.8, 21.0, 12.0);
            CGContextAddQuadCurveToPoint(c, 12.0, 19.2, 3.0, 12.0);
            CGContextStrokePath(c);
            CGContextFillEllipseInRect(c, CGRectMake(9.7, 9.7, 4.6, 4.6));
            break;
        }
        case HorizonIconEyeOff: {
            CGContextSetLineWidth(c, 1.9);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 3.0, 12.0);
            CGContextAddQuadCurveToPoint(c, 12.0, 4.8, 21.0, 12.0);
            CGContextAddQuadCurveToPoint(c, 12.0, 19.2, 3.0, 12.0);
            CGContextStrokePath(c);
            CGContextSetLineWidth(c, 2.1);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 4.8, 19.2);
            CGContextAddLineToPoint(c, 19.2, 4.8);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconEdit: {
            CGContextSetLineWidth(c, 2.0);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 15.2, 4.6);
            CGContextAddLineToPoint(c, 19.4, 8.8);
            CGContextAddLineToPoint(c, 8.8, 19.4);
            CGContextAddLineToPoint(c, 4.6, 19.4);
            CGContextAddLineToPoint(c, 4.6, 15.2);
            CGContextClosePath(c);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconTrash: {
            CGContextSetLineWidth(c, 1.9);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 4.5, 6.8);
            CGContextAddLineToPoint(c, 19.5, 6.8);
            CGContextMoveToPoint(c, 9.2, 6.8);
            CGContextAddLineToPoint(c, 9.2, 4.4);
            CGContextAddLineToPoint(c, 14.8, 4.4);
            CGContextAddLineToPoint(c, 14.8, 6.8);
            CGContextMoveToPoint(c, 6.5, 6.8);
            CGContextAddLineToPoint(c, 7.4, 19.4);
            CGContextAddLineToPoint(c, 16.6, 19.4);
            CGContextAddLineToPoint(c, 17.5, 6.8);
            CGContextMoveToPoint(c, 10.2, 10.2);
            CGContextAddLineToPoint(c, 10.2, 16.2);
            CGContextMoveToPoint(c, 13.8, 10.2);
            CGContextAddLineToPoint(c, 13.8, 16.2);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconGlobe: {
            CGContextSetLineWidth(c, 1.8);
            CGContextStrokeEllipseInRect(c, CGRectMake(3.8, 3.8, 16.4, 16.4));
            CGContextStrokeEllipseInRect(c, CGRectMake(8.2, 3.8, 7.6, 16.4));
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 4.2, 12.0);
            CGContextAddLineToPoint(c, 19.8, 12.0);
            CGContextMoveToPoint(c, 5.6, 7.8);
            CGContextAddLineToPoint(c, 18.4, 7.8);
            CGContextMoveToPoint(c, 5.6, 16.2);
            CGContextAddLineToPoint(c, 18.4, 16.2);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconShare: {
            CGContextSetLineWidth(c, 2.0);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 12.0, 14.5);
            CGContextAddLineToPoint(c, 12.0, 4.2);
            CGContextMoveToPoint(c, 8.2, 7.8);
            CGContextAddLineToPoint(c, 12.0, 4.0);
            CGContextAddLineToPoint(c, 15.8, 7.8);
            CGContextMoveToPoint(c, 6.0, 11.2);
            CGContextAddLineToPoint(c, 5.0, 11.2);
            CGContextAddLineToPoint(c, 5.0, 19.5);
            CGContextAddLineToPoint(c, 19.0, 19.5);
            CGContextAddLineToPoint(c, 19.0, 11.2);
            CGContextAddLineToPoint(c, 18.0, 11.2);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconDocument: {
            CGContextSetLineWidth(c, 1.9);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 6.0, 3.6);
            CGContextAddLineToPoint(c, 14.2, 3.6);
            CGContextAddLineToPoint(c, 18.4, 7.8);
            CGContextAddLineToPoint(c, 18.4, 20.4);
            CGContextAddLineToPoint(c, 6.0, 20.4);
            CGContextClosePath(c);
            CGContextStrokePath(c);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 8.8, 11.2);
            CGContextAddLineToPoint(c, 15.6, 11.2);
            CGContextMoveToPoint(c, 8.8, 14.6);
            CGContextAddLineToPoint(c, 15.6, 14.6);
            CGContextMoveToPoint(c, 8.8, 17.6);
            CGContextAddLineToPoint(c, 13.0, 17.6);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconCheck: {
            CGContextSetLineWidth(c, 2.6);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 5.2, 12.4);
            CGContextAddLineToPoint(c, 9.8, 17.2);
            CGContextAddLineToPoint(c, 19.0, 7.0);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconWarning: {
            CGContextSetLineWidth(c, 2.0);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 12.0, 4.0);
            CGContextAddLineToPoint(c, 20.4, 19.2);
            CGContextAddLineToPoint(c, 3.6, 19.2);
            CGContextClosePath(c);
            CGContextStrokePath(c);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 12.0, 9.4);
            CGContextAddLineToPoint(c, 12.0, 13.8);
            CGContextStrokePath(c);
            CGContextFillEllipseInRect(c, CGRectMake(10.9, 15.6, 2.2, 2.2));
            break;
        }
        case HorizonIconChevronRight: {
            CGContextSetLineWidth(c, 2.3);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 9.2, 6.4);
            CGContextAddLineToPoint(c, 15.0, 12.0);
            CGContextAddLineToPoint(c, 9.2, 17.6);
            CGContextStrokePath(c);
            break;
        }
        case HorizonIconHorizonCube: {
            // Isometric Minecraft/Horizon block mark with shaded faces
            CGContextSaveGState(c);
            // Top face (brightest)
            CGContextSetAlpha(c, 1.0);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 12.0, 2.6);
            CGContextAddLineToPoint(c, 20.4, 7.4);
            CGContextAddLineToPoint(c, 12.0, 12.2);
            CGContextAddLineToPoint(c, 3.6, 7.4);
            CGContextClosePath(c);
            CGContextFillPath(c);
            // Left face (medium)
            CGContextSetAlpha(c, 0.72);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 3.6, 7.4);
            CGContextAddLineToPoint(c, 12.0, 12.2);
            CGContextAddLineToPoint(c, 12.0, 21.4);
            CGContextAddLineToPoint(c, 3.6, 16.6);
            CGContextClosePath(c);
            CGContextFillPath(c);
            // Right face (deepest)
            CGContextSetAlpha(c, 0.48);
            CGContextBeginPath(c);
            CGContextMoveToPoint(c, 20.4, 7.4);
            CGContextAddLineToPoint(c, 12.0, 12.2);
            CGContextAddLineToPoint(c, 12.0, 21.4);
            CGContextAddLineToPoint(c, 20.4, 16.6);
            CGContextClosePath(c);
            CGContextFillPath(c);
            CGContextRestoreGState(c);
            break;
        }
    }
}

@end
