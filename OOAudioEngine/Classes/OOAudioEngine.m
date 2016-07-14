//
//  OOAudioEngine.m
//  OOAudioEngine
//
//  Created by oo on 16/3/17.
//  Copyright © 2016年 oo. All rights reserved.
//

#import "OOAudioEngine.h"
#import "objc/runtime.h"
#import <UIKit/UIKit.h>
static UInt32 const kMaxFramesPerSlice      = 4096;
static UInt32 const kAudioOutputBusMaxCount = 128;
static void * kAsbdChangedContext           =&kAsbdChangedContext;
static void * kVolumeChangedContext         =&kVolumeChangedContext;
static void * kPanChangedContext            =&kPanChangedContext;
static void * kAudioOutputBusKey            =&kAudioOutputBusKey;
static void * kAudioElementInterruptionKey  =&kAudioElementInterruptionKey;
NSString * OOAudioEngineInterruptionBeginNotification=@"OOAudioEngineInterruptionBeginNotification";
NSString * OOAudioEngineInterruptionEndNotification=@"OOAudioEngineInterruptionEndNotification";
#define OOAudioEngineLogEnable false
#define OOAudioEngineCheckResult(result,operation) (OOAudioEngineCheckResult_((result),(operation),strrchr(__FILE__, '/')+1,__LINE__))

static inline void OOAudioEngineError(OSStatus result, const char *operation, const char* file, int line) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-variable"
    int fourCC = CFSwapInt32HostToBig(result);
#pragma clang diagnostic pop
    @autoreleasepool {
        if (OOAudioEngineLogEnable) {
            NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&fourCC);
        }
    }
}

static inline BOOL OOAudioEngineCheckResult_(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        OOAudioEngineError(result, operation, file, line);
        return NO;
    }
    return YES;
}

typedef struct {
    AudioUnitRenderActionFlags *ioActionFlags;
    const AudioTimeStamp       *inTimeStamp;
    UInt32                     inBusNumber;
    UInt32                     inNumberFrames;
    const void                 *this;
    AudioBufferList            *ioData;
}AudioEngineContext;

@interface OOAudioEngine ()

@property (nonatomic, assign ) AUGraph                     auGraph;
@property (nonatomic, assign ) AudioUnit                   ioAudioUnit;
@property (nonatomic, assign ) AudioUnit                   mixerAudioUnit;
@property (nonatomic, assign ) AUNode                      ioNode;
@property (nonatomic, assign ) AUNode                      mixerNode;
@property (nonatomic, assign ) BOOL                        isRunning;
@property (nonatomic, assign ) BOOL                        isInterrupted;
@property (nonatomic, assign ) AudioStreamBasicDescription asbd;
@property (nonatomic, strong ) NSMutableDictionary         *audioInputs;
@property (nonatomic, strong ) NSMutableDictionary         *audioOutputs;
@property (nonatomic, strong ) dispatch_queue_t            queue;
@property (nonatomic, strong ) dispatch_queue_t            operationQueue;
@property (nonatomic, assign ) void                        *operationQueueKey;
@property (nonatomic, strong ) NSMutableArray              *freeBusIdentifiers;
@property (nonatomic, assign ) AudioEngineContext          *input_context;
@end



static void input_callback_apply(const void *_key, const void *_value, void *_context){
    AudioEngineContext *context=_context;
    __unsafe_unretained id<OOAudioInput> audioInput=(__bridge id)_value;
    __unsafe_unretained OOAudioEngine *audioEngine=(__bridge id)context->this;
    OOAudioEngineInputCallback callback=[audioInput inputCallback];
    @autoreleasepool {
            callback(audioInput,audioEngine,context->inTimeStamp,context->inNumberFrames,context->ioData);
    }
}

static OSStatus inputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    __block OSStatus result=noErr;
    __unsafe_unretained OOAudioEngine *THIS = (__bridge OOAudioEngine *)inRefCon;
    dispatch_barrier_sync(THIS.queue, ^{
        AudioBufferList bufferList={0};
        bufferList.mNumberBuffers=1;
        result=AudioUnitRender(THIS.ioAudioUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &bufferList);
        OOAudioEngineCheckResult(result, "AudioUnitRender");
        THIS.input_context->ioActionFlags=ioActionFlags;
        THIS.input_context->inTimeStamp=inTimeStamp;
        THIS.input_context->inBusNumber=inBusNumber;
        THIS.input_context->inNumberFrames=inNumberFrames;
        THIS.input_context->this=(__bridge const void *)THIS;
        THIS.input_context->ioData=&bufferList;
        CFDictionaryApplyFunction((__bridge CFDictionaryRef)THIS.audioInputs, input_callback_apply,THIS.input_context);
    });
    return result;
}

