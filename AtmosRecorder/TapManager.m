#import "TapManager.h"
#import <Accelerate/Accelerate.h>

// 定义日志宏
#ifdef DEBUG
    #define DebugLog(fmt, ...) NSLog(@"[DEBUG] " fmt, ##__VA_ARGS__)
#else
    #define DebugLog(fmt, ...)
#endif

#define InfoLog(fmt, ...) printf(fmt "\n", ##__VA_ARGS__)
#define ErrorLog(fmt, ...) fprintf(stderr, "错误: " fmt "\n", ##__VA_ARGS__)

// --- CLASS EXTENSION for Private Properties and Methods ---
@interface TapManager ()
@property (nonatomic, strong) AVPlayerItem *playerItem;
@property (nonatomic, strong, nullable) AVPlayerItem *playerItem_ivar;
@property (nonatomic, strong, nullable) AVAudioFormat *fixedOutputFormat;
@property (nonatomic, strong, nullable) NSURL *outputFileURL_ivar;
@property (nonatomic, copy, nullable) TapRecordingCompletionHandler completionHandler_ivar;

@property (nonatomic, strong, nullable) AVAudioFile *currentOutputFile;
@property (nonatomic, strong, nullable) AVAudioFormat *tapInputDerivedFormat;
@property (nonatomic, strong, nullable) id timeObserver;

- (BOOL)setupAudioTap;
- (void)finalizeRecordingProcess:(NSError * _Nullable)potentialError withReason:(NSString *)reason;
@end


// Structure to hold data for tap callbacks
struct TapClientData {
    __unsafe_unretained TapManager * _Nullable manager;
    __unsafe_unretained AVAudioFormat * _Nullable processingFormatFromTapASBD;
    __unsafe_unretained AVAudioFormat * _Nullable outputFileFormatToMatch;
    __unsafe_unretained AVAudioFile * _Nullable outputFile;
    
    BOOL isRecording;
    AudioBufferList * _Nullable nonInterleavedABL;
    AudioStreamBasicDescription tapInputASBD;
    BOOL tapInputASBDIsValid;
    
    // 添加重用缓冲区
    AVAudioPCMBuffer * _Nullable reusableOutputBuffer;
    AVAudioFrameCount maxFrameCapacity;
};

// --- MTAudioProcessingTap C Callbacks ---

static void tap_Init(MTAudioProcessingTapRef tap, void * CM_NULLABLE clientInfo, void * CM_NULLABLE * CM_NONNULL tapStorageOut) {
    DebugLog(@"[MTAudioProcessingTap] Init.");
    *tapStorageOut = clientInfo;
}

static void tap_Finalize(MTAudioProcessingTapRef tap) {
    DebugLog(@"[MTAudioProcessingTap] Finalize.");
    struct TapClientData *tapData = (struct TapClientData *)MTAudioProcessingTapGetStorage(tap);
    if (tapData) {
        if (tapData->nonInterleavedABL) {
            DebugLog(@"[MTAudioProcessingTap] Finalize: Freeing nonInterleavedABL.");
            for (UInt32 i = 0; i < tapData->nonInterleavedABL->mNumberBuffers; ++i) {
                if (tapData->nonInterleavedABL->mBuffers[i].mData) {
                    free(tapData->nonInterleavedABL->mBuffers[i].mData);
                }
            }
            free(tapData->nonInterleavedABL);
            tapData->nonInterleavedABL = NULL;
        }
        
        tapData->reusableOutputBuffer = nil;
        tapData->maxFrameCapacity = 0;
    }
}

