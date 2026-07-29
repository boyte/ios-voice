#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const AppLocalVoiceAudioEngineErrorDomain;

typedef NS_ERROR_ENUM(AppLocalVoiceAudioEngineErrorDomain, AppLocalVoiceAudioEngineError) {
    AppLocalVoiceAudioEngineErrorPrepareException = 1,
    AppLocalVoiceAudioEngineErrorInstallTapException = 2,
    AppLocalVoiceAudioEngineErrorStartException = 3,
    AppLocalVoiceAudioEngineErrorRemoveTapException = 4,
    AppLocalVoiceAudioEngineErrorOutputFormatException = 5,
};

@interface AppLocalVoiceAudioEngineSafe : NSObject
+ (BOOL)prepare:(AVAudioEngine *)engine;
+ (BOOL)prepare:(AVAudioEngine *)engine error:(NSError * _Nullable * _Nullable)error;
+ (BOOL)installTapOnNode:(AVAudioInputNode *)node
                     bus:(AVAudioNodeBus)bus
              bufferSize:(AVAudioFrameCount)bufferSize
                  format:(AVAudioFormat * _Nullable)format
                   block:(AVAudioNodeTapBlock)block
                   ;
+ (BOOL)installTapOnNode:(AVAudioInputNode *)node
                     bus:(AVAudioNodeBus)bus
              bufferSize:(AVAudioFrameCount)bufferSize
                  format:(AVAudioFormat * _Nullable)format
                   block:(AVAudioNodeTapBlock)block
                   error:(NSError * _Nullable * _Nullable)error;
+ (BOOL)removeTapOnNode:(AVAudioInputNode *)node bus:(AVAudioNodeBus)bus;
+ (BOOL)removeTapOnNode:(AVAudioInputNode *)node
                    bus:(AVAudioNodeBus)bus
                   error:(NSError * _Nullable * _Nullable)error;
+ (AVAudioFormat * _Nullable)outputFormatForNode:(AVAudioInputNode *)node
                                               bus:(AVAudioNodeBus)bus;
+ (AVAudioFormat * _Nullable)outputFormatForNode:(AVAudioInputNode *)node
                                               bus:(AVAudioNodeBus)bus
                                              error:(NSError * _Nullable * _Nullable)error;
+ (BOOL)start:(AVAudioEngine *)engine;
+ (BOOL)start:(AVAudioEngine *)engine error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
