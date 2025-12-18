#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>

@interface PlayerView : NSView
@property (nonatomic, strong) NSURL *videoURL;
@end

@implementation PlayerView {
    AVPlayer *player;
    AVPlayerLayer *layer;
}

// 1. 允许 View 接收键盘事件 (必须返回 YES)
- (BOOL)acceptsFirstResponder {
    return YES;
}

// 2. 监听按键按下事件
- (void)keyDown:(NSEvent *)event {
    // 36 是回车键 (Return) 的 KeyCode
    if (event.keyCode == 36) {
        // 调用窗口的 toggleFullScreen 方法
        [self.window toggleFullScreen:nil];
    } else {
        // 其他按键交还给系统处理（比如系统提示音）
        [super keyDown:event];
    }
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];

    if (!self.window || !self.videoURL) return;
    if (player) return;

    player = [AVPlayer playerWithURL:self.videoURL];

    layer = [AVPlayerLayer playerLayerWithPlayer:player];
    layer.videoGravity = AVLayerVideoGravityResizeAspect; // 保持比例
    layer.frame = self.bounds;

    self.wantsLayer = YES;
    [self.layer addSublayer:layer];

    [player play];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    if (layer) {
        // 确保全屏切换时，视频层也能跟随调整大小
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

        // 创建窗口
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 960, 540)
                      styleMask:(NSWindowStyleMaskTitled |
                                 NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskResizable | // 必须可调整大小才能全屏
                                 NSWindowStyleMaskMiniaturizable) 
                        backing:NSBackingStoreBuffered
                          defer:NO];
        
        [window setTitle:[filePath lastPathComponent]];
        
        // 3. 设置窗口行为，支持全屏
        [window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];

        PlayerView *view = [[PlayerView alloc]
            initWithFrame:window.contentView.bounds];
        
        view.videoURL = url;
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        window.contentView = view;
        
        // 4. 让 View 成为第一响应者，以便立即接收键盘事件
        [window makeFirstResponder:view];
        
        [window makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];

        [app run];
    }
    return 0;
}