static void tap_Prepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *asbd) {
    DebugLog(@"[MTAudioProcessingTap] Prepare. MaxFrames: %ld, Input ASBD: (%.0f Hz, %u ch, FormatID: %x, Flags: %x)",
          (long)maxFrames, asbd->mSampleRate, (unsigned int)asbd->mChannelsPerFrame, (unsigned int)asbd->mFormatID, (unsigned int)asbd->mFormatFlags);

    struct TapClientData *tapData = (struct TapClientData *)MTAudioProcessingTapGetStorage(tap);
    if (!tapData) { return; }
    
    TapManager * __strong strongManager = tapData->manager;
    if (!strongManager) { return; }

    tapData->tapInputASBD = *asbd;
    tapData->tapInputASBDIsValid = YES;
    
    strongManager.tapInputDerivedFormat = [[AVAudioFormat alloc] initWithStreamDescription:asbd];
    tapData->processingFormatFromTapASBD = strongManager.tapInputDerivedFormat;

    if (tapData->outputFileFormatToMatch) {
        tapData->reusableOutputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:tapData->outputFileFormatToMatch
                                                                       frameCapacity:(AVAudioFrameCount)maxFrames];
        tapData->maxFrameCapacity = (AVAudioFrameCount)maxFrames;
    }

    BOOL tapIsInterleaved = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0;
    if (tapIsInterleaved && strongManager.fixedOutputFormat && !strongManager.fixedOutputFormat.isInterleaved) {
        if (tapData->nonInterleavedABL == NULL) {
            UInt32 numInputChannels = asbd->mChannelsPerFrame;
            UInt32 bytesPerSamplePerChannel = (numInputChannels > 0) ? (asbd->mBytesPerFrame / numInputChannels) : 0;

            if (numInputChannels > 0 && bytesPerSamplePerChannel > 0) {
                tapData->nonInterleavedABL = (AudioBufferList *)calloc(1, sizeof(AudioBufferList) + (numInputChannels - 1) * sizeof(AudioBuffer));
                if (tapData->nonInterleavedABL) {
                    tapData->nonInterleavedABL->mNumberBuffers = numInputChannels;
                    BOOL allocationSuccess = YES;
                    for (UInt32 i = 0; i < numInputChannels; ++i) {
                        tapData->nonInterleavedABL->mBuffers[i].mNumberChannels = 1;
                        tapData->nonInterleavedABL->mBuffers[i].mDataByteSize = (UInt32)maxFrames * bytesPerSamplePerChannel;
                        tapData->nonInterleavedABL->mBuffers[i].mData = malloc(tapData->nonInterleavedABL->mBuffers[i].mDataByteSize);
                        if (!tapData->nonInterleavedABL->mBuffers[i].mData) {
                            for (UInt32 j = 0; j < i; ++j) free(tapData->nonInterleavedABL->mBuffers[j].mData);
                            free(tapData->nonInterleavedABL);
                            tapData->nonInterleavedABL = NULL;
                            allocationSuccess = NO;
                            break;
                        }
                    }
                }
            }
        }
    }
}

static void tap_Unprepare(MTAudioProcessingTapRef tap) {
    DebugLog(@"[MTAudioProcessingTap] Unprepare.");
    struct TapClientData *tapData = (struct TapClientData *)MTAudioProcessingTapGetStorage(tap);
    if (tapData) {
        if (tapData->nonInterleavedABL) {
            for (UInt32 i = 0; i < tapData->nonInterleavedABL->mNumberBuffers; ++i) {
                if (tapData->nonInterleavedABL->mBuffers[i].mData) {
                    free(tapData->nonInterleavedABL->mBuffers[i].mData);
                    tapData->nonInterleavedABL->mBuffers[i].mData = NULL;
                }
            }
            free(tapData->nonInterleavedABL);
            tapData->nonInterleavedABL = NULL;
        }
        
        tapData->reusableOutputBuffer = nil;
        tapData->maxFrameCapacity = 0;
    }
}

