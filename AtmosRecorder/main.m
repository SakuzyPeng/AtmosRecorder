#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "TapManager.h"
#import <AudioToolbox/AudioToolbox.h>
#ifdef __APPLE__
#import <AppKit/AppKit.h>
#endif

// 定义错误代码
typedef NS_ENUM(NSInteger, AtmosRecorderError) {
    AtmosRecorderErrorNoInput = 1,
    AtmosRecorderErrorInvalidFormat,
    AtmosRecorderErrorNoAtmos,
    AtmosRecorderErrorWriteFailed,
    AtmosRecorderErrorDiskSpace
};

static BOOL g_processCompletelyFinished = NO;
static NSString *g_outputFilePath = nil;

// 显示使用说明
void showUsage(const char *programName) {
    printf("Atmos音频提取工具 v1.0\n");
    printf("用法:\n");
    printf("  %s                  - 在程序目录中查找并处理第一个音频文件\n", programName);
    printf("  %s <文件路径>       - 处理指定的音频文件\n", programName);
    printf("  %s <文件1> <文件2>  - 批量处理多个文件\n", programName);
    printf("\n支持的格式: .m4a, .eac3, .ec3\n");
    printf("输出格式: 12声道 Atmos 7.1.4 WAV (48kHz, 32-bit Float)\n");
}

// 检查文件是否为支持的音频格式
BOOL isSupportedAudioFile(NSString *path) {
    NSArray<NSString*> *extensions = @[@"m4a", @"eac3", @"ec3"];
    NSString *ext = path.pathExtension.lowercaseString;
    return [extensions containsObject:ext];
}

// 查找目录中第一个适合的音频文件（.m4a或.eac3/.ec3）
NSString* findFirstAudioFile(NSString *directory) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray<NSString *> *contents = [fileManager contentsOfDirectoryAtPath:directory error:&error];
    
    if (error) {
        fprintf(stderr, "错误: 无法读取目录 '%s': %s\n",
                directory.UTF8String, error.localizedDescription.UTF8String);
        return nil;
    }
    
    for (NSString *item in contents) {
        NSString *fullPath = [directory stringByAppendingPathComponent:item];
        if (isSupportedAudioFile(fullPath)) {
            return fullPath;
        }
    }
    return nil;
}

// 生成输出文件路径（避免覆盖）
NSString* generateOutputPath(NSString *inputPath) {
    NSString *directory = [inputPath stringByDeletingLastPathComponent];
    NSString *baseName = [[inputPath lastPathComponent] stringByDeletingPathExtension];
    NSString *baseOutputPath = [directory stringByAppendingPathComponent:
                               [NSString stringWithFormat:@"%@_atmos_714.wav", baseName]];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *outputPath = baseOutputPath;
    int counter = 1;
    
    // 如果文件已存在，添加编号
    while ([fileManager fileExistsAtPath:outputPath]) {
        outputPath = [directory stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@_atmos_714_%d.wav", baseName, counter++]];
    }
    
    return outputPath;
}

// 显示文件信息
void displayFileInfo(AVAsset *asset, NSString *inputPath) {
    CMTime duration = asset.duration;
    Float64 seconds = CMTimeGetSeconds(duration);
    
    if (CMTIME_IS_INVALID(duration)) {
        printf("输入文件: %s\n", inputPath.lastPathComponent.UTF8String);
        printf("  时长: 未知\n");
        return;
    }
    
    printf("输入文件: %s\n", inputPath.lastPathComponent.UTF8String);
    printf("  时长: %.2f 秒 (%.0f:%02.0f)\n", seconds, floor(seconds/60), fmod(seconds, 60));
    
    // 估算输出文件大小 (12通道 * 48000采样率 * 4字节每样本)
    double estimatedMB = seconds * 48000 * 12 * 4 / 1024 / 1024;
    printf("  预计输出大小: %.1f MB\n", estimatedMB);
    
    // 检查音轨信息
    if (@available(macOS 15.0, *)) {
        [asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack *> * _Nullable tracks, NSError * _Nullable error) {
            if (!error && tracks.count > 0) {
                printf("  音轨数量: %lu\n", (unsigned long)tracks.count);
            }
        }];
    } else {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
        if (audioTracks.count > 0) {
            printf("  音轨数量: %lu\n", (unsigned long)audioTracks.count);
        }
        #pragma clang diagnostic pop
    }
}

// 检查磁盘空间
BOOL checkDiskSpace(NSString *outputPath, double requiredMB) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSDictionary *attrs = [fileManager attributesOfFileSystemForPath:[outputPath stringByDeletingLastPathComponent]
                                                                error:&error];
    if (error) {
        return YES; // 如果无法检查，假设有足够空间
    }
    
    NSNumber *freeSpace = attrs[NSFileSystemFreeSize];
    double freeSpaceMB = freeSpace.doubleValue / 1024 / 1024;
    
    if (freeSpaceMB < requiredMB * 1.1) { // 留10%余量
        fprintf(stderr, "警告: 磁盘空间可能不足 (可用: %.1f MB, 需要: %.1f MB)\n",
                freeSpaceMB, requiredMB);
        return NO;
    }
    
    return YES;
}

