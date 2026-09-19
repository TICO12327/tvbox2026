#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^FBAudioPCMHandler)(NSData *data, double sampleRate);

/// Captures decoded AVPlayer audio without opening the microphone.
@interface FBAudioTapBridge : NSObject

+ (BOOL)installOnPlayerItem:(AVPlayerItem *)item
                  audioTrack:(AVAssetTrack *)audioTrack
                     handler:(FBAudioPCMHandler)handler
    NS_SWIFT_NAME(install(on:audioTrack:handler:));

@end

NS_ASSUME_NONNULL_END
