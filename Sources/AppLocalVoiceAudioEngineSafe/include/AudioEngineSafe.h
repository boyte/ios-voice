#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C exception guard around the AVAudioEngine calls that can throw
/// `NSException` instead of returning an error. Each call returns NO (or nil)
/// when the framework throws; the exception itself is never surfaced because
/// the package keeps provider text out of its public errors and diagnostics.
@interface AppLocalVoiceAudioEngineSafe : NSObject
+ (BOOL)prepare:(AVAudioEngine *)engine;
+ (BOOL)installTapOnNode:(AVAudioInputNode *)node
                     bus:(AVAudioNodeBus)bus
              bufferSize:(AVAudioFrameCount)bufferSize
                  format:(AVAudioFormat * _Nullable)format
                   block:(AVAudioNodeTapBlock)block;
+ (BOOL)removeTapOnNode:(AVAudioInputNode *)node bus:(AVAudioNodeBus)bus;
+ (AVAudioFormat * _Nullable)outputFormatForNode:(AVAudioInputNode *)node
                                               bus:(AVAudioNodeBus)bus;
+ (BOOL)start:(AVAudioEngine *)engine;
@end

NS_ASSUME_NONNULL_END
