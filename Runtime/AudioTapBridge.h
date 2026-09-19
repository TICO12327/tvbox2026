#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 音频 tap 回调：交付单声道 Float32 样本（取值范围 [-1, 1]）及其采样率。
typedef void (^FBAudioPCMHandler)(const float *samples, NSUInteger count, double sampleRate);

/// 在不打开麦克风的前提下采集 AVPlayer 已解码的音频。
@interface FBAudioTapBridge : NSObject

/// 在播放器的音频轨道上安装 tap。
///
/// 注意：必须在 `AVPlayerItem.status == READY_TO_PLAY` 之后调用。
/// 直播流在 item 刚创建时 manifest 尚未解析，`loadTracks` 常返回空，
/// 此时安装 tap 会失败并丢失整条音轨。
+ (BOOL)installOnPlayerItem:(AVPlayerItem *)item
                  audioTrack:(AVAssetTrack *)audioTrack
                     handler:(FBAudioPCMHandler)handler
    NS_SWIFT_NAME(install(on:audioTrack:handler:));

/// 移除已安装的 tap，避免切换频道后旧 tap 继续回调。
+ (void)uninstallFromPlayerItem:(AVPlayerItem *)item
    NS_SWIFT_NAME(uninstall(from:));

@end

NS_ASSUME_NONNULL_END
