#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h> // 需要引用这个来处理 CMTime

@interface PlayerView : NSView
@property (nonatomic, strong) NSURL *videoURL;
@end

@implementation PlayerView {
    AVPlayer *player;
    AVPlayerLayer *layer;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)keyDown:(NSEvent *)event {
    NSString *chars = [event charactersIgnoringModifiers];
    unsigned short keyCode = [event keyCode];

    // 'q' 键退出
    if ([chars isEqualToString:@"q"]) {
        [NSApp terminate:nil];
    }
    // 回车键 (36) 全屏
    else if (keyCode == 36) {
        [self.window toggleFullScreen:nil];
    }
    // 左方向键 (123) 后退 10 秒
    else if (keyCode == 123) {
        [self seekBySeconds:-10.0];
    }
    // 右方向键 (124) 前进 10 秒
    else if (keyCode == 124) {
        [self seekBySeconds:10.0];
    }
    else {
        [super keyDown:event];
    }
}

// 辅助方法：处理进度跳转
- (void)seekBySeconds:(Float64)seconds {
    if (!player) return;

    // 获取当前时间
    CMTime currentTime = [player currentTime];
    // 创建要跳转的时间间隔 (timescale 为 1，表示以秒为单位)
    CMTime offset = CMTimeMakeWithSeconds(seconds, 1);
    
    // 计算新时间
    CMTime newTime = CMTimeAdd(currentTime, offset);
    
    // 执行跳转
    // 使用 kCMTimeZero 作为容差可以实现精确跳转，但可能会稍微慢一点点
    // 如果想要更流畅的拖拽感，可以增大容差
    [player seekToTime:newTime 
       toleranceBefore:kCMTimeZero 
        toleranceAfter:kCMTimeZero];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];

    if (!self.window || !self.videoURL) return;
    if (player) return;

    player = [AVPlayer playerWithURL:self.videoURL];

    layer = [AVPlayerLayer playerLayerWithPlayer:player];
    layer.videoGravity = AVLayerVideoGravityResizeAspect;
    layer.frame = self.bounds;

    self.wantsLayer = YES;
    [self.layer addSublayer:layer];

    [player play];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    if (layer) {
        layer.frame = self.bounds;
    }
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: %s <path/to/movie.mp4>\n", argv[0]);
            return 1;
        }

        NSString *filePath = [NSString stringWithUTF8String:argv[1]];
        NSURL *url = [NSURL fileURLWithPath:filePath];

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 960, 540)
                      styleMask:(NSWindowStyleMaskTitled |
                                 NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskResizable |
                                 NSWindowStyleMaskMiniaturizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        
        [window setTitle:[filePath lastPathComponent]];
        [window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];

        PlayerView *view = [[PlayerView alloc]
            initWithFrame:window.contentView.bounds];
        
        view.videoURL = url;
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        window.contentView = view;
        [window makeFirstResponder:view];
        [window makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];

        [app run];
    }
    return 0;
}