static OSStatus outputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData) {
    __block OSStatus result=noErr;
    __unsafe_unretained OOAudioEngine *THIS=(__bridge id)inRefCon;
    dispatch_barrier_sync(THIS.queue, ^{
        id<OOAudioOutput>audioOutput=THIS.audioOutputs[@(inBusNumber)];
        if (audioOutput) {
            OOAudioEngineOutputCallback callback=[audioOutput outputCallback];
            @autoreleasepool {
                result= callback(audioOutput,THIS,inTimeStamp,inNumberFrames,ioData);
            }
        }else{
            result=kAudioUnitErr_InvalidElement;
        }
    });
    return result;
}

@implementation OOAudioEngine

- (instancetype)init{
    self=[super init];
    if (self) {
        self.asbd=[self defaultASBD];
        self.input_context=malloc(sizeof(AudioEngineContext));
        self.operationQueueKey=&_operationQueueKey;
        dispatch_queue_set_specific(self.operationQueue, self.operationQueueKey, (__bridge void *)self, NULL);
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(interruption:) name:AVAudioSessionInterruptionNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(routeChange:) name:AVAudioSessionRouteChangeNotification object:nil];
    }
    return self;
}

+ (instancetype)defaultAudioEngine{
    static OOAudioEngine *audioEngine=nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        audioEngine=[[OOAudioEngine alloc]init];
    });
    return audioEngine;
}

#pragma mark --
#pragma mark -- notification

#pragma mark --
#pragma mark -- notification

- (void)interruption:(NSNotification*)nf{
    dispatch_barrier_async(self.operationQueue, ^{
        if([[[nf userInfo]objectForKey:AVAudioSessionInterruptionTypeKey] intValue]==AVAudioSessionInterruptionTypeBegan){
            dispatch_barrier_async(self.operationQueue, ^{
                self.isInterrupted=YES;
            });
        }else{
            if (self.isRunning&&self.isInterrupted) {
                [self start:^(NSError *error) {
                    NSLog(@"%@",error.localizedDescription);
                }];
            }
        }
    });
}

- (void)routeChange:(NSNotification*)nf{
    
}

- (void)applicationWillEnterForeground:(NSNotification*)nf{
    dispatch_barrier_async(self.operationQueue, ^{
        if (self.isRunning&&self.isInterrupted) {
            [self start:^(NSError *error) {
                NSLog(@"%@",error.localizedDescription);
            }];
        }
    });
}

#pragma mark --
#pragma mark -- func

- (void)start:(void(^)(NSError *error))complete{
    void (^block)()=^{
        NSError *error=nil;
        if(self.isRunning){
            if (self.isInterrupted) {
                OSStatus result=AudioOutputUnitStart(self.ioAudioUnit);
                if (!OOAudioEngineCheckResult(result,"AudioOutputUnitStart(self.ioAudioUnit)")) {
                    error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AudioOutputUnitStart(self.ioAudioUnit)"}];
                    self.isRunning=NO;
                    if(complete){
                        complete(error);
                    }
                }else{
                    if (complete) {
                        complete(nil);
                    }
                }
            }else{
                if (complete) {
                    complete(nil);
                }
            }
            self.isInterrupted=NO;
            return;
        }
        if (![self setupAudioSession:&error]) {
            if (complete) {
                complete(error);
            }
            return;
        }
        if (![self startAuGraph:&error]) {
            if (complete) {
                complete(error);
            }
            return;
        }
        self.isRunning=YES;
        if (complete) {
            complete(nil);
        }
    };
    if(dispatch_get_specific(self.operationQueueKey)){
        block();
    }else{
        dispatch_barrier_async(self.operationQueue,  block);
    }
}

