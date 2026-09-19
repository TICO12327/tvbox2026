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
@property (nonatomic) dispatch_queue_t deliveryQueue;
@end

@implementation FBAudioTapContext
@end

static FBAudioTapContext *FBContextForTap(MTAudioProcessingTapRef tap) {
    return (__bridge FBAudioTapContext *)MTAudioProcessingTapGetStorage(tap);
}

static void FBTapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    // clientInfo is retained with CFBridgingRetain before the tap is created.
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
    context.sampleRate = processingFormat->mSampleRate;
    context.channelCount = processingFormat->mChannelsPerFrame;
    context.bytesPerSample = processingFormat->mBitsPerChannel > 16 ? 4 : 2;
    context.formatFlags = processingFormat->mFormatFlags;
}

static float FBSampleValue(const uint8_t *bytes, UInt32 bytesPerSample, AudioFormatFlags flags) {
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
    }

    if (bytesPerSample == sizeof(int16_t)) {
        int16_t value = 0;
        memcpy(&value, bytes, sizeof(value));
        return (float)value / 32768.0f;
    }
    if (bytesPerSample >= sizeof(int32_t)) {
        int32_t value = 0;
        memcpy(&value, bytes, sizeof(value));
        return (float)value / 2147483648.0f;
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

    if (status != noErr || sourceFrames == 0) {
        *numberFramesOut = 0;
        if (flagsOut != NULL) {
            *flagsOut = sourceFlags;
        }
        return;
    }

    *numberFramesOut = sourceFrames;
    if (flagsOut != NULL) {
        *flagsOut = sourceFlags;
    }

    const UInt32 channels = MAX(1, context.channelCount);
    const UInt32 bytesPerSample = MAX(1, context.bytesPerSample);
    const BOOL nonInterleaved = (context.formatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    NSMutableData *monoData = [NSMutableData dataWithLength:sourceFrames * sizeof(float)];
    float *mono = (float *)monoData.mutableBytes;

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

    NSData *deliveryData = [monoData copy];
    double sampleRate = context.sampleRate > 0 ? context.sampleRate : 44100.0;
    dispatch_async(context.deliveryQueue, ^{
        FBAudioPCMHandler handler = context.handler;
        if (handler != nil) {
            handler(deliveryData, sampleRate);
        }
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
    OSStatus status = MTAudioProcessingTapCreate(
        kCFAllocatorDefault,
        &callbacks,
        kMTAudioProcessingTapCreationFlag_PostEffects,
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

    CFRelease(tap);
    return YES;
}

@end
