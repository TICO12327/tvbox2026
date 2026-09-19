#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Small Objective-C++ bridge around the iOS NodeMobile runtime.
///
/// NodeMobile owns the Node event loop, so `startWithScriptPath` returns after
/// scheduling the engine on a background thread. The Swift side waits for the
/// HTTP health endpoint before sending spider requests.
@interface FBNodeRunner : NSObject

+ (BOOL)startWithScriptPath:(NSString *)scriptPath
                        port:(NSInteger)port
                       error:(NSError * _Nullable * _Nullable)error;

+ (BOOL)isRunning;
+ (int)lastExitCode;

@end

NS_ASSUME_NONNULL_END