- (void)stop:(void(^)(NSError *error))complete{
    void (^block)()=^{
        if (!self.isRunning) {
            if (complete) {
                complete(nil);
            }
            return;
        }
        if (self.auGraph) {
            OSStatus result=AUGraphStop(self.auGraph);
            if (!OOAudioEngineCheckResult(result,"AUGraphStop(self.auGraph)")) {
                if (complete) {
                    complete([NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AUGraphStop(self.auGraph)"}]);
                }
                return;
            }
            result=AUGraphClose(self.auGraph);
            if (!OOAudioEngineCheckResult(result,"AUGraphClose(self.auGraph)")) {
                if (complete) {
                    complete([NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AUGraphClose(self.auGraph)"}]);
                }
                return;
            }
            result=DisposeAUGraph(self.auGraph);
            if(!OOAudioEngineCheckResult(result,"DisposeAUGraph(self.auGraph)")){
                if (complete) {
                    complete([NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"DisposeAUGraph(self.auGraph)"}]);
                }
                return;
            }
            self.auGraph=NULL;
            self.ioAudioUnit=NULL;
            self.mixerAudioUnit=NULL;
            AVAudioSession *audioSession=[AVAudioSession sharedInstance];
            NSError *error=nil;
            if (![audioSession setActive:NO error:&error]) {
                if (complete) {
                    complete(error);
                }
                return;
            }
        }
        self.isRunning=NO;
        if (complete) {
            complete(nil);
        }
    };
    if(dispatch_get_specific(self.operationQueueKey)){
        block();
    }else{
        dispatch_barrier_async(self.operationQueue,  block);
    }
}

- (BOOL)setupAudioSession:(NSError * __autoreleasing *) error{
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    if (![audioSession setActive:YES error:error] ) {
        return NO;
    }
    int options=0;
    options |= AVAudioSessionCategoryOptionDefaultToSpeaker;
    options |= AVAudioSessionCategoryOptionAllowBluetooth;
    options |= AVAudioSessionCategoryOptionMixWithOthers;
    if (![audioSession setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:options error:error]) {
        return NO;
    }
    if ( ![audioSession setPreferredSampleRate:self.asbd.mSampleRate error:error] ) {
        return NO;
    }
    if (![audioSession setPreferredIOBufferDuration:0.01f error:error]) {
        return NO;
    }
    return YES;
}

- (BOOL)startAuGraph:(NSError **)error{
    if (![self setupAuGraph:error]) {
        return NO;
    }
    Boolean isInitialized=NO;
    OSStatus result=AUGraphIsInitialized(self.auGraph, &isInitialized);
    if (!OOAudioEngineCheckResult(result, "AUGraphIsInitialized(self.auGraph, &isInitialized)")) {
        if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AUGraphIsInitialized(self.auGraph, &isInitialized)"}];
        return NO;
    }
    if (!isInitialized) {
        result=AUGraphInitialize(self.auGraph);
        if (!OOAudioEngineCheckResult(result, "AUGraphInitialize(self.auGraph)")){
            if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AUGraphInitialize(self.auGraph)"}];
            return NO;
        }
    }
    Boolean isRunning=NO;
    result=AUGraphIsRunning(self.auGraph, &isRunning);
    if(!OOAudioEngineCheckResult(result,"AUGraphIsRunning(self.auGraph, &isRuning)")){
        if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AUGraphIsRunning(self.auGraph, &isRuning)"}];
        return NO;
    }
    if (!isRunning) {
        result=AUGraphStart(self.auGraph);
        if(!OOAudioEngineCheckResult(result,"AUGraphStart(self.auGraph)")){
            if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AUGraphStart(self.auGraph)"}];
            return NO;
        }
    }
    Boolean isIOAudioUnitRunning;
    UInt32 isIOAudioUnitRunningSize = sizeof(isIOAudioUnitRunning);
    if (!OOAudioEngineCheckResult(AudioUnitGetProperty(_ioAudioUnit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &isIOAudioUnitRunning, &isIOAudioUnitRunningSize), "kAudioOutputUnitProperty_IsRunning") ) {
        return NO;
    }
    if (!isIOAudioUnitRunning) {
        result=AudioOutputUnitStart(self.ioAudioUnit);
        if (!OOAudioEngineCheckResult(result,"AudioOutputUnitStart(self.ioAudioUnit)")) {
            if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AudioOutputUnitStart(self.ioAudioUnit)"}];
            return NO;
        }
    }
    return YES;
}

- (BOOL)setupAuGraph:(NSError **)error{
    if (!self.auGraph) {
        OSStatus result = NewAUGraph(&_auGraph);
        if (!OOAudioEngineCheckResult(result, "NewAUGraph")){
            self.auGraph=NULL;
            if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"NewAUGraph(&self.auGraph)"}];
            return NO;
        }
        AudioComponentDescription io_desc = {
            .componentType = kAudioUnitType_Output,
            .componentSubType =  kAudioUnitSubType_VoiceProcessingIO,
            .componentManufacturer = kAudioUnitManufacturer_Apple,
            .componentFlags = 0,
            .componentFlagsMask = 0
        };
        AudioComponentDescription mixer_desc = {
            .componentType = kAudioUnitType_Mixer,
            .componentSubType =  kAudioUnitSubType_MultiChannelMixer,
            .componentManufacturer = kAudioUnitManufacturer_Apple,
            .componentFlags = 0,
            .componentFlagsMask = 0
        };
        result=AUGraphAddNode(self.auGraph, &io_desc, &_ioNode);
        if (!OOAudioEngineCheckResult(result, "AUGraphAddNode(self.auGraph, &io_desc, &_ioNode)")){
            if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AUGraphAddNode(self.auGraph, &io_desc, &_ioNode)"}];
            return NO;
        }
        result=AUGraphAddNode(self.auGraph, &mixer_desc, &_mixerNode);
        if (!OOAudioEngineCheckResult(result, "AUGraphAddNode(self.auGraph, &mixer_desc, &_mixerNode)") ){
            if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AUGraphAddNode(self.auGraph, &mixer_desc, &_mixerNode)"}];
            return NO;
        }
        result=AUGraphOpen(self.auGraph);
        if (!OOAudioEngineCheckResult(result, "AUGraphOpen(self.auGraph)")){
            if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AUGraphOpen(self.auGraph)"}];
            return NO;
        }
        result=AUGraphNodeInfo(self.auGraph, self.ioNode, NULL, &_ioAudioUnit);
        if (!OOAudioEngineCheckResult(result, "AUGraphNodeInfo(self.auGraph, self.ioNode, NULL, &_ioAudioUnit)") ){
            if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AUGraphNodeInfo(self.auGraph, self.ioNode, NULL, &_ioAudioUnit)"}];
            return NO;
        }
        result=AudioUnitSetProperty(self.ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,1,&_asbd,sizeof(self.asbd));
        if ( !OOAudioEngineCheckResult(result,"AudioUnitSetProperty(self.ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,1,&_asbd,sizeof(self.asbd))")){
            if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AudioUnitSetProperty(self.ioAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,1,&_asbd,sizeof(self.asbd))"}];
            return NO;
        }
        result=AudioUnitSetProperty(self.ioAudioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &kMaxFramesPerSlice, sizeof(kMaxFramesPerSlice));
        if (!OOAudioEngineCheckResult(result, "AudioUnitSetProperty(self.ioAudioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &kMaxFramesPerSlice, sizeof(kMaxFramesPerSlice))")){
            if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AudioUnitSetProperty(self.ioAudioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &kMaxFramesPerSlice, sizeof(kMaxFramesPerSlice))"}];
            return NO;
        }
        result=AUGraphNodeInfo(self.auGraph, self.mixerNode, NULL, &_mixerAudioUnit);
        if (!OOAudioEngineCheckResult(result, "AUGraphNodeInfo(self.auGraph, self.mixerNode, NULL, &_mixerAudioUnit)") ){
            if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AUGraphNodeInfo(self.auGraph, self.mixerNode, NULL, &_mixerAudioUnit)"}];
            return NO;
        }
        result=AudioUnitSetProperty(self.mixerAudioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &kMaxFramesPerSlice, sizeof(kMaxFramesPerSlice));
        if (!OOAudioEngineCheckResult(result, "AudioUnitSetProperty(self.mixerAudioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &kMaxFramesPerSlice, sizeof(kMaxFramesPerSlice))")){
            if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AudioUnitSetProperty(self.mixerAudioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &kMaxFramesPerSlice, sizeof(kMaxFramesPerSlice))"}];
            return NO;
        }
        result=AudioUnitSetProperty(self.mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &kAudioOutputBusMaxCount, sizeof(kAudioOutputBusMaxCount));
        if ( !OOAudioEngineCheckResult(result,"AudioUnitSetProperty(self.mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &kOutputChannelBusMaxCount, sizeof(kOutputChannelBusMaxCount))")){
            if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AudioUnitSetProperty(self.mixerAudioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &kOutputChannelBusMaxCount, sizeof(kOutputChannelBusMaxCount))"}];
            return NO;
        }
        result=AUGraphConnectNodeInput(self.auGraph, self.mixerNode, 0, self.ioNode,0);
        if ( !OOAudioEngineCheckResult(result,"AUGraphConnectNodeInput(self.auGraph, self.mixerNode, 0, self.ioNode,0)")){
            if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AUGraphConnectNodeInput(self.auGraph, self.mixerNode, 0, self.ioNode,0)"}];
            return NO;
        }
    }
    return YES;
}

#pragma mark --
#pragma mark -- config inputEnable
- (void)configIOAudioUnitInputEnabled:(BOOL)inputEnabled complete:(void(^)(NSError *error))complete{
    void (^block)()=^{
        OSStatus result;
        UInt32 isInputEnabled=0;
        UInt32 isInputEnabledSize=sizeof(isInputEnabled);
        result=AudioUnitGetProperty(self.ioAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &isInputEnabled, &isInputEnabledSize);
        if (!OOAudioEngineCheckResult(result, "AudioUnitGetProperty(self.ioAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &isInputEnabled, &isInputEnabledSize)")) {
            if (complete) {
                complete([NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AudioUnitGetProperty(self.ioAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &isInputEnabled, &isInputEnabledSize)"}]);
            }
            return;
        }
        if (isInputEnabled!=inputEnabled) {
            result=AUGraphStop(self.auGraph);
            if (!OOAudioEngineCheckResult(result, "AUGraphStop(self.auGraph)")) {
                if (complete) {
                    complete([NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AUGraphStop(self.auGraph)"}]);
                }
                return;
            }
            result=AUGraphUninitialize(self.auGraph);
            if(!OOAudioEngineCheckResult(result, "AUGraphUninitialize(_audioGraph)")){
                if (complete) {
                    complete([NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AUGraphUninitialize(_audioGraph)"}]);
                }
                return;
            }
            isInputEnabled = inputEnabled;
            result=AudioUnitSetProperty(self.ioAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &isInputEnabled, sizeof(isInputEnabled));
            if(!OOAudioEngineCheckResult(result, "AudioUnitSetProperty(self.ioAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &isInputEnabled, sizeof(isInputEnabled))")){
                if (complete) {
                    complete([NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AudioUnitSetProperty(self.ioAudioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &isInputEnabled, sizeof(isInputEnabled))"}]);
                }
                return;
            }
            if (isInputEnabled) {
                AURenderCallbackStruct inRenderProc;
                inRenderProc.inputProc = &inputCallback;
                inRenderProc.inputProcRefCon = (__bridge void *)self;
                result=AudioUnitSetProperty(self.ioAudioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inRenderProc, sizeof(inRenderProc));
                if(!OOAudioEngineCheckResult(result,"AudioUnitSetProperty(self.ioAudioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inRenderProc, sizeof(inRenderProc))")){
                    if (complete) {
                        complete([NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AudioUnitSetProperty(self.ioAudioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inRenderProc, sizeof(inRenderProc))"}]);
                    }
                    return;
                }
            }
            result=AUGraphInitialize(self.auGraph);
            if (!OOAudioEngineCheckResult(result, "OAUGraphInitialize(self.auGraph)")) {
                if (complete) {
                    complete([NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"OAUGraphInitialize(self.auGraph)"}]);
                }
                return;
            }
            result=AUGraphStart(self.auGraph);
            if (!OOAudioEngineCheckResult(result, "AUGraphStart(self.auGraph)")) {
                if (complete) {
                    complete([NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AUGraphStart(self.auGraph)"}]);
                }
                return;
            }
        }
        if (complete) {
            complete(nil);
        }
    };
    dispatch_barrier_async(self.operationQueue,  block);
}

#pragma mark --
#pragma mark -- busIdentifier

- (void)pushBusIdentifier:(int)identifier{
    [self.freeBusIdentifiers addObject:@(identifier)];
}

- (int)popBusIdentifier{
    NSMutableArray *sorted=[NSMutableArray arrayWithArray:[self.freeBusIdentifiers sortedArrayUsingComparator:^NSComparisonResult(id obj1, id obj2) {
        return [obj1 intValue]<[obj2 intValue]?NSOrderedDescending:NSOrderedSame;
    }]];
    int ret=OOAudioEngineErrorCodeOutputBusExhausted;
    if (sorted.count>0) {
        ret=[[sorted lastObject] intValue];
        [self.freeBusIdentifiers removeObject:[sorted lastObject]];
    }
    return ret;
}

#pragma mark --
#pragma mark -- add bus

- (BOOL)addbus:(UInt32)bus asbd:(AudioStreamBasicDescription)asbd volume:(Float32)volume pan:(Float32)pan error:(NSError**)error{
    AURenderCallbackStruct rcbs = { .inputProc = &outputCallback, .inputProcRefCon = (__bridge void *)self};
    OSStatus result=AUGraphSetNodeInputCallback(self.auGraph, self.mixerNode, bus, &rcbs);
    if(!OOAudioEngineCheckResult(result, "AUGraphSetNodeInputCallback(self.auGraph, self.mixerNode, bus, &rcbs)")){
        if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AUGraphSetNodeInputCallback(self.auGraph, self.mixerNode, bus, &rcbs)"}];
        return NO;
    }
    result=AudioUnitSetProperty(self.mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, bus, &asbd, sizeof(asbd));
    if(!OOAudioEngineCheckResult(result,"AudioUnitSetProperty(self.mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, bus, &asbd, sizeof(asbd))")){
        if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AudioUnitSetProperty(self.mixerAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, bus, &asbd, sizeof(asbd))"}];
        return NO;
    }
    result=AudioUnitSetParameter(self.mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, bus, volume, 0);
    if (!OOAudioEngineCheckResult(result, "AudioUnitSetParameter(self.mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, bus, volume, 0)")) {
        if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AudioUnitSetParameter(self.mixerAudioUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, bus, volume, 0)"}];
        return NO;
    }
    result=AudioUnitSetParameter(self.mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, bus, pan, 0);
    if (!OOAudioEngineCheckResult(result, "AudioUnitSetParameter(self.mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, bus, pan, 0)")) {
        if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AudioUnitSetParameter(self.mixerAudioUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, bus, pan, 0)"}];
        return NO;
    }
    Boolean isupdated=YES;
    result=AUGraphUpdate(self.auGraph, &isupdated);
    if(!OOAudioEngineCheckResult(result, "AUGraphUpdate(self.auGraph, &isupdated)")){
        if (error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AUGraphUpdate(self.auGraph, &isupdated)"}];
        return NO;
    }
    return YES;
}

- (BOOL)removeBus:(UInt32)bus error:(NSError **)error{
    OSStatus result=AUGraphDisconnectNodeInput(self.auGraph, self.mixerNode,bus);
    if (!OOAudioEngineCheckResult(result, "AUGraphDisconnectNodeInput(self.auGraph, self.mixerNode,bus)")) {
        if(error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AUGraphDisconnectNodeInput(self.auGraph, self.mixerNode,bus)"}];
        return NO;
    }
    Boolean isupdated=YES;
    result=AUGraphUpdate(self.auGraph, &isupdated);
    if(!OOAudioEngineCheckResult(result, "AUGraphUpdate(self.auGraph, &isupdated)")){
        if(error) *error=[NSError errorWithDomain:NSStringFromClass(self.class) code:result userInfo:@{NSLocalizedDescriptionKey:@"AUGraphUpdate(self.auGraph, &isupdated)"}];
        return NO;
    }
    return YES;
}

#pragma mark --
#pragma mark -- add remove

- (void)addInput:(id<OOAudioInput>)audioInput complete:(void(^)(NSError * error))complete{
    dispatch_barrier_async(self.queue, ^{
        __block BOOL result=NO;
        __block BOOL didChoose=NO;
        AVAudioSession *audioSession=[AVAudioSession sharedInstance];
        [audioSession requestRecordPermission:^(BOOL granted) {
            result=granted;
            didChoose=YES;
        }];
        if (result) {
            [self start:^(NSError *error) {
                if (error) {
                    if (complete) {
                        dispatch_barrier_async(dispatch_get_main_queue(), ^{
                            complete(error);
                        });
                        
                    }
                    return;
                }
                [self configIOAudioUnitInputEnabled:YES complete:^(NSError *error) {
                    if (error) {
                        if (complete) {
                            dispatch_barrier_async(dispatch_get_main_queue(), ^{
                                 complete(error);
                            });
                           
                        }
                        return;
                    }
                    dispatch_barrier_sync(self.queue, ^{
                        [self setAudioElement:audioInput interruption:NO];
                        [self.audioInputs setObject:audioInput forKey:[NSString stringWithFormat:@"%d",(int)audioInput]];
                        if (complete) {
                            dispatch_barrier_async(dispatch_get_main_queue(), ^{
                                if (complete) {
                                    complete(nil);
                                }
                            });
                        }
                    });
                }];
            }];
        }else{
            if(complete){
                dispatch_barrier_async(dispatch_get_main_queue(), ^{
                    NSError *error=nil;
                    if (didChoose) {
                        error=[NSError errorWithDomain:NSStringFromClass(self.class) code:OOAudioEngineErrorCodeInputRequirePermission userInfo:@{NSLocalizedDescriptionKey:@"user refuse to allow app to record!"}];
 
                    }else{
                       error=[NSError errorWithDomain:NSStringFromClass(self.class) code:OOAudioEngineErrorCodeInputPermissionRefused userInfo:@{NSLocalizedDescriptionKey:@"user should choose if allow app to record!"}];
                    }
                    complete(error);
                });
            }
        }
    });
}

- (void)removeInput:(id<OOAudioInput>)audioInput complete:(void(^)(NSError * error))complete{
    dispatch_barrier_async(self.queue, ^{
        [self.audioInputs removeObjectForKey:[NSString stringWithFormat:@"%d",(int)audioInput]];
        if (self.audioInputs.count==0&&self.audioOutputs.count==0){
            [self stop:^(NSError *error) {
                if (complete) {
                    dispatch_barrier_async(dispatch_get_main_queue(), ^{
                      complete(error);
                    });
                    
                }
            }];
            return;
        }else if (self.audioInputs.count==0) {
            [self configIOAudioUnitInputEnabled:NO complete:^(NSError *error) {
                if (complete) {
                    dispatch_barrier_async(dispatch_get_main_queue(), ^{
                        complete(error);
                    });
                    
                }
            }];
            return;
        }
        if (complete) {
            dispatch_barrier_async(dispatch_get_main_queue(), ^{
                complete(nil);
            });
        }
    });
}

- (void)addOutput:(id<OOAudioOutput>)audioOutput complete:(void(^)(NSError * error))complete{
    dispatch_barrier_async(self.queue, ^{
        NSNumber *key=objc_getAssociatedObject(audioOutput, kAudioOutputBusKey);
        if (key) {
            id exsitAudioOutput = self.audioOutputs[key];
            if (exsitAudioOutput&&exsitAudioOutput==audioOutput) {
                if (complete) {
                    dispatch_barrier_async(dispatch_get_main_queue(), ^{
                        complete(nil);
                    });
                }
                return;
            }
        }
        [self start:^(NSError *error) {
            if (error) {
                if (complete) {
                    dispatch_barrier_async(dispatch_get_main_queue(), ^{
                        complete(error);
                    });
                }
                return;
            }
            dispatch_barrier_sync(self.queue, ^{
                __block int bus=[self popBusIdentifier];
                if (bus==OOAudioEngineErrorCodeOutputBusExhausted) {
                    if (complete) {
                        dispatch_barrier_async(dispatch_get_main_queue(), ^{
                            complete([NSError errorWithDomain:NSStringFromClass(self.class) code:OOAudioEngineErrorCodeOutputBusExhausted userInfo:@{NSLocalizedDescriptionKey:@"output bus is more than max count"}]);
                        });
                    }
                    return;
                }
                AudioStreamBasicDescription asbd=self.asbd;
                if ([audioOutput respondsToSelector:@selector(asbd)]) {
                    asbd=[audioOutput asbd];
                }
                Float32 volume=1;
                if ([audioOutput respondsToSelector:@selector(volume)]) {
                    volume=[audioOutput volume];
                }
                Float32 pan=0;
                if ([audioOutput respondsToSelector:@selector(pan)]) {
                    pan=[audioOutput pan];
                }
                NSError *error=nil;
                if (![self addbus:bus asbd:asbd volume:volume pan:pan error:&error]) {
                    if (complete) {
                        dispatch_barrier_async(dispatch_get_main_queue(), ^{
                            complete(error);
                        });
                    }
                    return;
                }
                [(NSObject*)audioOutput addObserver:self forKeyPath:@"asbd" options:NSKeyValueObservingOptionNew context:kAsbdChangedContext];
                [(NSObject*)audioOutput addObserver:self forKeyPath:@"volume" options:NSKeyValueObservingOptionNew context:kVolumeChangedContext];
                [(NSObject*)audioOutput addObserver:self forKeyPath:@"pan" options:NSKeyValueObservingOptionNew context:kPanChangedContext];
                objc_setAssociatedObject(audioOutput, kAudioOutputBusKey,@(bus), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [self setAudioElement:audioOutput interruption:NO];
                [self.audioOutputs setObject:audioOutput forKey:@(bus)];
                if (complete) {
                    dispatch_barrier_async(dispatch_get_main_queue(), ^{
                        complete(nil);
                    });
                }
            });
        }];
    
        });
}

- (void)removeOutput:(id<OOAudioOutput>)audioOutput complete:(void(^)(NSError * error))complete{
    dispatch_barrier_async(self.queue, ^{
        NSError *error=nil;
        NSNumber *key=objc_getAssociatedObject(audioOutput, kAudioOutputBusKey);
        if (key) {
            id exsitAudioOutput = self.audioOutputs[key];
            if (exsitAudioOutput&&exsitAudioOutput==audioOutput) {
                UInt32 bus=[key intValue];
                [exsitAudioOutput removeObserver:self forKeyPath:@"asbd" context:kAsbdChangedContext];
                [exsitAudioOutput removeObserver:self forKeyPath:@"volume" context:kVolumeChangedContext];
                [exsitAudioOutput removeObserver:self forKeyPath:@"pan" context:kPanChangedContext];
                if (![self removeBus:bus error:&error]) {
                    if (complete) {
                        dispatch_barrier_async(dispatch_get_main_queue(), ^{
                            complete(error);
                        });
                    }
                    return;
                }
                [self pushBusIdentifier:bus];
                [self.audioOutputs removeObjectForKey:key];
                if (self.audioInputs.count==0&&self.audioOutputs.count==0){
                    [self stop:^(NSError *error) {
                        if (complete) {
                            dispatch_barrier_async(dispatch_get_main_queue(), ^{
                                complete(error);
                            });
                        }
                    }];
                }else{
                    if (complete) {
                        dispatch_barrier_async(dispatch_get_main_queue(), ^{
                            complete(nil);
                        });
                    }
                }
            }else{
                if (complete) {
                    dispatch_barrier_async(dispatch_get_main_queue(), ^{
                        complete(nil);
                    });
                }
            }
        }else{
            if (complete) {
                dispatch_barrier_async(dispatch_get_main_queue(), ^{
                    complete(nil);
                });
            }
        }

    });
}




#pragma mark --
#pragma mark -- setter

- (void)setAsbd:(AudioStreamBasicDescription)asbd{
    dispatch_barrier_async(self.operationQueue, ^{
        _asbd=asbd;
        if (self.isRunning) {
            [self stop:^(NSError *error) {
                [self start:nil];
            }];
        }
    });
}

- (void)setAudioElement:(id<OOAudioEngineElement>)audioElement interruption:(BOOL)interruption{
    objc_setAssociatedObject(audioElement, kAudioElementInterruptionKey, @(interruption), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)setIsInterrupted:(BOOL)isInterrupted{
    if (_isInterrupted!=isInterrupted) {
        _isInterrupted=isInterrupted;
        if (_isInterrupted) {
            [[NSNotificationCenter defaultCenter] postNotificationName:OOAudioEngineInterruptionBeginNotification object:nil];
            dispatch_barrier_sync(self.queue, ^{
                [self.audioInputs enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id<OOAudioEngineElement>  _Nonnull obj, BOOL * _Nonnull stop) {
                    [self setAudioElement:obj interruption:YES];
                    if ([obj respondsToSelector:@selector(interruptionBegin)]) {
                        [obj interruptionBegin];
                    }
                }];
                [self.audioOutputs enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id<OOAudioEngineElement>  _Nonnull obj, BOOL * _Nonnull stop) {
                    [self setAudioElement:obj interruption:YES];
                    if ([obj respondsToSelector:@selector(interruptionBegin)]) {
                        [obj interruptionBegin];
                    }
                }];
            });
        }else{
            [[NSNotificationCenter defaultCenter] postNotificationName:OOAudioEngineInterruptionEndNotification object:nil];
            dispatch_barrier_sync(self.queue, ^{
                [self.audioInputs enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id<OOAudioEngineElement>  _Nonnull obj, BOOL * _Nonnull stop) {
                    [self setAudioElement:obj interruption:YES];
                    if ([obj respondsToSelector:@selector(interruptionBegin)]) {
                        [obj interruptionEnd];
                    }
                }];
                [self.audioOutputs enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id<OOAudioEngineElement>  _Nonnull obj, BOOL * _Nonnull stop) {
                    [self setAudioElement:obj interruption:NO];
                    if ([obj respondsToSelector:@selector(interruptionBegin)]) {
                        [obj interruptionEnd];
                    }
                }];
            });
        }
    }
}


#pragma mark --
#pragma mark -- getter

- (BOOL)audioElementInteruption:(id<OOAudioEngineElement>)audioElement{
    return [objc_getAssociatedObject(audioElement, kAudioElementInterruptionKey) boolValue];
}

- (dispatch_queue_t)queue{
    if (!_queue) {
        _queue=dispatch_queue_create("OOAudioEngineQueue", NULL);
    }
    return _queue;
}

- (dispatch_queue_t)operationQueue{
    if (!_operationQueue) {
        _operationQueue=dispatch_queue_create("OOAudioEngineOperationQueue", NULL);
    }
    return _operationQueue;
}

- (NSMutableDictionary*)audioInputs{
    if (!_audioInputs) {
        _audioInputs=[NSMutableDictionary dictionary];
    }
    return _audioInputs;
}

- (NSMutableDictionary*)audioOutputs{
    if (!_audioOutputs) {
        _audioOutputs=[NSMutableDictionary dictionary];
    }
    return _audioOutputs;
}

- (NSMutableArray*)freeBusIdentifiers{
    if (!_freeBusIdentifiers) {
        _freeBusIdentifiers=[NSMutableArray array];
        for(int i=2;i<kAudioOutputBusMaxCount+2;i++){
            [_freeBusIdentifiers addObject:@(i)];
        }
    }
    return _freeBusIdentifiers;
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
@end
