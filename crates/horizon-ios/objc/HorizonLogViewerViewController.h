// horizon-ios: scrollable monospace log & crash report viewer sheet.
#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface HorizonLogViewerViewController : UIViewController

@property (nonatomic, copy) NSArray<NSString *> *titles;
@property (nonatomic, copy) NSArray<NSURL *> *fileURLs;

@end

NS_ASSUME_NONNULL_END
