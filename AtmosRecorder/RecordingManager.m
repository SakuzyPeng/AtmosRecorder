#import "RecordingManager.h"

// --- CLASS EXTENSION: All properties are declared here ---
@interface RecordingManager ()
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) AVAudioPlayerNode *playerNode;
@property (nonatomic, strong, nullable) AVAudioFile *outputFile;
@property (nonatomic, assign) BOOL tapInstalledAndBusConfigured;
@property (nonatomic, assign) int consecutiveSilentBuffers;
@property (atomic, assign) BOOL playerHasFinishedSchedulingAtomic;
@property (atomic, assign) BOOL isFinishingRecording; // Flag to prevent re-entry into finishRecording
@property (nonatomic, strong, nullable) dispatch_source_t recordingTimeoutTimer; // For timeout
@property (nonatomic, assign) int debugStepCounter; // For debugging finishRecording flow
@end

// Constants for silence detection and timeout
const int MAX_CONSECUTIVE_SILENT_BUFFERS = 5;     // Stop after 5 silent buffers post-schedule-completion
const float SILENCE_THRESHOLD = 0.0001f;          // Audio samples below this are considered silence
const double RECORDING_TIMEOUT_SECONDS = 10.0;    // Timeout in seconds after player finishes scheduling

@implementation RecordingManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _engine = [[AVAudioEngine alloc] init];
        _playerNode = [[AVAudioPlayerNode alloc] init];
        _outputFile = nil;
        _tapInstalledAndBusConfigured = NO;
        _consecutiveSilentBuffers = 0;
        _playerHasFinishedSchedulingAtomic = NO;
        _isFinishingRecording = NO;
        _recordingTimeoutTimer = nil;
        _debugStepCounter = 0;
    }
    return self;
}

// Helper to cancel existing timer
- (void)cancelTimeoutTimer {
    if (self.recordingTimeoutTimer) {
        NSLog(@"DEBUG: Cancelling recording timeout timer.");
        dispatch_source_cancel(self.recordingTimeoutTimer);
        self.recordingTimeoutTimer = nil;
    }
}

