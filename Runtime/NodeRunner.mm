#import "NodeRunner.h"

#include <NodeMobile/NodeMobile.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

@implementation FBNodeRunner

static dispatch_queue_t FBNodeRunnerQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.tico.FlowBox.node", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static BOOL FBNodeRunnerStarted = NO;

+ (BOOL)startWithScriptPath:(NSString *)scriptPath
                        port:(NSInteger)port
                       error:(NSError * _Nullable * _Nullable)error {
    if (scriptPath.length == 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"FlowBox.NodeRuntime"
                                          code:1
                                      userInfo:@{NSLocalizedDescriptionKey: @"NodeJS 脚本路径为空"}];
        }
        return NO;
    }

    @synchronized (self) {
        if (FBNodeRunnerStarted) {
            return YES;
        }
        FBNodeRunnerStarted = YES;
    }

    NSString *directory = [scriptPath stringByDeletingLastPathComponent];
    NSString *portString = [NSString stringWithFormat:@"%ld", (long)MAX(1, port)];

    dispatch_async(FBNodeRunnerQueue(), ^{
        @autoreleasepool {
            // CatVodSpider uses process.argv[1] to decide whether it should
            // auto-start. Its bundle is intentionally saved as index.js.
            if (chdir(directory.fileSystemRepresentation) != 0) {
                NSLog(@"[FlowBox] unable to change Node working directory: %s", strerror(errno));
            }
            setenv("PORT", portString.UTF8String, 1);
            setenv("HOST", "127.0.0.1", 1);
            unsetenv("CATVOD_DISABLE_AUTOSTART");

            NSArray<NSString *> *arguments = @[
                @"flowbox-node",
                scriptPath
            ];

            // libuv expects argv strings to remain contiguous while node_start
            // owns the event loop. Keep both the buffer and argv alive until it
            // returns, matching the official NodeMobile sample.
            size_t bufferSize = 0;
            for (NSString *argument in arguments) {
                bufferSize += argument.lengthOfBytesUsingEncoding:NSUTF8StringEncoding + 1;
            }

            char *argumentBuffer = (char *)calloc(bufferSize, sizeof(char));
            char **argv = (char **)calloc(arguments.count, sizeof(char *));
            if (argumentBuffer == NULL || argv == NULL) {
                free(argumentBuffer);
                free(argv);
                @synchronized (self) {
                    FBNodeRunnerStarted = NO;
                }
                return;
            }

            char *cursor = argumentBuffer;
            int argc = 0;
            for (NSString *argument in arguments) {
                const char *utf8 = argument.UTF8String;
                size_t length = strlen(utf8);
                memcpy(cursor, utf8, length);
                cursor[length] = '\0';
                argv[argc++] = cursor;
                cursor += length + 1;
            }

            node_start(argc, argv);

            free(argv);
            free(argumentBuffer);
            @synchronized (self) {
                FBNodeRunnerStarted = NO;
            }
        }
    });

    return YES;
}

+ (BOOL)isRunning {
    @synchronized (self) {
        return FBNodeRunnerStarted;
    }
}

@end
