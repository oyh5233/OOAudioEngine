//
//  OOAudioOutput.m
//  OOAudioEngine
//
//  Created by oo on 15/12/4.
//  Copyright © 2015年 oo. All rights reserved.
//

#import "OOAudioOutput.h"
OSStatus  liveAudioCallback(__unsafe_unretained OOAudioOutput *THIS,
                            __unsafe_unretained OOAudioEngine  *audioEngine,
                            const AudioTimeStamp               *time,
                            UInt32                             frames,
                            AudioBufferList                    *audio){
    OSStatus status=noErr;
    short * targetBuffer = audio->mBuffers[0].mData;
    for (int i=0;i<frames;i++){
        short frame=(short)(arc4random()%2000)*THIS.v;
        memcpy(targetBuffer+i, &frame,sizeof(short));
    }
    return status;
}
@implementation OOAudioOutput


- (void)interruptionBegin{
    NSLog(@"OOAudioOutput InterruptionBegin");
}

- (void)interruptionEnd{
    NSLog(@"OOAudioOutput InterruptionEnd");
}

- (AudioStreamBasicDescription)asbd{
    AudioStreamBasicDescription asbd;
    asbd.mSampleRate = 16000;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked;
    asbd.mBitsPerChannel = 16;
    asbd.mBytesPerFrame = 2;
    asbd.mChannelsPerFrame = 1;
    asbd.mBytesPerPacket = asbd.mBytesPerFrame * asbd.mChannelsPerFrame;
    asbd.mFramesPerPacket = 1;
    asbd.mReserved = 0;
    return asbd;
}

- (OOAudioEngineOutputCallback)outputCallback{
    return liveAudioCallback;
}
@end
