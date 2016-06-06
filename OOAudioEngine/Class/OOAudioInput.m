//
//  OOAudioInput.m
//  OOAudioEngine
//
//  Created by oo on 15/12/4.
//  Copyright © 2015年 oo. All rights reserved.
//

#import "OOAudioInput.h"
#import "SKP_Silk_SDK_API.h"
//#import "webrtc_vad.h"
#import "noise_suppression.h"
#import <Accelerate/Accelerate.h>

#define oo_audio_input_samplerate 16000

@interface OOAudioInput()
@property (nonatomic, strong) NSMutableData                 *mData;
@property (nonatomic, assign) ExtAudioFileRef               f1;
@property (nonatomic, assign) ExtAudioFileRef               f2;
@property (nonatomic, assign) ExtAudioFileRef               f3;
@property (nonatomic, strong) NSFileHandle                  *f4;
@property (nonatomic, assign) void                          *silk_encoder_state;
@property (nonatomic, assign) SKP_SILK_SDK_EncControlStruct *silk_encoder_control;
@property (nonatomic, assign) void                          *silk_out;
@property (nonatomic, assign) short                         silk_length;
@property (nonatomic, assign) NsHandle                      *webrtc_ns;
@property (nonatomic, assign) void                          *webrtc_floatIn;
@property (nonatomic, assign) void                          *webrtc_floatOut;
@property (assign           ) bool                          isRunning;
@property (nonatomic, strong) NSLock                        *lock;
- (void)didRecevied:(AudioBufferList*)audioBufferList;

@end


OSStatus liveInputCallback (__unsafe_unretained OOAudioInput     *THIS,
                            __unsafe_unretained OOAudioEngine     *audioEngine,
                            const                                 AudioTimeStamp *time,
                            UInt32                                frames,
                            AudioBufferList                       *audio){
    static OSStatus status=noErr;
    [THIS didRecevied:audio];
    return status;
}




@implementation OOAudioInput

- (void)dealloc{
    if (self.silk_encoder_state) {
        free(self.silk_encoder_state);
    }
    if (self.silk_encoder_control) {
        free(self.silk_encoder_control);
    }

    if (self.webrtc_ns){
        WebRtcNs_Free(self.webrtc_ns);
    }
    if (self.webrtc_floatIn) {
        free(self.webrtc_floatIn);
    }
    if (self.webrtc_floatOut) {
        free(self.webrtc_floatOut);
    }
    if (self.silk_out) {
        free(self.silk_out);
    }
}

- (instancetype)init{
    self=[super init];
    if (self) {
        SKP_Silk_SDK_InitEncoder(self.silk_encoder_state,self.silk_encoder_state);
    }
    return self;
}