static void tap_Process(MTAudioProcessingTapRef tap, CMItemCount numberFrames, MTAudioProcessingTapFlags flags, AudioBufferList *bufferListInOut, CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut) {
    @autoreleasepool {
        struct TapClientData *tapData = (struct TapClientData *)MTAudioProcessingTapGetStorage(tap);

        if (!tapData) { MTAudioProcessingTapGetSourceAudio(tap,numberFrames,bufferListInOut,flagsOut,NULL,numberFramesOut); *numberFramesOut=0; return; }
        TapManager * __strong strongManager = tapData->manager;
        if (!strongManager) { MTAudioProcessingTapGetSourceAudio(tap,numberFrames,bufferListInOut,flagsOut,NULL,numberFramesOut); *numberFramesOut=0; return; }
        AVAudioFile * __strong fileToWrite = strongManager.currentOutputFile;
        if (!tapData->isRecording || !fileToWrite || !tapData->outputFileFormatToMatch || !tapData->tapInputASBDIsValid) {
            OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, NULL, numberFramesOut);
            if (status != noErr) *numberFramesOut = 0;
            return;
        }

        OSStatus sourceAudioStatus = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, NULL, numberFramesOut);
        if (sourceAudioStatus != noErr || *numberFramesOut == 0) { return; }
        
        AVAudioPCMBuffer *outputBuffer;
        if (tapData->reusableOutputBuffer && tapData->maxFrameCapacity >= *numberFramesOut) {
            outputBuffer = tapData->reusableOutputBuffer;
            outputBuffer.frameLength = (AVAudioFrameCount)*numberFramesOut;
        } else {
            outputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:tapData->outputFileFormatToMatch frameCapacity:(AVAudioFrameCount)*numberFramesOut];
            outputBuffer.frameLength = (AVAudioFrameCount)*numberFramesOut;
        }

        UInt32 inputNumChannelsFromTap = tapData->tapInputASBD.mChannelsPerFrame;
        UInt32 outputNumChannels = tapData->outputFileFormatToMatch.channelCount;
        BOOL inputIsInterleaved = (tapData->tapInputASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0;
        
        AudioBufferList *sourceABL;

        if (inputIsInterleaved) {
            if (bufferListInOut->mNumberBuffers != 1 || !tapData->nonInterleavedABL || tapData->nonInterleavedABL->mNumberBuffers != inputNumChannelsFromTap) { return; }
            
            const float *inputSamples = (const float *)bufferListInOut->mBuffers[0].mData;
            
            for (UInt32 ch = 0; ch < inputNumChannelsFromTap; ++ch) {
                float *outputChannel = (float *)tapData->nonInterleavedABL->mBuffers[ch].mData;
                
                cblas_scopy((int)*numberFramesOut,      // n: 元素数量
                            inputSamples + ch,          // x: 源向量
                            (int)inputNumChannelsFromTap, // incx: 源步长
                            outputChannel,              // y: 目标向量
                            1);                         // incy: 目标步长
            }
            
            sourceABL = tapData->nonInterleavedABL;
        } else {
            if (bufferListInOut->mNumberBuffers != inputNumChannelsFromTap) return;
            sourceABL = bufferListInOut;
        }
        
        UInt32 channelsToCopy = MIN(inputNumChannelsFromTap, outputNumChannels);

        for (UInt32 ch = 0; ch < channelsToCopy; ++ch) {
            if (sourceABL->mBuffers[ch].mData != NULL && outputBuffer.floatChannelData[ch] != NULL) {
                memcpy(outputBuffer.floatChannelData[ch], sourceABL->mBuffers[ch].mData, sourceABL->mBuffers[ch].mDataByteSize);
            }
        }

        if (outputBuffer.frameLength > 0) {
            NSError *writeError = nil;
            if (![fileToWrite writeFromBuffer:outputBuffer error:&writeError]) {
                ErrorLog("写入音频数据失败: %s", writeError.localizedDescription.UTF8String);
            }
        }
    }
}

// --- TapManager Objective-C Implementation ---
@implementation TapManager {
    struct TapClientData _clientData;
    MTAudioProcessingTapRef _audioTap;
}

@synthesize player = _player;
@synthesize isRecording = _isRecording;

- (instancetype)initWithPlayerItem:(AVPlayerItem *)playerItem
                targetOutputFormat:(AVAudioFormat *)targetOutputFormat
                     outputFileURL:(NSURL *)outputFileURL {
    self = [super init];
    if (self) {
        _player = [[AVPlayer alloc] initWithPlayerItem:playerItem];
        self.playerItem_ivar = playerItem;
        self.fixedOutputFormat = targetOutputFormat;
        self.outputFileURL_ivar = outputFileURL;
        _isRecording = NO;

        _clientData.manager = self;
        _clientData.isRecording = NO;
        _clientData.outputFileFormatToMatch = self.fixedOutputFormat;
        _clientData.outputFile = nil;
        _clientData.processingFormatFromTapASBD = nil;
        _clientData.nonInterleavedABL = NULL;
        _clientData.tapInputASBDIsValid = NO;
        _clientData.reusableOutputBuffer = nil;
        _clientData.maxFrameCapacity = 0;

        if (![self setupAudioTap]) {
            ErrorLog("初始化音频处理器失败");
            return nil;
        }
    }
    return self;
}

