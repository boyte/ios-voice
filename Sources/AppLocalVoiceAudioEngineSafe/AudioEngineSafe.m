#import "AudioEngineSafe.h"

@implementation AppLocalVoiceAudioEngineSafe

+ (BOOL)prepare:(AVAudioEngine *)engine {
    @try { [engine prepare]; return YES; }
    @catch (NSException *exception) { return NO; }
}

+ (BOOL)installTapOnNode:(AVAudioInputNode *)node bus:(AVAudioNodeBus)bus bufferSize:(AVAudioFrameCount)bufferSize format:(AVAudioFormat *)format block:(AVAudioNodeTapBlock)block {
    @try { [node installTapOnBus:bus bufferSize:bufferSize format:format block:block]; return YES; }
    @catch (NSException *exception) { return NO; }
}

+ (BOOL)removeTapOnNode:(AVAudioInputNode *)node bus:(AVAudioNodeBus)bus {
    @try { [node removeTapOnBus:bus]; return YES; }
    @catch (NSException *exception) { return NO; }
}

+ (BOOL)start:(AVAudioEngine *)engine {
    @try { return [engine startAndReturnError:nil]; }
    @catch (NSException *exception) { return NO; }
}

+ (AVAudioFormat *)outputFormatForNode:(AVAudioInputNode *)node bus:(AVAudioNodeBus)bus {
    @try { return [node outputFormatForBus:bus]; }
    @catch (NSException *exception) { return nil; }
}

@end
