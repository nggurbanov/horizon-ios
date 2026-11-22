// horizon-ios: native dark-slate Add / Edit Server sheet with per-server Auto-Login settings.
#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface HorizonServerEditorViewController : UIViewController

/// Index in `servers.dat` when editing an existing server, or `-1` when adding a new one.
@property (nonatomic, assign) NSInteger serverIndex;
@property (nonatomic, copy) NSString *initialName;
@property (nonatomic, copy) NSString *initialAddress;
@property (nonatomic, copy) NSString *serversDatPath;

@property (nonatomic, copy, nullable) void (^onSaved)(void);
@property (nonatomic, copy, nullable) void (^onDeleted)(void);

@end

NS_ASSUME_NONNULL_END
