#import "AudioTapBridge.h"

#import <MediaToolbox/MediaToolbox.h>
#include <math.h>
#include <string.h>

@interface FBAudioTapContext : NSObject
@property (nonatomic, copy) FBAudioPCMHandler handler;
@property (nonatomic) double sampleRate;
@property (nonatomic) UInt32 channelCount;
@property (nonatomic) UInt32 bytesPerSample;
@property (nonatomic) AudioFormatFlags formatFlags;
@property (nonatomic, strong) dispatch_queue_t deliveryQueue;
/// 复用的缓冲区，避免音频线程上反复分配内存（会造成爆音/丢帧）。
@property (nonatomic, strong) NSMutableData *scratch;
@end

@implementation FBAudioTapContext
@end

static FBAudioTapContext *FBContextForTap(MTAudioProcessingTapRef tap) {
    return (__bridge FBAudioTapContext *)MTAudioProcessingTapGetStorage(tap);
}

static void FBTapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    // clientInfo 在创建 tap 之前已用 CFBridgingRetain 持有，这里直接移交所有权。
    *tapStorageOut = clientInfo;
}

static void FBTapFinalize(MTAudioProcessingTapRef tap) {
    void *storage = MTAudioProcessingTapGetStorage(tap);
    if (storage != NULL) {
        CFBridgingRelease(storage);
    }
}

static void FBTapPrepare(
    MTAudioProcessingTapRef tap,
    CMItemCount maxFrames,
    const AudioStreamBasicDescription *processingFormat
) {
    (void)maxFrames;
    FBAudioTapContext *context = FBContextForTap(tap);
    if (context == nil || processingFormat == NULL) {
        return;
    }
    context.sampleRate = processingFormat->mSampleRate;
    context.channelCount = processingFormat->mChannelsPerFrame;

    // 依据格式标志精确判断样本位宽，而不是只看 mBitsPerChannel。
    // 浮点格式下 mBitsPerChannel 与实际存储宽度可能不一致。
    if ((processingFormat->mFormatFlags & kAudioFormatFlagIsFloat) != 0) {
        context.bytesPerSample = (processingFormat->mBitsPerChannel == 64) ? 8 : 4;
    } else {
        context.bytesPerSample = (processingFormat->mBitsPerChannel > 16) ? 4 : 2;
    }
    context.formatFlags = processingFormat->mFormatFlags;
}

static float FBSampleValue(const uint8_t *bytes, UInt32 bytesPerSample, AudioFormatFlags flags) {
    if (bytes == NULL) {
        return 0;
    }
    if ((flags & kAudioFormatFlagIsFloat) != 0) {
        if (bytesPerSample == sizeof(float)) {
            float value = 0;
            memcpy(&value, bytes, sizeof(float));
            return isfinite(value) ? value : 0;
        }
        if (bytesPerSample == sizeof(double)) {
            double value = 0;
            memcpy(&value, bytes, sizeof(double));
            return isfinite(value) ? (float)value : 0;
        }
        return 0;
    }

    // 整数格式需要处理「有符号 / 无符号」两种表示。
    const BOOL isSigned = (flags & kAudioFormatFlagIsSignedInteger) != 0;
    if (bytesPerSample == sizeof(int16_t)) {
        if (isSigned) {
            int16_t value = 0;
            memcpy(&value, bytes, sizeof(value));
            return (float)value / 32768.0f;
        }
        uint16_t value = 0;
        memcpy(&value, bytes, sizeof(value));
        return ((float)value - 32768.0f) / 32768.0f;
    }
    if (bytesPerSample >= sizeof(int32_t)) {
        if (isSigned) {
            int32_t value = 0;
            memcpy(&value, bytes, sizeof(value));
            return (float)((double)value / 2147483648.0);
        }
        uint32_t value = 0;
        memcpy(&value, bytes, sizeof(value));
        return (float)(((double)value - 2147483648.0) / 2147483648.0);
    }
    return 0;
}

