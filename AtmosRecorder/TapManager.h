#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// 定义录制完成后的回调 Block 类型
typedef void (^TapRecordingCompletionHandler)(NSError * _Nullable error);

// 定义进度回调 Block 类型
typedef void (^TapRecordingProgressHandler)(float progress, NSTimeInterval currentTime, NSTimeInterval totalTime);

/**
 * TapManager 类负责使用 MTAudioProcessingTap 从 AVPlayerItem 中提取音频数据，
 * 并将其写入到一个具有指定多声道格式的文件中。
 */
@interface TapManager : NSObject

/// 内部分管理的 AVPlayer 实例，用于播放 PlayerItem。
@property (nonatomic, strong, readonly) AVPlayer *player;

/// 指示当前是否正在录制。
@property (nonatomic, assign, readonly) BOOL isRecording;

/// 进度回调
@property (nonatomic, copy, nullable) TapRecordingProgressHandler progressHandler;

/**
 * 初始化 TapManager。
 *
 * @param playerItem 包含待处理音频的 AVPlayerItem。
 * @param targetOutputFormat 期望的输出文件 AVAudioFormat (例如，12声道 Atmos 格式)。
 * @param outputFileURL 最终输出的 .wav 文件的完整路径 URL。
 * @return TapManager 的一个实例，如果初始化失败则返回 nil。
 */
- (instancetype)initWithPlayerItem:(AVPlayerItem *)playerItem
                targetOutputFormat:(AVAudioFormat *)targetOutputFormat
                     outputFileURL:(NSURL *)outputFileURL;

/**
 * 开始录制过程。
 * TapManager 将会设置 audio tap，开始播放 PlayerItem，并将处理后的音频数据写入文件。
 *
 * @param completion 操作完成（成功或失败）时调用的回调 Block。
 */
- (void)startRecording:(TapRecordingCompletionHandler _Nullable)completion;

/**
 * 手动停止录制过程。
 */
- (void)stopRecording;

@end

NS_ASSUME_NONNULL_END