- (BOOL)setupAudioTap {
    MTAudioProcessingTapCallbacks callbacks;
    callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;
    callbacks.clientInfo = &_clientData;
    callbacks.init = tap_Init;
    callbacks.finalize = tap_Finalize;
    callbacks.prepare = tap_Prepare;
    callbacks.unprepare = tap_Unprepare;
    callbacks.process = tap_Process;

    OSStatus status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &_audioTap);
    if (status != noErr || _audioTap == NULL) {
        ErrorLog("创建 MTAudioProcessingTap 失败 (错误代码: %d)", (int)status);
        _audioTap = NULL;
        return NO;
    }
    DebugLog(@"MTAudioProcessingTap 创建成功");
    return YES;
}

- (void)startRecording:(TapRecordingCompletionHandler _Nullable)completion {
    if (_isRecording) {
        InfoLog("已经在录制中");
        if (completion) {
            completion([NSError errorWithDomain:@"TapManagerErrorDomain"
                                           code:101
                                       userInfo:@{NSLocalizedDescriptionKey:@"已经在录制中"}]);
        }
        return;
    }
    if (!_audioTap) {
        ErrorLog("音频处理器未初始化");
        if (completion) {
            completion([NSError errorWithDomain:@"TapManagerErrorDomain"
                                           code:102
                                       userInfo:@{NSLocalizedDescriptionKey:@"音频处理器未初始化"}]);
        }
        return;
    }
    
    self.completionHandler_ivar = [completion copy];

    NSError *fileError = nil;
    self.currentOutputFile = [[AVAudioFile alloc] initForWriting:self.outputFileURL_ivar
                                                        settings:self.fixedOutputFormat.settings
                                                    commonFormat:self.fixedOutputFormat.commonFormat
                                                     interleaved:self.fixedOutputFormat.isInterleaved
                                                           error:&fileError];
    if (!self.currentOutputFile || fileError) {
        ErrorLog("创建输出文件失败: %s", fileError.localizedDescription.UTF8String);
        [self finalizeRecordingProcess:fileError withReason:@"OutputFileCreationError"];
        return;
    }
    _clientData.outputFile = self.currentOutputFile;
    InfoLog("输出文件准备就绪: %s", self.outputFileURL_ivar.lastPathComponent.UTF8String);

    [self setupProgressMonitoring];

    __weak typeof(self) weakSelf = self;
    [self.playerItem_ivar.asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack *> * _Nullable audioTracks, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) { return; }

            if (error) {
                ErrorLog("加载音频轨道失败: %s", error.localizedDescription.UTF8String);
                [strongSelf finalizeRecordingProcess:error withReason:@"TrackLoadingError"];
                return;
            }

            if (!audioTracks || audioTracks.count == 0) {
                ErrorLog("未找到音频轨道");
                NSError *noTrackError = [NSError errorWithDomain:@"TapManagerErrorDomain"
                                                            code:103
                                                        userInfo:@{NSLocalizedDescriptionKey:@"未找到音频轨道"}];
                [strongSelf finalizeRecordingProcess:noTrackError withReason:@"NoTracksFound"];
                return;
            }

            AVMutableAudioMix *audioMix = [AVMutableAudioMix audioMix];
            AVAssetTrack *trackToTap = audioTracks.firstObject;
            AVMutableAudioMixInputParameters *inputParams = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:trackToTap];
            inputParams.audioTapProcessor = strongSelf->_audioTap;
            audioMix.inputParameters = @[inputParams];
            strongSelf.playerItem_ivar.audioMix = audioMix;
            DebugLog(@"AudioMix with tap set on playerItem for track ID: %d", trackToTap.trackID);

            strongSelf->_isRecording = YES;
            strongSelf->_clientData.isRecording = YES;

            [[NSNotificationCenter defaultCenter] addObserver:strongSelf
                                                     selector:@selector(playerItemDidPlayToEndTime:)
                                                         name:AVPlayerItemDidPlayToEndTimeNotification
                                                       object:strongSelf.playerItem_ivar];
            [[NSNotificationCenter defaultCenter] addObserver:strongSelf
                                                     selector:@selector(playerItemFailedToPlayToEndTime:)
                                                         name:AVPlayerItemFailedToPlayToEndTimeNotification
                                                       object:strongSelf.playerItem_ivar];
            
            InfoLog("开始转换...");
            
            strongSelf.player.volume = 0.0f;
            strongSelf.player.rate = 1.0f;
        });
    }];
}

