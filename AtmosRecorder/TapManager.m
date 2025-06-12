#import "TapManager.h"

// --- CLASS EXTENSION for Private Properties and Methods ---
@interface TapManager ()
@property (nonatomic, strong) AVPlayerItem *playerItem;
@property (nonatomic, strong, nullable) AVPlayerItem *playerItem_ivar;
@property (nonatomic, strong, nullable) AVAudioFormat *fixedOutputFormat;
@property (nonatomic, strong, nullable) NSURL *outputFileURL_ivar;
@property (nonatomic, copy, nullable) TapRecordingCompletionHandler completionHandler_ivar;

@property (nonatomic, strong, nullable) AVAudioFile *currentOutputFile;
@property (nonatomic, strong, nullable) AVAudioFormat *tapInputDerivedFormat;

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
};

// --- MTAudioProcessingTap C Callbacks ---

static void tap_Init(MTAudioProcessingTapRef tap, void * CM_NULLABLE clientInfo, void * CM_NULLABLE * CM_NONNULL tapStorageOut) {
    NSLog(@"[MTAudioProcessingTap] Init.");
    *tapStorageOut = clientInfo;
}

static void tap_Finalize(MTAudioProcessingTapRef tap) {
    NSLog(@"[MTAudioProcessingTap] Finalize.");
    struct TapClientData *tapData = (struct TapClientData *)MTAudioProcessingTapGetStorage(tap);
    if (tapData && tapData->nonInterleavedABL) {
        NSLog(@"[MTAudioProcessingTap] Finalize: Freeing nonInterleavedABL.");
        for (UInt32 i = 0; i < tapData->nonInterleavedABL->mNumberBuffers; ++i) {
            if (tapData->nonInterleavedABL->mBuffers[i].mData) {
                free(tapData->nonInterleavedABL->mBuffers[i].mData);
            }
        }
        free(tapData->nonInterleavedABL);
        tapData->nonInterleavedABL = NULL;
    }
}

static void tap_Prepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *asbd) {
    NSLog(@"[MTAudioProcessingTap] Prepare. MaxFrames: %ld, Input ASBD: (%.0f Hz, %u ch, FormatID: %x, Flags: %x)",
          (long)maxFrames, asbd->mSampleRate, (unsigned int)asbd->mChannelsPerFrame, (unsigned int)asbd->mFormatID, (unsigned int)asbd->mFormatFlags);

    struct TapClientData *tapData = (struct TapClientData *)MTAudioProcessingTapGetStorage(tap);
    if (!tapData) { NSLog(@"[MTAudioProcessingTap] Prepare: CRITICAL - tapData is NULL."); return; }
    TapManager * __strong strongManager = tapData->manager;
    if (!strongManager) { NSLog(@"[MTAudioProcessingTap] Prepare: CRITICAL - manager is NULL in tapData."); return; }

    tapData->tapInputASBD = *asbd;
    tapData->tapInputASBDIsValid = YES;
    
    strongManager.tapInputDerivedFormat = [[AVAudioFormat alloc] initWithStreamDescription:asbd];
    tapData->processingFormatFromTapASBD = strongManager.tapInputDerivedFormat;

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
                    if (allocationSuccess) NSLog(@"[MTAudioProcessingTap] Prepare: nonInterleavedABL (%u ch) ready for de-interleaving.", numInputChannels);
                }
            }
        }
    }
}

static void tap_Unprepare(MTAudioProcessingTapRef tap) {
    NSLog(@"[MTAudioProcessingTap] Unprepare.");
    struct TapClientData *tapData = (struct TapClientData *)MTAudioProcessingTapGetStorage(tap);
    if (tapData && tapData->nonInterleavedABL) {
        for (UInt32 i = 0; i < tapData->nonInterleavedABL->mNumberBuffers; ++i) {
            if (tapData->nonInterleavedABL->mBuffers[i].mData) {
                free(tapData->nonInterleavedABL->mBuffers[i].mData);
                tapData->nonInterleavedABL->mBuffers[i].mData = NULL;
            }
        }
        free(tapData->nonInterleavedABL);
        tapData->nonInterleavedABL = NULL;
        NSLog(@"[MTAudioProcessingTap] Unprepare: Freed nonInterleavedABL.");
    }
}