static void FBTapProcess(
    MTAudioProcessingTapRef tap,
    CMItemCount numberFrames,
    MTAudioProcessingTapFlags flags,
    AudioBufferList *bufferListInOut,
    CMItemCount *numberFramesOut,
    MTAudioProcessingTapFlags *flagsOut
) {
    FBAudioTapContext *context = FBContextForTap(tap);
    MTAudioProcessingTapFlags sourceFlags = flags;
    CMItemCount sourceFrames = 0;
    OSStatus status = MTAudioProcessingTapGetSourceAudio(
        tap,
        numberFrames,
        bufferListInOut,
        &sourceFlags,
        NULL,
        &sourceFrames
    );

    // 任何异常路径都必须回填 out 参数，否则播放器会认为没有可用帧而卡住。
    if (status != noErr || sourceFrames <= 0 || context == nil) {
        *numberFramesOut = (status == noErr) ? sourceFrames : 0;
        if (flagsOut != NULL) {
            *flagsOut = sourceFlags;
        }
        return;
    }

    *numberFramesOut = sourceFrames;
    if (flagsOut != NULL) {
        *flagsOut = sourceFlags;
    }

    if (context.handler == nil) {
        return;
    }

    const UInt32 channels = MAX(1, context.channelCount);
    const UInt32 bytesPerSample = MAX(1, context.bytesPerSample);
    const BOOL nonInterleaved = (context.formatFlags & kAudioFormatFlagIsNonInterleaved) != 0;

    // 复用缓冲区，避免音频实时线程上的分配开销。
    if (context.scratch == nil || context.scratch.length < (NSUInteger)(sourceFrames * sizeof(float))) {
        context.scratch = [NSMutableData dataWithLength:(NSUInteger)(sourceFrames * sizeof(float))];
    }
    float *mono = (float *)context.scratch.mutableBytes;

    for (CMItemCount frame = 0; frame < sourceFrames; frame++) {
        float sum = 0;
        UInt32 validChannels = 0;
        for (UInt32 channel = 0; channel < channels; channel++) {
            UInt32 bufferIndex = nonInterleaved ? channel : 0;
            if (bufferIndex >= bufferListInOut->mNumberBuffers) {
                continue;
            }
            AudioBuffer audioBuffer = bufferListInOut->mBuffers[bufferIndex];
            if (audioBuffer.mData == NULL) {
                continue;
            }
            if ((NSUInteger)(frame * (nonInterleaved ? bytesPerSample : bytesPerSample * channels) + bytesPerSample)
                > audioBuffer.mDataByteSize) {
                continue;
            }
            UInt32 stride = nonInterleaved ? bytesPerSample : bytesPerSample * channels;
            const uint8_t *sample = (const uint8_t *)audioBuffer.mData + frame * stride;
            if (!nonInterleaved) {
                sample += channel * bytesPerSample;
            }
            sum += FBSampleValue(sample, bytesPerSample, context.formatFlags);
            validChannels += 1;
        }
        mono[frame] = validChannels == 0 ? 0 : sum / (float)validChannels;
    }

    // 复制出来再异步投递：scratch 会被下一次 process 覆写。
    NSUInteger sampleCount = (NSUInteger)sourceFrames;
    NSData *deliveryData = [NSData dataWithBytes:mono length:sampleCount * sizeof(float)];
    double sampleRate = context.sampleRate > 0 ? context.sampleRate : 44100.0;
    dispatch_queue_t queue = context.deliveryQueue;
    FBAudioPCMHandler handler = context.handler;

    if (queue == nil || handler == nil) {
        return;
    }
    dispatch_async(queue, ^{
        const float *samples = (const float *)deliveryData.bytes;
        handler(samples, sampleCount, sampleRate);
    });
}

@implementation FBAudioTapBridge

+ (BOOL)installOnPlayerItem:(AVPlayerItem *)item
                  audioTrack:(AVAssetTrack *)audioTrack
                     handler:(FBAudioPCMHandler)handler {
    if (item == nil || audioTrack == nil || handler == nil) {
        return NO;
    }

    FBAudioTapContext *context = [FBAudioTapContext new];
    context.handler = handler;
    context.deliveryQueue = dispatch_queue_create("com.tico.FlowBox.audio-tap", DISPATCH_QUEUE_SERIAL);

    MTAudioProcessingTapCallbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;
    callbacks.clientInfo = (void *)CFBridgingRetain(context);
    callbacks.init = FBTapInit;
    callbacks.finalize = FBTapFinalize;
    callbacks.prepare = FBTapPrepare;
    callbacks.process = FBTapProcess;

    MTAudioProcessingTapRef tap = NULL;
    // 使用 PreEffects：拿到的是解码后的原始音频，不受音量/均衡器等
    // 播放器后处理影响，识别准确率更稳定。
    OSStatus status = MTAudioProcessingTapCreate(
        kCFAllocatorDefault,
        &callbacks,
        kMTAudioProcessingTapCreationFlag_PreEffects,
        &tap
    );
    if (status != noErr || tap == NULL) {
        CFBridgingRelease(callbacks.clientInfo);
        return NO;
    }

    AVMutableAudioMixInputParameters *parameters =
        [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:audioTrack];
    parameters.audioTapProcessor = tap;
    AVMutableAudioMix *audioMix = [AVMutableAudioMix audioMix];
    audioMix.inputParameters = @[parameters];
    item.audioMix = audioMix;

    // audioMix 已持有 tap，这里释放创建时的那份引用。
    CFRelease(tap);
    return YES;
}

+ (void)uninstallFromPlayerItem:(AVPlayerItem *)item {
    if (item == nil) {
        return;
    }
    // 清空 audioMix 会释放 tap，其 finalize 回调负责释放 context。
    item.audioMix = nil;
}

@end
