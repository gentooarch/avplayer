#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>

@interface PlayerView : NSView
@property (nonatomic, strong) NSURL *videoURL;
@end

@implementation PlayerView {
    AVPlayer *player;
    AVPlayerLayer *layer;
}

// 1. 允许接收键盘事件
- (BOOL)acceptsFirstResponder {
    return YES;
}

// 2. 监听按键
- (void)keyDown:(NSEvent *)event {
    NSString *chars = [event charactersIgnoringModifiers];
    
    // 检测 'q' 键退出
    if ([chars isEqualToString:@"q"]) {
        [NSApp terminate:nil];
    } 
    // 检测回车键 (Key Code 36) 全屏
    else if (event.keyCode == 36) {
        [self.window toggleFullScreen:nil];
    } 
    else {
        [super keyDown:event];
    }
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
        
        // 确保 View 获得焦点以响应键盘
        [window makeFirstResponder:view];
        
        [window makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];

        [app run];
    }
    return 0;
}