- (AudioStreamBasicDescription)defaultASBD{
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
- (void)begin{
    [self.lock lock];
    if (self.isRunning) {
        [self.lock unlock];
        return;
    }
    [self openFile];
    self.isRunning=YES;
    [self.lock unlock];
}
- (void)finish{
    [self.lock lock];
    if (!self.isRunning) {
        [self.lock unlock];
        return;
    }
    self.isRunning=NO;
    [self closeFile];
    [self.lock unlock];
}
- (void)closeFile{
    ExtAudioFileDispose(self.f1);
    ExtAudioFileDispose(self.f2);
    ExtAudioFileDispose(self.f3);
    [self.f4 closeFile];
    self.f1=NULL;
    self.f2=NULL;
    self.f3=NULL;
    self.f4=nil;
}
- (void)openFile{
    CFURLRef urlRef=CFURLCreateWithString(CFAllocatorGetDefault(), (__bridge CFStringRef)[self fileForIndex:1], NULL);
    AudioStreamBasicDescription asbd=[self defaultASBD];
    OSStatus result = ExtAudioFileCreateWithURL(urlRef, kAudioFileWAVEType, &asbd,
                                                NULL, kAudioFileFlags_EraseFile, &_f1);
    if (result!=noErr) {
        NSLog(@"ExtAudioFileCreateWithURLError");
    }
    CFRelease(urlRef);
    urlRef=CFURLCreateWithString(CFAllocatorGetDefault(), (__bridge CFStringRef)[self fileForIndex:2], NULL);
    result = ExtAudioFileCreateWithURL(urlRef, kAudioFileWAVEType, &asbd,
                                                NULL, kAudioFileFlags_EraseFile, &_f2);
    if (result!=noErr) {
        NSLog(@"ExtAudioFileCreateWithURLError");
    }
    CFRelease(urlRef);
    urlRef=CFURLCreateWithString(CFAllocatorGetDefault(), (__bridge CFStringRef)[self fileForIndex:3], NULL);
    result = ExtAudioFileCreateWithURL(urlRef, kAudioFileWAVEType, &asbd,
                                                NULL, kAudioFileFlags_EraseFile, &_f3);
    if (result!=noErr) {
        NSLog(@"ExtAudioFileCreateWithURLError");
    }
    CFRelease(urlRef);
    if ([[NSFileManager defaultManager] fileExistsAtPath:[self fileForIndex:4]]) {
           [[NSFileManager defaultManager] createFileAtPath:[self fileForIndex:4] contents:nil attributes:nil];
    }
    self.f4=[NSFileHandle fileHandleForWritingAtPath:[self fileForIndex:4]];
    [self.f4 truncateFileAtOffset:0];
    const char * silk_header="#!SILK_V3";
    [self.f4 writeData:[NSData dataWithBytes:silk_header length:strlen(silk_header)]];
}
- (void)didRecevied:(AudioBufferList*)audioBufferList{
    [self.lock lock];
    if(!self.isRunning){
        [self.lock unlock];
        return;
    }
    [self.mData appendBytes:audioBufferList->mBuffers[0].mData length:audioBufferList->mBuffers[0].mDataByteSize];
    static int packet_size=640;
    static short frame_num=320;
    while (self.mData.length>=packet_size) {
        void * data=malloc(packet_size);
        memcpy(data, [self.mData bytes], packet_size);
        AudioBufferList buffer={0};
        buffer.mNumberBuffers=1;
        buffer.mBuffers[0].mNumberChannels=1;
        buffer.mBuffers[0].mDataByteSize=packet_size;
        buffer.mBuffers[0].mData=data;
        OSStatus result= ExtAudioFileWrite(self.f1, frame_num, &buffer);
        if (result!=noErr) {
            NSLog(@"ExtAudioFileWriteError");
        }
        for (int i=0;i<2;i++){
            [self webrtc_nsFor10ms:self.webrtc_ns frames:(short *)(data+frame_num*i) nFrames:frame_num/2];
        }
        result= ExtAudioFileWrite(self.f3,frame_num, &buffer);
        if (result!=noErr) {
            NSLog(@"ExtAudioFileWriteError");
        }
        _silk_length=1024;
        result=SKP_Silk_SDK_Encode(self.silk_encoder_state, self.silk_encoder_control, data, frame_num, self.silk_out, &_silk_length);
        if(result!=noErr){
            NSLog(@"silk_error:%d",result);
        }
        [self.f4 writeData:[NSData dataWithBytes:&_silk_length length:sizeof(short)]];
        [self.f4 writeData:[NSData dataWithBytes:self.silk_out length:self.silk_length]];
        free(data);
        [self.mData replaceBytesInRange:NSMakeRange(0, packet_size) withBytes:NULL length:0];
    }
    [self.lock unlock];
}


- (void)interruptionBegin{
    NSLog(@"OOAudioInput InterruptionBegin");
}

- (void)interruptionEnd{
    NSLog(@"OOAudioInput InterruptionEnd");
}

//降噪处理

- (void)webrtc_nsFor10ms:(NsHandle *)nsHandle frames:(short *)frames nFrames:(int)nFrames{
    vDSP_vflt16(frames, 1, self.webrtc_floatIn, 1, nFrames);
    WebRtcNs_Process(nsHandle, self.webrtc_floatIn, NULL, self.webrtc_floatOut, NULL);
    vDSP_vfixru16(self.webrtc_floatOut,1,(unsigned short *)frames,1,nFrames);
}

#pragma mark --
#pragma mark -- getter

- (NSMutableData*)mData{
    if (!_mData) {
        _mData=[[NSMutableData alloc]init];
    }
    return _mData;
}

- (NSString*)fileForIndex:(int)index{
    NSString *file;
    switch (index) {
        case 1:
            file=@"1.wav";
            break;
        case 2:
            file=@"2.wav";
            break;
        case 3:
            file=@"3.wav";
            break;
        case 4:
            file=@"4.silk";
            break;
            
        default:
            break;
    }
    return [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject] stringByAppendingPathComponent:file];
}
- (void*)silk_encoder_state{
    if (!_silk_encoder_state) {
        SKP_int32 silk_encoder_size=0;
        int ret=SKP_Silk_SDK_Get_Encoder_Size(&silk_encoder_size);
        if (ret) {
            return nil;
        }
        _silk_encoder_state=malloc(silk_encoder_size);
    }
    return _silk_encoder_state;
}

//- (VadInst*)webrtc_vad{
//    if (!_webrtc_vad) {
//        WebRtcVad_Create(&_webrtc_vad);
//        WebRtcVad_Init(_webrtc_vad);
//        WebRtcVad_set_mode(_webrtc_vad, 2);
//    }
//    return _webrtc_vad;
//}

- (NsHandle*)webrtc_ns{
    if (!_webrtc_ns) {
        WebRtcNs_Create(&_webrtc_ns);
        WebRtcNs_Init(_webrtc_ns, oo_audio_input_samplerate);
        WebRtcNs_set_policy(_webrtc_ns, 0);
    }
    return _webrtc_ns;
}

- (SKP_SILK_SDK_EncControlStruct*)silk_encoder_control{
    if (!_silk_encoder_control) {
        _silk_encoder_control=malloc(sizeof(SKP_SILK_SDK_EncControlStruct));
        _silk_encoder_control->API_sampleRate=oo_audio_input_samplerate;
        _silk_encoder_control->packetSize=320;
        _silk_encoder_control->maxInternalSampleRate=oo_audio_input_samplerate;
        _silk_encoder_control->packetLossPercentage=0;
        _silk_encoder_control->complexity = 1;
        _silk_encoder_control->useInBandFEC = 0;
        _silk_encoder_control->useDTX = 0;
        _silk_encoder_control->bitRate = oo_audio_input_samplerate;
    }
    return _silk_encoder_control;
}

- (void*)silk_out{
    if (!_silk_out) {
        _silk_out=malloc(4096);
    }
    return _silk_out;
}

- (void*)webrtc_floatIn{
    if (!_webrtc_floatIn) {
        _webrtc_floatIn=malloc(4096);
    }
    return _webrtc_floatIn;
}

- (void*)webrtc_floatOut{
    if (!_webrtc_floatOut) {
        _webrtc_floatOut=malloc(4096);
    }
    return _webrtc_floatOut;
}

- (NSLock*)lock{
    if (!_lock) {
        _lock=[[NSLock alloc]init];
    }
    return _lock;
}
- (OOAudioEngineInputCallback)inputCallback{
    return liveInputCallback;
}
@end