// 处理完成后的操作
void handleCompletion(NSString *outputPath, NSError *error) {
    if (error) {
        fprintf(stderr, "转换失败: %s\n", error.localizedDescription.UTF8String);
        return;
    }
    
    printf("\n转换成功!\n");
    printf("输出文件: %s\n", outputPath.UTF8String);
    
    // 验证输出文件
    NSError *readError = nil;
    AVAudioFile *outputFile = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:outputPath]
                                                             error:&readError];
    if (!readError && outputFile) {
        printf("  声道数: %u\n", outputFile.fileFormat.channelCount);
        printf("  采样率: %.0f Hz\n", outputFile.fileFormat.sampleRate);
        printf("  文件大小: %.1f MB\n", outputFile.length * outputFile.fileFormat.streamDescription->mBytesPerFrame / 1024.0 / 1024.0);
    }
    
#ifdef __APPLE__
    // 在 Finder 中显示文件
    NSString *folderPath = [outputPath stringByDeletingLastPathComponent];
    [[NSWorkspace sharedWorkspace] selectFile:outputPath
                     inFileViewerRootedAtPath:folderPath];
    
    // 播放完成提示音
    NSSound *sound = [NSSound soundNamed:@"Glass"];
    [sound play];
#endif
}

// 处理单个文件
BOOL processFile(NSString *inputPath) {
    printf("\n========================================\n");
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:inputPath]) {
        fprintf(stderr, "错误: 文件不存在: %s\n", inputPath.UTF8String);
        return NO;
    }
    
    if (!isSupportedAudioFile(inputPath)) {
        fprintf(stderr, "错误: 不支持的文件格式: %s\n", inputPath.pathExtension.UTF8String);
        return NO;
    }
    
    NSString *outputPath = generateOutputPath(inputPath);
    g_outputFilePath = outputPath;
    
    NSURL *inputURL = [NSURL fileURLWithPath:inputPath];
    NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
    
    // 创建 AVAsset 并显示信息
    AVAsset *asset = [AVAsset assetWithURL:inputURL];
    displayFileInfo(asset, inputPath);
    
    // 检查磁盘空间
    CMTime duration = asset.duration;
    if (CMTIME_IS_VALID(duration)) {
        Float64 seconds = CMTimeGetSeconds(duration);
        double estimatedMB = seconds * 48000 * 12 * 4 / 1024 / 1024;
        if (!checkDiskSpace(outputPath, estimatedMB)) {
            char response[10];
            printf("是否继续? (y/n): ");
            if (fgets(response, sizeof(response), stdin)) {
                if (response[0] != 'y' && response[0] != 'Y') {
                    printf("已取消\n");
                    return NO;
                }
            }
        }
    }
    
    AVPlayerItem *playerItem = [AVPlayerItem playerItemWithURL:inputURL];
    if (!playerItem) {
        fprintf(stderr, "错误: 无法创建 AVPlayerItem\n");
        return NO;
    }
    
