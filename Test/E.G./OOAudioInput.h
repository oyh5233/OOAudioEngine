//
//  OOAudioInput.h
//  OOAudioEngine
//
//  Created by oo on 15/12/4.
//  Copyright © 2015年 oo. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "OOAudioEngine.h"
@interface OOAudioInput : NSObject<OOAudioInput>
@property (nonatomic, assign) OOAudioEngineInputCallback inputCallback;
@property (assign, readonly ) bool                       isRunning;

- (void)begin;

- (void)finish;
@end
