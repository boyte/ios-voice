#import "AudioEngineSafe.h"

NSErrorDomain const AppLocalVoiceAudioEngineErrorDomain = @"AppLocalVoice.AudioEngine";

@implementation AppLocalVoiceAudioEngineSafe

+ (NSError *)errorFromException:(NSException *)exception code:(NSInteger)code {
    return [NSError errorWithDomain:AppLocalVoiceAudioEngineErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: exception.name}];
}

+ (BOOL)prepare:(AVAudioEngine *)engine {
    return [self prepare:engine error:nil];
}

+ (BOOL)prepare:(AVAudioEngine *)engine error:(NSError **)error {
    @try { [engine prepare]; return YES; }
    @catch (NSException *exception) {
        if (error) *error = [self errorFromException:exception code:AppLocalVoiceAudioEngineErrorPrepareException];
        return NO;
    }
}

+ (BOOL)installTapOnNode:(AVAudioInputNode *)node bus:(AVAudioNodeBus)bus bufferSize:(AVAudioFrameCount)bufferSize format:(AVAudioFormat *)format block:(AVAudioNodeTapBlock)block {
    return [self installTapOnNode:node bus:bus bufferSize:bufferSize format:format block:block error:nil];
}

+ (BOOL)installTapOnNode:(AVAudioInputNode *)node bus:(AVAudioNodeBus)bus bufferSize:(AVAudioFrameCount)bufferSize format:(AVAudioFormat *)format block:(AVAudioNodeTapBlock)block error:(NSError **)error {
    @try { [node installTapOnBus:bus bufferSize:bufferSize format:format block:block]; return YES; }
    @catch (NSException *exception) {
        if (error) *error = [self errorFromException:exception code:AppLocalVoiceAudioEngineErrorInstallTapException];
        return NO;
    }
}

+ (BOOL)removeTapOnNode:(AVAudioInputNode *)node bus:(AVAudioNodeBus)bus {
    return [self removeTapOnNode:node bus:bus error:nil];
}

+ (BOOL)removeTapOnNode:(AVAudioInputNode *)node bus:(AVAudioNodeBus)bus error:(NSError **)error {
    @try {
        [node removeTapOnBus:bus];
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = [self errorFromException:exception code:AppLocalVoiceAudioEngineErrorRemoveTapException];
        return NO;
    }
}

+ (BOOL)start:(AVAudioEngine *)engine {
    return [self start:engine error:nil];
}

+ (BOOL)start:(AVAudioEngine *)engine error:(NSError **)error {
    @try {
        NSError *startError = nil;
        BOOL result = [engine startAndReturnError:&startError];
        if (!result && error) *error = startError;
        return result;
    } @catch (NSException *exception) {
        if (error) *error = [self errorFromException:exception code:AppLocalVoiceAudioEngineErrorStartException];
        return NO;
    }
}

+ (AVAudioFormat *)outputFormatForNode:(AVAudioInputNode *)node bus:(AVAudioNodeBus)bus {
    return [self outputFormatForNode:node bus:bus error:nil];
}

+ (AVAudioFormat *)outputFormatForNode:(AVAudioInputNode *)node
                                   bus:(AVAudioNodeBus)bus
                                  error:(NSError **)error {
    @try { return [node outputFormatForBus:bus]; }
    @catch (NSException *exception) {
        if (error) *error = [self errorFromException:exception code:AppLocalVoiceAudioEngineErrorOutputFormatException];
        return nil;
    }
}

@end