// ✅ FIXED: Handles channel count mismatch
static void tap_Process(MTAudioProcessingTapRef tap, CMItemCount numberFrames, MTAudioProcessingTapFlags flags, AudioBufferList *bufferListInOut, CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut) {
    struct TapClientData *tapData = (struct TapClientData *)MTAudioProcessingTapGetStorage(tap);

    if (!tapData) { MTAudioProcessingTapGetSourceAudio(tap,numberFrames,bufferListInOut,flagsOut,NULL,numberFramesOut);*numberFramesOut=0; return; }
    TapManager * __strong strongManager = tapData->manager;
    if (!strongManager) { MTAudioProcessingTapGetSourceAudio(tap,numberFrames,bufferListInOut,flagsOut,NULL,numberFramesOut);*numberFramesOut=0; return; }

    AVAudioFile * __strong fileToWrite = strongManager.currentOutputFile;

    if (!tapData->isRecording || !fileToWrite || !tapData->outputFileFormatToMatch || !tapData->tapInputASBDIsValid) {
        OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, NULL, numberFramesOut);
        if (status != noErr) *numberFramesOut = 0;
        return;
    }

    OSStatus sourceAudioStatus = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, NULL, numberFramesOut);
    if (sourceAudioStatus != noErr || *numberFramesOut == 0) {
        return;
    }
    
    AVAudioPCMBuffer *outputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:tapData->outputFileFormatToMatch
                                                                   frameCapacity:(AVAudioFrameCount)*numberFramesOut];
    outputBuffer.frameLength = (AVAudioFrameCount)*numberFramesOut;

    UInt32 inputNumChannelsFromTap = tapData->tapInputASBD.mChannelsPerFrame;
    UInt32 outputNumChannels = tapData->outputFileFormatToMatch.channelCount;
    BOOL inputIsInterleaved = (tapData->tapInputASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0;
    
    AudioBufferList *sourceABL;

    if (inputIsInterleaved) {
        if (bufferListInOut->mNumberBuffers != 1 || !tapData->nonInterleavedABL || tapData->nonInterleavedABL->mNumberBuffers != inputNumChannelsFromTap) {
            return;
        }
        UInt32 bytesPerSamplePerChannel = (inputNumChannelsFromTap > 0) ? (tapData->tapInputASBD.mBytesPerFrame / inputNumChannelsFromTap) : 0;
        if(bytesPerSamplePerChannel == 0) return;

        float *inputSamples = (float *)bufferListInOut->mBuffers[0].mData;
        for (AVAudioFrameCount frame = 0; frame < *numberFramesOut; ++frame) {
            for (UInt32 ch = 0; ch < inputNumChannelsFromTap; ++ch) {
                ((float *)tapData->nonInterleavedABL->mBuffers[ch].mData)[frame] = inputSamples[frame * inputNumChannelsFromTap + ch];
            }
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
            NSLog(@"[MTAudioProcessingTap] Error writing buffer: %@", writeError.localizedDescription);
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

        memset(&_clientData, 0, sizeof(struct TapClientData));
        _clientData.manager = self;
        _clientData.isRecording = NO;
        _clientData.outputFileFormatToMatch = self.fixedOutputFormat;
        _clientData.outputFile = nil;
        _clientData.processingFormatFromTapASBD = nil;
        _clientData.nonInterleavedABL = NULL;
        _clientData.tapInputASBDIsValid = NO;

        if (![self setupAudioTap]) {
            NSLog(@"[TapManager] CRITICAL ERROR: Failed to setup audio tap during init.");
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
        NSLog(@"[TapManager] Error: Failed to create MTAudioProcessingTap (status: %d).", (int)status);
        _audioTap = NULL;
        return NO;
    }
    NSLog(@"[TapManager] MTAudioProcessingTap created successfully.");
    return YES;
}

// ✅ FIXED: Uses modern asynchronous API to load tracks
- (void)startRecording:(TapRecordingCompletionHandler _Nullable)completion {
    if (_isRecording) {
        NSLog(@"[TapManager] Already recording.");
        if (completion) { completion([NSError errorWithDomain:@"TapManagerErrorDomain" code:101 userInfo:nil]); }
        return;
    }
    if (!_audioTap) {
        NSLog(@"[TapManager] Audio tap not setup.");
        if (completion) { completion([NSError errorWithDomain:@"TapManagerErrorDomain" code:102 userInfo:nil]); }
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
        NSLog(@"[TapManager] Error creating output file: %@", fileError.localizedDescription);
        [self finalizeRecordingProcess:fileError withReason:@"OutputFileCreationError"];
        return;
    }
    _clientData.outputFile = self.currentOutputFile;
    NSLog(@"[TapManager] Output file ready: %@", self.outputFileURL_ivar.lastPathComponent);

    // Asynchronously load audio tracks
    __weak typeof(self) weakSelf = self;
    [self.playerItem_ivar.asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack *> * _Nullable audioTracks, NSError * _Nullable error) {
        // Dispatch to main thread to modify player and playerItem
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) { return; }

            if (error) {
                NSLog(@"[TapManager] Error loading audio tracks: %@", error.localizedDescription);
                [strongSelf finalizeRecordingProcess:error withReason:@"TrackLoadingError"];
                return;
            }

            if (!audioTracks || audioTracks.count == 0) {
                NSLog(@"[TapManager] CRITICAL: No audio tracks found to apply tap.");
                NSError *noTrackError = [NSError errorWithDomain:@"TapManagerErrorDomain" code:103 userInfo:@{NSLocalizedDescriptionKey:@"No audio tracks found in asset."}];
                [strongSelf finalizeRecordingProcess:noTrackError withReason:@"NoTracksFound"];
                return;
            }

            AVMutableAudioMix *audioMix = [AVMutableAudioMix audioMix];
            AVAssetTrack *trackToTap = audioTracks.firstObject;
            AVMutableAudioMixInputParameters *inputParams = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:trackToTap];
            inputParams.audioTapProcessor = strongSelf->_audioTap;
            audioMix.inputParameters = @[inputParams];
            strongSelf.playerItem_ivar.audioMix = audioMix;
            NSLog(@"[TapManager] AudioMix with tap set on playerItem for track ID: %d", trackToTap.trackID);

            strongSelf->_isRecording = YES;
            strongSelf->_clientData.isRecording = YES;

            [[NSNotificationCenter defaultCenter] addObserver:strongSelf selector:@selector(playerItemDidPlayToEndTime:) name:AVPlayerItemDidPlayToEndTimeNotification object:strongSelf.playerItem_ivar];
            [[NSNotificationCenter defaultCenter] addObserver:strongSelf selector:@selector(playerItemFailedToPlayToEndTime:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:strongSelf.playerItem_ivar];
            
            // --- MODIFICATION START ---
            // The original line was: [strongSelf.player play];
            // Setting rate to a non-zero value also starts playback. 2.0f is double speed.
            strongSelf.player.rate = 1.0f;
            // --- MODIFICATION END ---
        });
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

    NSLog(@"[TapManager] Finalizing recording (Reason: %@). Error: %@", reason, potentialError.localizedDescription);

    if (_player && _player.rate > 0.0) {
        [self.player pause];
    }
    _isRecording = NO;
    _clientData.isRecording = NO;

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    if (self.playerItem_ivar) {
        self.playerItem_ivar.audioMix = nil;
        NSLog(@"[TapManager] AudioMix removed.");
    }

    if (self.currentOutputFile) {
        NSLog(@"[TapManager] Closing output file (length: %lld frames).", self.currentOutputFile.length);
        self.currentOutputFile = nil;
        _clientData.outputFile = nil;
        NSLog(@"[TapManager] Output file closed.");
    }
    
    self.tapInputDerivedFormat = nil;

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
    NSLog(@"[TapManager] PlayerItem did play to end.");
    [self finalizeRecordingProcess:nil withReason:@"PlayToEnd"];
}

- (void)playerItemFailedToPlayToEndTime:(NSNotification *)notification {
    NSError *error = notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    NSLog(@"[TapManager] PlayerItem failed to play to end: %@", error.localizedDescription);
    [self finalizeRecordingProcess:error withReason:@"PlayFail"];
}

- (void)dealloc {
    NSLog(@"[TapManager] dealloc.");
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_player && _player.rate > 0.0) { [_player pause]; }
    if (self.playerItem_ivar) { self.playerItem_ivar.audioMix = nil; }
    self.currentOutputFile = nil;
    
    if (_audioTap) {
        _audioTap = NULL;
    }
}

@end