- (void)recordFromPath:(NSString *)inPath
              toPath:(NSString *)outPath
          completion:(RecordingCompletionHandler _Nullable)completion {

    __block NSError *blockError = nil;

    NSLog(@"DEBUG: recordFromPath STARTING. Resetting state.");
    self.consecutiveSilentBuffers = 0;
    self.playerHasFinishedSchedulingAtomic = NO;
    self.isFinishingRecording = NO;
    self.debugStepCounter = 0; // Reset debug counter
    [self cancelTimeoutTimer];

    NSURL *inputFileURL = [NSURL fileURLWithPath:inPath];
    NSURL *outputURL = [NSURL fileURLWithPath:outPath];

    // 1. Prepare Input Audio File
    AVAudioFile *inputFile = [[AVAudioFile alloc] initForReading:inputFileURL error:&blockError];
    if (!inputFile || blockError) {
        NSString *errMsg = [NSString stringWithFormat:@"Failed to load input file: %@", blockError.localizedDescription ?: @"Unknown error"];
        NSLog(@"Error: %@", errMsg);
        if (completion) { completion(blockError); }
        return;
    }
    NSLog(@"Input file loaded: %@, Format: %@", inputFileURL.lastPathComponent, inputFile.processingFormat);

    // 2. Prepare Output Audio File Format
    AVAudioChannelCount outputChannelCount = 2;
    AVAudioCommonFormat outputCommonFormat = AVAudioPCMFormatFloat32;
    BOOL outputInterleaved = NO;
    AVAudioFormat *desiredOutputFormat = [[AVAudioFormat alloc] initWithCommonFormat:outputCommonFormat
                                                                        sampleRate:inputFile.processingFormat.sampleRate
                                                                        channels:outputChannelCount
                                                                        interleaved:outputInterleaved];
    if (!desiredOutputFormat) {
        NSString *errMsg = @"Could not create desired output audio format.";
        NSLog(@"Error: %@", errMsg);
        blockError = [NSError errorWithDomain:@"RecordingManagerErrorDomain" code:1001 userInfo:@{NSLocalizedDescriptionKey:errMsg}];
        if (completion) { completion(blockError); }
        return;
    }
    NSLog(@"Desired output/tap format: %@", desiredOutputFormat);

    // 3. Setup Output File
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:outputURL.path]) {
        if (![fileManager removeItemAtURL:outputURL error:&blockError]) {
            NSString *errMsg = [NSString stringWithFormat:@"Failed to remove existing output file: %@", blockError.localizedDescription ?: @"Unknown error"];
            NSLog(@"Error: %@", errMsg);
            if (completion) { completion(blockError); }
            return;
        }
        NSLog(@"Removed existing output file at: %@", outputURL.path);
    }
    self.outputFile = [[AVAudioFile alloc] initForWriting:outputURL
                                                settings:desiredOutputFormat.settings
                                            commonFormat:desiredOutputFormat.commonFormat
                                             interleaved:desiredOutputFormat.isInterleaved
                                                   error:&blockError];
    if (!self.outputFile || blockError) {
        NSString *errMsg = [NSString stringWithFormat:@"Failed to create output file: %@", blockError.localizedDescription ?: @"Unknown error"];
        NSLog(@"Error: %@", errMsg);
        if (completion) { completion(blockError); }
        return;
    }
    NSLog(@"Output file created: %@", outputURL.lastPathComponent);

    // 4. Configure Audio Engine
    [self.engine attachNode:self.playerNode];
    AVAudioMixerNode *mixer = self.engine.mainMixerNode;
    if (!mixer) {
        NSString *errMsg = @"Main mixer node is nil!";
        NSLog(@"Error: %@", errMsg);
        blockError = [NSError errorWithDomain:@"RecordingManagerErrorDomain" code:1006 userInfo:@{NSLocalizedDescriptionKey:errMsg}];
        if (completion) { completion(blockError); }
        return;
    }

    [self.engine connect:self.playerNode
                      to:mixer
                  format:inputFile.processingFormat];
    NSLog(@"PlayerNode connected to Mixer input bus 0 with format: %@", inputFile.processingFormat);

    // 5. Install Tap
    AVAudioFrameCount bufferSize = 4096;
    __weak RecordingManager *weakSelf = self;

    NSLog(@"Mixer output format for bus 0 (before tap): %@", [mixer outputFormatForBus:0]);

    [mixer installTapOnBus:0
              bufferSize:bufferSize
                  format:desiredOutputFormat
                   block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
        RecordingManager *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.outputFile || !strongSelf.engine.isRunning || strongSelf.isFinishingRecording) {
            if (strongSelf && strongSelf.isFinishingRecording) {
                 NSLog(@"Tap block: Bailing early because isFinishingRecording is YES.");
            }
            return;
        }

        BOOL currentSchedulingStatusInTap = strongSelf.playerHasFinishedSchedulingAtomic;
        NSLog(@"Tap: scheduleDone=%s, silentCount=%d, finishing=%s, frameLen=%u",
              currentSchedulingStatusInTap ? "Y" : "N", strongSelf.consecutiveSilentBuffers,
              strongSelf.isFinishingRecording ? "Y" : "N", buffer.frameLength);

        BOOL isSilent = YES;
        if (buffer.frameLength > 0 && buffer.format.commonFormat == AVAudioPCMFormatFloat32 && buffer.floatChannelData != NULL) {
            for (AVAudioChannelCount ch = 0; ch < buffer.format.channelCount; ++ch) {
                for (AVAudioFramePosition i = 0; i < buffer.frameLength; ++i) {
                    if (fabsf(buffer.floatChannelData[ch][i]) > SILENCE_THRESHOLD) {
                        isSilent = NO;
                        break;
                    }
                }
                if (!isSilent) break;
            }
        } else if (buffer.frameLength == 0) {
            NSLog(@"Tap: Received empty buffer.");
            isSilent = YES;
        }

        if (isSilent) {
            NSLog(@"Tap: Buffer is silent.");
            if (currentSchedulingStatusInTap && !strongSelf.isFinishingRecording) {
                strongSelf.consecutiveSilentBuffers++;
                NSLog(@"Tap: Consecutive silent buffers after schedule completion: %d", strongSelf.consecutiveSilentBuffers);
                if (strongSelf.consecutiveSilentBuffers >= MAX_CONSECUTIVE_SILENT_BUFFERS) {
                    NSLog(@"Tap: Max consecutive silent buffers reached (%d >= %d). Attempting stop via SILENCE.",
                          strongSelf.consecutiveSilentBuffers, MAX_CONSECUTIVE_SILENT_BUFFERS);
                    strongSelf.isFinishingRecording = YES;
                    NSLog(@"Tap: Set isFinishingRecording to YES (silence detection).");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [strongSelf finishRecordingWithCompletion:completion error:nil stopReason:@"SilenceDetection"];
                    });
                }
            }
        } else {
            NSLog(@"Tap: Buffer is not silent.");
            if (currentSchedulingStatusInTap) {
                if (strongSelf.consecutiveSilentBuffers > 0) {
                    NSLog(@"Tap: Non-silent buffer after schedule. Resetting silentCount from %d.", strongSelf.consecutiveSilentBuffers);
                }
                strongSelf.consecutiveSilentBuffers = 0;
            }
        }

        NSError *writeError = nil;
        BOOL writeSuccess = [strongSelf.outputFile writeFromBuffer:buffer error:&writeError];
        if (!writeSuccess) {
            NSLog(@"Error: FAILED to write buffer to output file. Error: %@", writeError.localizedDescription ?: @"Unknown write error");
            if (!strongSelf.isFinishingRecording) {
                strongSelf.isFinishingRecording = YES;
                NSLog(@"Tap: Set isFinishingRecording to YES (write error).");
                dispatch_async(dispatch_get_main_queue(), ^{
                     [strongSelf finishRecordingWithCompletion:completion error:writeError stopReason:@"WriteError"];
                });
            }
        } else {
             NSLog(@"Tap: Successfully wrote buffer. File frameLength now: %lld, Buffer frameLength: %u", strongSelf.outputFile.length, buffer.frameLength);
             if (buffer.frameLength == 0 && currentSchedulingStatusInTap) { // Only log empty writes if schedule done
                 NSLog(@"Tap: Wrote an EMPTY buffer (frameLength 0) after schedule completion.");
             }
        }
    }];
    self.tapInstalledAndBusConfigured = YES;
    NSLog(@"Tap installed. Mixer output format (after tap): %@", [mixer outputFormatForBus:0]);

    // 6. Connect mixer output to physical output
    if (self.tapInstalledAndBusConfigured) {
        [self.engine connect:mixer
                          to:self.engine.outputNode
                      format:desiredOutputFormat];
        NSLog(@"Mixer connected to Engine outputNode.");
    }

    // 7. Prepare and Start Engine
    if (!self.engine.isRunning) {
        @try {
            [self.engine prepare];
            NSLog(@"Engine prepared.");
        } @catch (NSException *exception) {
            NSLog(@"Exception preparing engine: %@", exception.reason);
            blockError = [NSError errorWithDomain:@"RecordingManagerErrorDomain" code:1007 userInfo:@{NSLocalizedDescriptionKey:exception.reason ?: @"Failed to prepare engine"}];
            if (self.tapInstalledAndBusConfigured) { AVAudioMixerNode *m = self.engine.mainMixerNode; if(m) [m removeTapOnBus:0]; self.tapInstalledAndBusConfigured = NO; }
            self.outputFile = nil;
            [self cancelTimeoutTimer];
            if (completion) { completion(blockError); }
            return;
        }
    }

    if (![self.engine startAndReturnError:&blockError]) {
        NSString *errMsg = [NSString stringWithFormat:@"Failed to start audio engine: %@", blockError.localizedDescription ?: @"Unknown error"];
        NSLog(@"Error: %@", errMsg);
        if (self.tapInstalledAndBusConfigured) { AVAudioMixerNode *m = self.engine.mainMixerNode; if(m) [m removeTapOnBus:0]; self.tapInstalledAndBusConfigured = NO; }
        self.outputFile = nil;
        [self cancelTimeoutTimer];
        if (completion) { completion(blockError); }
        return;
    }
    NSLog(@"Audio engine started.");

    // 8. Schedule File and Play
    __weak RecordingManager *weakSelfForScheduleCompletion = self;
    [self.playerNode scheduleFile:inputFile
                           atTime:nil
                completionHandler:^{
        RecordingManager *strongSelf = weakSelfForScheduleCompletion;
        if (!strongSelf) {
            NSLog(@"PlayerNode schedule completion: self is nil.");
            return;
        }

        NSLog(@"PlayerNode finished *scheduling* file. isFinishing: %s", strongSelf.isFinishingRecording ? "Y":"N");
        if (strongSelf.isFinishingRecording) {
            NSLog(@"PlayerNode schedule completion: Already finishing, not starting timeout timer.");
            return;
        }

        strongSelf.playerHasFinishedSchedulingAtomic = YES;
        NSLog(@"Player schedule completion: flag set YES. silentCount: %d", strongSelf.consecutiveSilentBuffers);

        if (!strongSelf.isFinishingRecording && !strongSelf.recordingTimeoutTimer) {
            NSLog(@"DEBUG: Starting recording timeout timer for %.1f seconds.", RECORDING_TIMEOUT_SECONDS);
            strongSelf.recordingTimeoutTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            if (strongSelf.recordingTimeoutTimer) {
                dispatch_source_set_timer(strongSelf.recordingTimeoutTimer,
                                          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RECORDING_TIMEOUT_SECONDS * NSEC_PER_SEC)),
                                          DISPATCH_TIME_FOREVER,
                                          0);
                dispatch_source_set_event_handler(strongSelf.recordingTimeoutTimer, ^{
                    RecordingManager *ssSelf = weakSelfForScheduleCompletion;
                    if (!ssSelf) return;
                    NSLog(@"DEBUG: Recording TIMEOUT reached. isFinishing: %s", ssSelf.isFinishingRecording ? "Y":"N");
                    if (!ssSelf.isFinishingRecording) {
                        // No need to set ssSelf.isFinishingRecording = YES here, finishRecordingWithCompletion will do it.
                        // ssSelf.isFinishingRecording = YES; // This was a potential bug, removed.
                        // NSLog(@"DEBUG: Timer: Set isFinishingRecording to YES."); // Log was tied to above.
                        [ssSelf finishRecordingWithCompletion:completion error:nil stopReason:@"Timeout"];
                    }
                    // Timer should be cancelled within finishRecordingWithCompletion
                });
                dispatch_resume(strongSelf.recordingTimeoutTimer);
            } else {
                 NSLog(@"Error: Could not create recording timeout timer.");
                if(!strongSelf.isFinishingRecording){
                    // No need to set flag here, finishRecording will do it.
                    blockError = [NSError errorWithDomain:@"RecordingManagerErrorDomain" code:1008 userInfo:@{NSLocalizedDescriptionKey:@"Failed to create timeout timer."}];
                    [strongSelf finishRecordingWithCompletion:completion error:blockError stopReason:@"TimerCreationError"];
                }
            }
        } else {
            NSLog(@"DEBUG: Player schedule completion: Not starting timeout timer because already finishing or timer exists.");
        }
    }];
    [self.playerNode play];
    NSLog(@"PlayerNode playing...");
}


