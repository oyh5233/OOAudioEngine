//
//  OOAudioEngine.h
//  OOAudioEngine
//
//  Created by oo on 16/3/17.
//  Copyright © 2016年 oo. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

typedef NS_ENUM(NSInteger,OOAudioEngineErrorCode) {
    OOAudioEngineErrorCodeOutputBusExhausted=-100,
    OOAudioEngineErrorCodeInputRequirePermission=-200,
    OOAudioEngineErrorCodeInputPermissionRefused=-300
};

extern const NSString * OOAudioEngineInterruptionBeginNotification;
extern const NSString * OOAudioEngineInterruptionEndNotification;

@protocol OOAudioEngineElement <NSObject>

@optional

- (void)interruptionBegin;

- (void)interruptionEnd;

@end

@class OOAudioEngine;
@protocol OOAudioInput;
@protocol OOAudioOutput;

typedef OSStatus (*OOAudioEngineInputCallback) (__unsafe_unretained id<OOAudioInput> audioInput,
                                                __unsafe_unretained OOAudioEngine    *audioEngine,
                                                const                                AudioTimeStamp *time,
                                                UInt32                               frames,
                                                AudioBufferList                      *audio);

typedef OSStatus (*OOAudioEngineOutputCallback) (__unsafe_unretained id<OOAudioOutput> audioOutput,
                                                 __unsafe_unretained OOAudioEngine     *audioEngine,
                                                 const AudioTimeStamp                  *time,
                                                 UInt32                                frames,
                                                 AudioBufferList                       *audio);

@protocol OOAudioInput <OOAudioEngineElement>

@property (nonatomic, assign, readonly) OOAudioEngineInputCallback inputCallback;

@end

@protocol OOAudioOutput <OOAudioEngineElement>

@property (nonatomic, assign, readonly) OOAudioEngineOutputCallback outputCallback;

@property (nonatomic, assign          ) AudioStreamBasicDescription asbd;

@optional

@property (nonatomic, assign          ) Float32                     volume;

@property (nonatomic, assign          ) Float32                     pan;

@end

@interface OOAudioEngine : NSObject

+ (instancetype)defaultAudioEngine;

- (void)addInput:(id<OOAudioInput>)audioInput complete:(void(^)(NSError * error))complete;

- (void)removeInput:(id<OOAudioInput>)audioInput complete:(void(^)(NSError * error))complete;

- (void)addOutput:(id<OOAudioOutput>)audioOutput complete:(void(^)(NSError * error))complete;

- (void)removeOutput:(id<OOAudioOutput>)audioOutput complete:(void(^)(NSError * error))complete;


@end