- (void)setupProgressMonitoring {
    CMTime duration = self.playerItem_ivar.asset.duration;
    Float64 totalSeconds = CMTimeGetSeconds(duration);
    
    if (CMTIME_IS_INVALID(duration) || totalSeconds <= 0) {
        return;
    }
    
    __weak typeof(self) weakSelf = self;
    self.timeObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMake(1, 2)
                                                                  queue:dispatch_get_main_queue()
                                                             usingBlock:^(CMTime time) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.isRecording) return;
        
        Float64 currentSeconds = CMTimeGetSeconds(time);
        float progress = currentSeconds / totalSeconds;
        
        NSTimeInterval remaining = totalSeconds - currentSeconds;
        
        printf("\r处理进度: %.1f%% [", progress * 100);
        
        int barWidth = 30;
        int pos = barWidth * progress;
        for (int i = 0; i < barWidth; ++i) {
            if (i < pos) printf("=");
            else if (i == pos) printf(">");
            else printf(" ");
        }
        
        printf("] 剩余时间: %.0f秒", remaining);
        fflush(stdout);
        
        if (strongSelf.progressHandler) {
            strongSelf.progressHandler(progress, currentSeconds, totalSeconds);
        }
    }];
}

- (void)finalizeRecordingProcess:(NSError * _Nullable)potentialError withReason:(NSString *)reason {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finalizeRecordingProcess:potentialError withReason:reason];
        });
        return;
    }

    static BOOL finalizing = NO;
    if (finalizing) {
        return;
    }
    finalizing = YES;

    DebugLog(@"Finalizing recording (Reason: %@). Error: %@", reason, potentialError.localizedDescription);

    if (self.timeObserver) {
        [self.player removeTimeObserver:self.timeObserver];
        self.timeObserver = nil;
    }

    if (_player && _player.rate > 0.0) {
        [self.player pause];
    }
    _isRecording = NO;
    _clientData.isRecording = NO;

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    if (self.playerItem_ivar) {
        self.playerItem_ivar.audioMix = nil;
        DebugLog(@"AudioMix removed.");
    }

    AVAudioFramePosition fileLength = 0;
    if (self.currentOutputFile) {
        fileLength = self.currentOutputFile.length;
        DebugLog(@"Closing output file (length: %lld frames).", fileLength);
        self.currentOutputFile = nil;
        _clientData.outputFile = nil;
        DebugLog(@"Output file closed.");
    }
    
    _clientData.reusableOutputBuffer = nil;
    _clientData.maxFrameCapacity = 0;
    
    self.tapInputDerivedFormat = nil;

    if (!potentialError) {
        printf("\r处理进度: 100.0%% [==============================] 完成!        \n");
    } else {
        printf("\n");
    }

    if (self.completionHandler_ivar) {
        self.completionHandler_ivar(potentialError);
        self.completionHandler_ivar = nil;
    }
    finalizing = NO;
}

- (void)stopRecording {
    [self finalizeRecordingProcess:nil withReason:@"ManualStop"];
}

- (void)playerItemDidPlayToEndTime:(NSNotification *)notification {
    DebugLog(@"PlayerItem did play to end.");
    [self finalizeRecordingProcess:nil withReason:@"PlayToEnd"];
}

- (void)playerItemFailedToPlayToEndTime:(NSNotification *)notification {
    NSError *error = notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    ErrorLog("播放失败: %s", error.localizedDescription.UTF8String);
    [self finalizeRecordingProcess:error withReason:@"PlayFail"];
}

- (void)dealloc {
    DebugLog(@"TapManager dealloc.");
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    if (self.timeObserver) {
        [_player removeTimeObserver:self.timeObserver];
        self.timeObserver = nil;
    }
    
    if (_player && _player.rate > 0.0) {
        [_player pause];
    }
    
    if (self.playerItem_ivar) {
        self.playerItem_ivar.audioMix = nil;
    }
    
    self.currentOutputFile = nil;
    
    if (_audioTap) {
        CFRelease(_audioTap);
        _audioTap = NULL;
    }
}

@end
