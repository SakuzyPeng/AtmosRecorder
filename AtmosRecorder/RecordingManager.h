#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^RecordingCompletionHandler)(NSError * _Nullable error);

@interface RecordingManager : NSObject

- (void)recordFromPath:(NSString *)inPath
              toPath:(NSString *)outPath
          completion:(RecordingCompletionHandler _Nullable)completion;

- (void)stopRecordingAndEngine;

@end

NS_ASSUME_NONNULL_END