- (void)finishRecordingWithCompletion:(RecordingCompletionHandler _Nullable)completion
                                error:(NSError * _Nullable)error
                           stopReason:(NSString *)reason {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishRecordingWithCompletion:completion error:error stopReason:reason];
        });
        return;
    }

    self.debugStepCounter = 1; // Reset for this method
    NSLog(@"DEBUG: (%d) ==> finishRecordingWithCompletion CALLED ON MAIN THREAD (Reason: %@, current isFinishing: %s)", self.debugStepCounter++, reason, self.isFinishingRecording ? "Y":"N");

    if (self.isFinishingRecording) {
        BOOL isTimeoutCall = (reason && [reason isEqualToString:@"Timeout"]);
        BOOL isNewErrorCall = (error != nil); // More robust check might be needed if errors can be "normal"
        
        if (isTimeoutCall) {
            NSLog(@"DEBUG: (%d) finishRecording - Timeout called, proceeding to cancel its timer even if already finishing.", self.debugStepCounter++);
            [self cancelTimeoutTimer];
        }
        // Allow a new error to be reported, or timeout to cleanup, but don't re-execute full cleanup
        if (!isTimeoutCall && !isNewErrorCall) {
             NSLog(@"DEBUG: (%d) finishRecording - Already finishing (isFinishingRecording is YES). Bailing subsequent non-error/non-timeout call (Reason: %@).", self.debugStepCounter++, reason);
            return;
        }
         if (isNewErrorCall && ![reason isEqualToString:@"WriteError"] && ![reason isEqualToString:@"TimerCreationError"]) {
             NSLog(@"DEBUG: (%d) finishRecording - Already finishing, but new error (Reason: %@, Error: %@). Logging and bailing for most.", self.debugStepCounter++, reason, error.localizedDescription);
             // If an error completion is pending from the first call to finish, don't overwrite with nil
             return; // Prevent re-execution of cleanup for general new errors if already finishing
        }
    }
    
    if (!self.isFinishingRecording) { // Only set if not already set (e.g. by tap block)
        self.isFinishingRecording = YES;
        NSLog(@"DEBUG: (%d) finishRecording - Set isFinishingRecording to YES (Reason: %@).", self.debugStepCounter++, reason);
    }


    NSLog(@"DEBUG: (%d) Finishing recording (Reason: %@). Actual execution...", self.debugStepCounter++, reason ?: @"N/A");
    [self cancelTimeoutTimer];
    NSLog(@"DEBUG: (%d) Timeout timer cancelled (if active).", self.debugStepCounter++);


    NSLog(@"DEBUG: (%d) Stopping playerNode.", self.debugStepCounter++);
    [self.playerNode stop];
    NSLog(@"DEBUG: (%d) PlayerNode stopped.", self.debugStepCounter++);
    
    if (self.engine.isRunning) {
        NSLog(@"DEBUG: (%d) Engine IS running, attempting to stop...", self.debugStepCounter++);
        [self.engine stop];
        NSLog(@"DEBUG: (%d) Engine stop command issued. Engine isRunning NOW: %s", self.debugStepCounter++, self.engine.isRunning ? "Y":"N");
    } else {
        NSLog(@"DEBUG: (%d) Engine was NOT running.", self.debugStepCounter++);
    }

    if (self.tapInstalledAndBusConfigured) {
        AVAudioMixerNode *mixer = self.engine.mainMixerNode;
        if (mixer) {
            NSLog(@"DEBUG: (%d) Removing tap.", self.debugStepCounter++);
            [mixer removeTapOnBus:0];
            NSLog(@"DEBUG: (%d) Tap removed.", self.debugStepCounter++);
        }
        self.tapInstalledAndBusConfigured = NO;
    }

    if (self.outputFile) {
        NSLog(@"DEBUG: (%d) Setting outputFile to nil (closing file)...", self.debugStepCounter++);
        self.outputFile = nil;
        NSLog(@"DEBUG: (%d) Output file object set to nil (should be closed and flushed).", self.debugStepCounter++);
    } else {
        NSLog(@"DEBUG: (%d) outputFile was already nil.", self.debugStepCounter++);
    }
    
    NSLog(@"DEBUG: (%d) Resetting state flags.", self.debugStepCounter++);
    self.consecutiveSilentBuffers = 0;
    self.playerHasFinishedSchedulingAtomic = NO;
    // self.isFinishingRecording is reset at the start of a new recordFromPath

    if (completion) {
        if (error) {
            NSLog(@"Recording ended by %@ with error: %@", reason ?: @"Unknown", error.localizedDescription);
            completion(error);
        } else {
            NSLog(@"Recording ended successfully by %@.", reason ?: @"Unknown");
            completion(nil);
        }
    }
    NSLog(@"DEBUG: (%d) finishRecording - METHOD FULLY ENDED (Reason: %@)", self.debugStepCounter++, reason);
}

- (void)finishRecordingWithCompletion:(RecordingCompletionHandler _Nullable)completion error:(NSError * _Nullable)error {
    [self finishRecordingWithCompletion:completion error:error stopReason:@"UnknownExternalCall"];
}

- (void)stopRecordingAndEngine {
    NSLog(@"DEBUG: stopRecordingAndEngine called (user/premature stop).");
    NSError *prematureStopError = [NSError errorWithDomain:@"RecordingManagerErrorDomain"
                                                      code:2000
                                                  userInfo:@{NSLocalizedDescriptionKey:@"Recording stopped prematurely by user."}];
    [self finishRecordingWithCompletion:nil error:prematureStopError stopReason:@"PrematureStopMethod"];
}

@end
