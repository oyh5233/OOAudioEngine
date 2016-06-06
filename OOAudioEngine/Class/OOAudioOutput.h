//
//  OOAudioOutput.h
//  OOAudioEngine
//
//  Created by oo on 15/12/4.
//  Copyright © 2015年 oo. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "OOAudioEngine.h"

@interface OOAudioOutput : NSObject <OOAudioOutput>
@property (nonatomic, assign, readonly) OOAudioEngineOutputCallback outputCallback;
@property (nonatomic, assign) Float32 v;
@property (nonatomic, assign) AudioStreamBasicDescription asbd;
@end