//    playerItem.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmVarispeed;
    
    // --- 配置 TAP 输出格式为: 12 声道, Atmos 7.1.4 ---
    double sampleRate = 48000.0;
    UInt32 targetChannelCount = 12;
    AudioChannelLayoutTag layoutTagToUse = kAudioChannelLayoutTag_Atmos_7_1_4;
    AVAudioChannelLayout *targetChannelLayout = nil;
    
    AudioChannelLayout layoutStruct;
    memset(&layoutStruct, 0, sizeof(AudioChannelLayout));
    layoutStruct.mChannelLayoutTag = layoutTagToUse;
    targetChannelLayout = [[AVAudioChannelLayout alloc] initWithLayout:&layoutStruct];

    if (!targetChannelLayout) {
        fprintf(stderr, "错误: 无法创建 Atmos 7.1.4 声道布局\n");
        return NO;
    }
    
    AVAudioFormat *fixedTargetOutputFormat;
    AudioStreamBasicDescription outputASBD;
    memset(&outputASBD, 0, sizeof(outputASBD));
    outputASBD.mSampleRate       = sampleRate;
    outputASBD.mFormatID         = kAudioFormatLinearPCM;
    outputASBD.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved;
    outputASBD.mChannelsPerFrame = targetChannelCount;
    outputASBD.mBitsPerChannel   = 32;
    outputASBD.mBytesPerPacket   = outputASBD.mBytesPerFrame = (outputASBD.mBitsPerChannel / 8);
    outputASBD.mFramesPerPacket  = 1;
    
    fixedTargetOutputFormat = [[AVAudioFormat alloc] initWithStreamDescription:&outputASBD
                                                                 channelLayout:targetChannelLayout];
    
    if (!fixedTargetOutputFormat) {
        fprintf(stderr, "错误: 无法创建输出格式\n");
        return NO;
    }
    
    // --- TapManager 初始化并开始录制 ---
    __block TapManager *tapManager = [[TapManager alloc] initWithPlayerItem:playerItem
                                                         targetOutputFormat:fixedTargetOutputFormat
                                                              outputFileURL:outputURL];
    
    if (!tapManager) {
        fprintf(stderr, "错误: 无法初始化音频处理器\n");
        return NO;
    }
    
    __block BOOL success = YES;
    __block NSError *recordingError = nil;
    
    printf("\n");
    [tapManager startRecording:^(NSError * _Nullable error) {
        recordingError = error;
        success = (error == nil);
        g_processCompletelyFinished = YES;
    }];
    
    // 等待处理完成
    while (!g_processCompletelyFinished &&
           [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]]) {
        // 保持运行循环活跃
    }
    
    handleCompletion(outputPath, recordingError);
    
    tapManager = nil;
    g_processCompletelyFinished = NO; // 重置以便处理下一个文件
    
    return success;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        [NSThread setThreadPriority:1.0];
        printf("Atmos音频提取工具 v1.0\n");
        printf("========================================\n");
        
        NSMutableArray<NSString *> *filesToProcess = [NSMutableArray array];
        
        if (argc > 1) {
            // 处理命令行参数
            for (int i = 1; i < argc; i++) {
                NSString *arg = [NSString stringWithUTF8String:argv[i]];
                
                if ([arg isEqualToString:@"-h"] || [arg isEqualToString:@"--help"]) {
                    showUsage(argv[0]);
                    return 0;
                }
                
                // 展开路径（处理 ~ 等）
                NSString *expandedPath = [arg stringByExpandingTildeInPath];
                
                // 检查是否为目录
                BOOL isDirectory;
                if ([[NSFileManager defaultManager] fileExistsAtPath:expandedPath isDirectory:&isDirectory]) {
                    if (isDirectory) {
                        // 如果是目录，查找其中的音频文件
                        NSFileManager *fileManager = [NSFileManager defaultManager];
                        NSArray *contents = [fileManager contentsOfDirectoryAtPath:expandedPath error:nil];
                        for (NSString *item in contents) {
                            NSString *fullPath = [expandedPath stringByAppendingPathComponent:item];
                            if (isSupportedAudioFile(fullPath)) {
                                [filesToProcess addObject:fullPath];
                            }
                        }
                    } else if (isSupportedAudioFile(expandedPath)) {
                        [filesToProcess addObject:expandedPath];
                    } else {
                        fprintf(stderr, "警告: 跳过不支持的文件: %s\n", expandedPath.UTF8String);
                    }
                }
            }
        } else {
            // 在程序目录中查找
            NSString *executablePath = [[NSBundle mainBundle] executablePath];
            NSString *executableDir = [executablePath stringByDeletingLastPathComponent];
            printf("程序目录: %s\n", executableDir.UTF8String);
            
            NSString *foundFile = findFirstAudioFile(executableDir);
            if (foundFile) {
                [filesToProcess addObject:foundFile];
            } else {
                fprintf(stderr, "错误: 在程序目录中未找到音频文件\n");
                fprintf(stderr, "请将音频文件放在程序目录中，或直接拖拽文件到程序图标上\n");
                return 1;
            }
        }
        
        if (filesToProcess.count == 0) {
            fprintf(stderr, "错误: 没有找到可处理的音频文件\n");
            showUsage(argv[0]);
            return 1;
        }
        
        // 显示待处理文件列表
        if (filesToProcess.count > 1) {
            printf("\n找到 %lu 个文件待处理:\n", (unsigned long)filesToProcess.count);
            for (NSString *file in filesToProcess) {
                printf("  - %s\n", file.lastPathComponent.UTF8String);
            }
        }
        
        // 处理所有文件
        NSInteger successCount = 0;
        NSInteger failCount = 0;
        
        for (NSString *inputFile in filesToProcess) {
            if (processFile(inputFile)) {
                successCount++;
            } else {
                failCount++;
            }
        }
        
        // 显示总结
        if (filesToProcess.count > 1) {
            printf("\n========================================\n");
            printf("处理完成!\n");
            printf("  成功: %ld 个文件\n", (long)successCount);
            if (failCount > 0) {
                printf("  失败: %ld 个文件\n", (long)failCount);
            }
        }
        
        printf("\n程序结束\n");
    }
    return 0;
}
