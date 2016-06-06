//
//  ViewController.m
//  OOAudioEngine
//
//  Created by oo on 15/12/4.
//  Copyright © 2015年 oo. All rights reserved.
//

#import "ViewController.h"
#import "OOAudioInput.h"
#import "OOAudioOutput.h"
@interface OOButton :UIButton

@property (nonatomic, strong)OOAudioInput *audioInput;
@property (nonatomic, strong)OOAudioOutput *audioOutput;

+ (OOButton*)buttonWithAudioInput:(OOAudioInput*)audioInput;
+ (OOButton*)buttonWithAudioOutput:(OOAudioOutput*)audioOutput;
@end

@implementation OOButton

+ (OOButton*)buttonWithAudioInput:(OOAudioInput *)audioInput{
    OOButton *button=[self buttonWithTitle:@"添加输入" selectedTitle:@"移除输入"];
    button.audioInput=audioInput;
    return button;
}

+ (OOButton*)buttonWithAudioOutput:(OOAudioOutput *)audioOutput{
    OOButton *button=[self buttonWithTitle:@"添加输出" selectedTitle:@"移除输出"];
    button.audioOutput=audioOutput;
    return button;
}

+ (OOButton*)buttonWithTitle:(NSString*)title selectedTitle:(NSString*)selectedTitle{
    OOButton * button=[[OOButton alloc]init];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitle:selectedTitle forState:UIControlStateSelected];
    [button setBackgroundColor:[UIColor greenColor]];
    return button;
}
@end
@interface ViewController ()

@property (nonatomic, strong) dispatch_queue_t  queue;

@end

@implementation ViewController
- (void)dealloc{
 }
- (void)viewDidLoad {
    [super viewDidLoad];
    OOButton *button=[OOButton buttonWithAudioInput:[[OOAudioInput alloc]init]];
    [button addTarget:self action:@selector(audioInputClick:) forControlEvents:UIControlEventTouchUpInside];
    button.tag=1000;
    button.frame=CGRectMake(100, 20,(CGRectGetWidth(self.view.frame)-100)/2, 70);
    [self.view addSubview:button];
    for (int i=0;i<5;i++){
        OOAudioOutput *audioOutput=[[OOAudioOutput alloc]init];
        audioOutput.v=i+1;
        OOButton *button=[OOButton buttonWithAudioOutput:audioOutput];
        button.frame=CGRectMake(100, 100+70*i,(CGRectGetWidth(self.view.frame)-100)/2, 70);
        [button addTarget:self action:@selector(audioOutputClick:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:button];
    }
//    [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(click) userInfo:nil repeats:YES];
     // Do any additional setup after loading the view, typically from a nib.
}
- (void)click{
    [self audioInputClick:[self.view viewWithTag:1000]];
}
- (void)audioInputClick:(OOButton*)button{
    button.selected=!button.selected;
    if (button.selected) {
        self.view.userInteractionEnabled=NO;
        [[OOAudioEngine defaultAudioEngine] addInput:button.audioInput complete:^(NSError *error) {
            if (!error) {
                [button.audioInput begin];
            }else{
                button.selected=!button.selected;
            }
            if (error) {
                NSLog(@"%@",error.localizedDescription);
            }
            self.view.userInteractionEnabled=YES;
        }];
    }else{
        self.view.userInteractionEnabled=NO;
        [[OOAudioEngine defaultAudioEngine] removeInput:button.audioInput complete:^(NSError *error) {
            if (!error) {
                [button.audioInput finish];
            }else{
                button.selected=!button.selected;
            }
            if (error) {
                NSLog(@"%@",error.localizedDescription);
            }
            self.view.userInteractionEnabled=YES;
        }];
    }
}
- (void)audioOutputClick:(OOButton*)button{
    button.selected=!button.selected;
    if (button.selected) {
        [[OOAudioEngine defaultAudioEngine] addOutput:button.audioOutput complete:^(NSError *error) {
            if (!error) {
                
            }else{
                button.selected=!button.selected;
            }
            if (error) {
                NSLog(@"%@",error.localizedDescription);
            }
        }];
    }else{
        [[OOAudioEngine defaultAudioEngine] removeOutput:button.audioOutput complete:^(NSError *error) {
            if (!error) {
                
            }else{
                button.selected=!button.selected;
            }
            if (error) {
                NSLog(@"%@",error.localizedDescription);
            }
        }];
    }
}

- (void)audioEngineInterruptionBegin{
    NSLog(@"%@",NSStringFromSelector(_cmd));
}
- (void)audioEngineInterruptionEnd{
    NSLog(@"%@",NSStringFromSelector(_cmd));
}
- (dispatch_queue_t)queue{
    if (!_queue) {
        _queue=dispatch_queue_create("ViewControllerQueue", NULL);
    }
    return _queue;
}
- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

@end
