#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

// --- 自定义 Slider 以优化点击体验 (可选，这里直接用原生 NSSlider) ---

@interface PlayerView : NSView
@property (nonatomic, strong) NSURL *videoURL;
@end

@implementation PlayerView {
    AVPlayer *player;
    AVPlayerLayer *layer;
    NSSlider *progressSlider;     // 进度条
    NSTrackingArea *trackingArea; // 鼠标追踪区域
    id timeObserverToken;         // 时间监听器句柄
    BOOL isUserDragging;          // 标记用户是否正在拖动滑块
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    // 初始化进度条
    // 放在底部，高度 20
    progressSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(20, 10, self.bounds.size.width - 40, 20)];
    progressSlider.minValue = 0.0;
    progressSlider.maxValue = 1.0; // 初始值，加载视频后会更新
    progressSlider.doubleValue = 0.0;
    progressSlider.target = self;
    progressSlider.action = @selector(sliderAction:);
    
    // 设置自动调整宽度，保持在底部
    progressSlider.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    
    // 初始透明度为 0 (隐藏)
    progressSlider.alphaValue = 0.0;
    progressSlider.wantsLayer = YES; // 开启 Layer 才能做透明度动画

    [self addSubview:progressSlider];
}

// 1. 允许接收键盘事件
- (BOOL)acceptsFirstResponder {
    return YES;
}

// 2. 键盘控制
- (void)keyDown:(NSEvent *)event {
    NSString *chars = [event charactersIgnoringModifiers];
    unsigned short keyCode = [event keyCode];

    if ([chars isEqualToString:@"q"]) {
        [NSApp terminate:nil];
    } else if (keyCode == 36) { // Enter
        [self.window toggleFullScreen:nil];
    } else if (keyCode == 123) { // Left
        [self seekBySeconds:-10.0];
    } else if (keyCode == 124) { // Right
        [self seekBySeconds:10.0];
    } else {
        [super keyDown:event];
    }
}

// 3. 鼠标移动逻辑 (MPV 风格)
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    
    if (trackingArea) {
        [self removeTrackingArea:trackingArea];
    }
    
    // 追踪整个视图的鼠标移动
    NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited | 
                                    NSTrackingMouseMoved | 
                                    NSTrackingActiveInKeyWindow | 
                                    NSTrackingActiveAlways;
    
    trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                options:options
                                                  owner:self
                                               userInfo:nil];
    [self addTrackingArea:trackingArea];
}

- (void)mouseMoved:(NSEvent *)event {
    // 获取鼠标在视图内的位置
    NSPoint mousePoint = [self convertPoint:[event locationInWindow] fromView:nil];
    
    // 如果鼠标在底部 80 像素区域内，显示进度条
    if (mousePoint.y < 80) {
        [[progressSlider animator] setAlphaValue:1.0];
    } else {
        [[progressSlider animator] setAlphaValue:0.0];
    }
}

// 鼠标移出视图时隐藏
- (void)mouseExited:(NSEvent *)event {
    [[progressSlider animator] setAlphaValue:0.0];
}


// 4. 视频加载与同步
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];

    if (!self.window || !self.videoURL) return;
    if (player) return;

    player = [AVPlayer playerWithURL:self.videoURL];

    layer = [AVPlayerLayer playerLayerWithPlayer:player];
    layer.videoGravity = AVLayerVideoGravityResizeAspect;
    layer.frame = self.bounds;
    
    // 确保进度条在视频层上面
    self.wantsLayer = YES;
    [self.layer insertSublayer:layer atIndex:0]; // 放在最底层

    [self setupTimeObserver];
    [player play];
}

// 监听播放进度 -> 更新 Slider
- (void)setupTimeObserver {
    __weak PlayerView *weakSelf = self;
    
    // 每 0.5 秒回调一次
    timeObserverToken = [player addPeriodicTimeObserverForInterval:CMTimeMake(1, 2)
                                                             queue:dispatch_get_main_queue()
                                                        usingBlock:^(CMTime time) {
        [weakSelf syncSlider];
    }];
}

- (void)syncSlider {
    // 如果用户正在拖动，不要由视频进度来更新 Slider，防止冲突
    NSEvent *currentEvent = [NSApp currentEvent];
    if (currentEvent.type == NSEventTypeLeftMouseDragged) {
        return;
    }

    if (player.currentItem.status == AVPlayerItemStatusReadyToPlay) {
        double current = CMTimeGetSeconds(player.currentTime);
        double duration = CMTimeGetSeconds(player.currentItem.duration);
        
        if (!isnan(duration) && duration > 0) {
            progressSlider.maxValue = duration;
            progressSlider.doubleValue = current;
        }
    }
}

// 用户拖动 Slider -> 跳转视频
- (void)sliderAction:(id)sender {
    if (player.status == AVPlayerStatusReadyToPlay) {
        double newTime = [sender doubleValue];
        CMTime time = CMTimeMakeWithSeconds(newTime, 1000);
        
        [player seekToTime:time toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }
}

// 辅助跳转方法（键盘用）
- (void)seekBySeconds:(Float64)seconds {
    if (!player) return;
    CMTime currentTime = [player currentTime];
    CMTime offset = CMTimeMakeWithSeconds(seconds, 1);
    CMTime newTime = CMTimeAdd(currentTime, offset);
    [player seekToTime:newTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    if (layer) {
        layer.frame = self.bounds;
    }
}

- (void)dealloc {
    if (timeObserverToken) {
        [player removeTimeObserver:timeObserverToken];
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
        
        // 关键：允许窗口接收鼠标移动事件，否则 mouseMoved 不会触发
        [window setAcceptsMouseMovedEvents:YES];

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
