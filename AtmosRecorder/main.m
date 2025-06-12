#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "TapManager.h"
#import <AudioToolbox/AudioToolbox.h>

static BOOL g_processCompletelyFinished = NO;
static NSString *g_outputFilePath = nil;

// 查找目录中第一个适合的音频文件（.m4a或.eac3/.ec3）
NSString* findFirstAudioFile(NSString *directory) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray<NSString *> *contents = [fileManager contentsOfDirectoryAtPath:directory error:&error];
    
    if (error) {
        NSLog(@"[FindFile] Error reading directory '%@': %@", directory, error.localizedDescription);
        return nil;
    }
    
    NSArray<NSString*> *extensions = @[@"m4a", @"eac3", @"ec3"];
    
    for (NSString *item in contents) {
        BOOL isMatchingExtension = NO;
        for (NSString *ext in extensions) {
            if ([item.pathExtension.lowercaseString isEqualToString:ext.lowercaseString]) {
                isMatchingExtension = YES;
                break;
            }
        }
        
        if (isMatchingExtension) {
            return [directory stringByAppendingPathComponent:item];
        }
    }
    return nil;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSLog(@"[Main] Application started.");
        
        NSString *executablePath = [[NSBundle mainBundle] executablePath];
        NSString *executableDir = [executablePath stringByDeletingLastPathComponent];
        NSLog(@"[Main] Program directory: %@", executableDir);
        
        NSString *inPath = findFirstAudioFile(executableDir);
        
        if (!inPath) {
            NSLog(@"[Main] Error: No suitable audio file (.m4a or .eac3/.ec3) found in the program directory.");
            return 1;
        }
        
        NSLog(@"[Main] Found audio file: %@", inPath.lastPathComponent);
        
        NSString *inputBaseName = [inPath.lastPathComponent stringByDeletingPathExtension];
        // 输出将是 12 声道 Atmos 7.1.4
        NSString *outPath = [executableDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_tap_atmos_714.wav", inputBaseName]];
        g_outputFilePath = outPath;
        
        NSURL *inputURL = [NSURL fileURLWithPath:inPath];
        NSURL *outputURL = [NSURL fileURLWithPath:outPath];
        
        AVPlayerItem *playerItem = [AVPlayerItem playerItemWithURL:inputURL];
        if (!playerItem) {
            NSLog(@"[Main] Error: Could not create AVPlayerItem from %@", inputURL.lastPathComponent);
            return 1;
        }
        
        NSLog(@"[Main] AVPlayerItem created for: %@", inputURL.lastPathComponent);
        playerItem.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmVarispeed;
        
        // --- 配置 TAP 输出格式为: 12 声道, Atmos 7.1.4 ---
        double sampleRate = 48000.0;
        UInt32 targetChannelCount = 12;
        AudioChannelLayoutTag layoutTagToUse = kAudioChannelLayoutTag_Atmos_7_1_4;
        AVAudioChannelLayout *targetChannelLayout = nil;
        
        NSLog(@"[Main] Configuring TAP output for %u channels (Layout Tag: %u - Atmos 7.1.4).", targetChannelCount, layoutTagToUse);
        
        AudioChannelLayout layoutStruct;
        memset(&layoutStruct, 0, sizeof(AudioChannelLayout));
        layoutStruct.mChannelLayoutTag = layoutTagToUse;
        targetChannelLayout = [[AVAudioChannelLayout alloc] initWithLayout:&layoutStruct];

        if (!targetChannelLayout) {
            NSLog(@"[Main] CRITICAL Error: Could not create AVAudioChannelLayout for Atmos 7.1.4 (Tag: %u).", layoutTagToUse);
            return 1;
        }
        
        AVAudioFormat *fixedTargetOutputFormat;
        AudioStreamBasicDescription outputASBD;
        memset(&outputASBD, 0, sizeof(outputASBD));
        outputASBD.mSampleRate       = sampleRate;
        outputASBD.mFormatID         = kAudioFormatLinearPCM;
        // MTAudioProcessingTap 通常需要非交错的 Float32
        outputASBD.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved;
        outputASBD.mChannelsPerFrame = targetChannelCount;
        outputASBD.mBitsPerChannel   = 32; // Float32
        outputASBD.mBytesPerPacket   = outputASBD.mBytesPerFrame = (outputASBD.mBitsPerChannel / 8);
        outputASBD.mFramesPerPacket  = 1;
        
        fixedTargetOutputFormat = [[AVAudioFormat alloc] initWithStreamDescription:&outputASBD channelLayout:targetChannelLayout];
        
        if (!fixedTargetOutputFormat) {
            NSLog(@"[Main] CRITICAL Error: Could not create fixed TAP output format for Atmos 7.1.4.");
            return 1;
        }
        NSLog(@"[Main] Target fixed TAP output format: %@", fixedTargetOutputFormat);
        
        // --- TapManager 初始化并开始录制 ---
        __block TapManager *tapManager = [[TapManager alloc] initWithPlayerItem:playerItem
                                                             targetOutputFormat:fixedTargetOutputFormat
                                                                  outputFileURL:outputURL];
        
        if (!tapManager) {
            NSLog(@"[Main] Error: Failed to init TapManager.");
            return 1;
        }
        
        NSLog(@"[Main] TapManager initialized.");
        NSLog(@"[Main] Starting tap recording...");
        
        [tapManager startRecording:^(NSError * _Nullable error) {
            if (error) {
                NSLog(@"[Main] Tap recording and playback FAILED: %@", error.localizedDescription);
            } else {
                NSLog(@"[Main] Tap recording and playback SUCCEEDED/FINISHED.");
            }
            g_processCompletelyFinished = YES; // 通知主运行循环退出
        }];
        
        NSLog(@"[Main] Entering run loop to wait for TapManager to complete...");
        while (!g_processCompletelyFinished && [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]]) {
            // 保持应用存活
        }
        
        NSLog(@"[Main] Exited run loop.");
        NSLog(@"[Main] Process finished by TapManager. Output WAV file: %@", g_outputFilePath);
        
        tapManager = nil;
        NSLog(@"[Main] Application will now exit.");
    }
    return 0;
}
