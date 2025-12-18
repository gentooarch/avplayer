//clang -fobjc-arc -framework Cocoa -framework AVFoundation main.m -o avplayer
#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>

@interface PlayerView : NSView
// 1. 添加一个属性来接收 URL
@property (nonatomic, strong) NSURL *videoURL;
@end

@implementation PlayerView {
    AVPlayer *player;
    AVPlayerLayer *layer;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];

    // 2. 检查是否有 window 以及 videoURL 是否已设置
    if (!self.window || !self.videoURL) return;
    
    // 防止重复初始化
    if (player) return;

    // 3. 使用传入的 videoURL 而不是硬编码路径
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
        // 4. 检查命令行参数
        if (argc < 2) {
            fprintf(stderr, "Usage: %s <path/to/movie.mp4>\n", argv[0]);
            return 1;
        }

        // 5. 获取命令行中的路径参数并转换为 NSURL
        NSString *filePath = [NSString stringWithUTF8String:argv[1]];
        // fileURLWithPath 会自动处理绝对路径，如果传入相对路径需确保当前工作目录正确
        NSURL *url = [NSURL fileURLWithPath:filePath];

        NSApplication *app = [NSApplication sharedApplication];
        
        // 设置应用激活策略，确保运行后窗口能自动前置并获得焦点
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 960, 540)
                      styleMask:(NSWindowStyleMaskTitled |
                                 NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        
        [window setTitle:[filePath lastPathComponent]]; // 可选：把文件名设为窗口标题

        PlayerView *view = [[PlayerView alloc]
            initWithFrame:window.contentView.bounds];
        
        // 6. 将解析出的 URL 传递给 View
        view.videoURL = url;
        
        // 设置 View 的自动调整掩码，保证窗口拉伸时 View 跟随变大
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        window.contentView = view;
        [window makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES]; // 强制前置

        [app run];
    }
    return 0;
}
