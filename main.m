#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

@interface PlayerView : NSView
@property (nonatomic, strong) NSURL *videoURL;
@end

@implementation PlayerView {
    AVPlayer *player;
    AVPlayerLayer *playerLayer;
    NSSlider *progressSlider;
    NSTrackingArea *trackingArea;
    id timeObserverToken;
    id <NSObject> sleepActivity; // 用来保持系统唤醒（听歌时）
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        player = [[AVPlayer alloc] init];
        
        // 1. 默认先不阻止屏幕休眠，等检测到有视频画面再说
        player.preventsDisplaySleepDuringVideoPlayback = NO; 
        
        // 2. 依然创建 Layer，因为可能随时切换到视频文件
        playerLayer = [AVPlayerLayer playerLayerWithPlayer:player];
        playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        
        self.layer = playerLayer;
        self.wantsLayer = YES;
        
        [self setupUI];
        
        // 3. 监听当前 Item 变化，以便检测是否包含视频轨
        [player addObserver:self forKeyPath:@"currentItem.tracks" options:NSKeyValueObservingOptionNew context:nil];
    }
    return self;
}

- (void)dealloc {
    [player removeObserver:self forKeyPath:@"currentItem.tracks"];
    if (timeObserverToken) [player removeTimeObserver:timeObserverToken];
    [self endSystemSleepActivity];
}

// 4. 核心逻辑：智能判断是“看视频”还是“听音乐”
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"currentItem.tracks"]) {
        NSArray *tracks = player.currentItem.tracks;
        BOOL hasVideo = NO;
        for (AVPlayerItemTrack *track in tracks) {
            if ([track.assetTrack.mediaType isEqualToString:AVMediaTypeVideo]) {
                hasVideo = YES;
                break;
            }
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (hasVideo) {
                // 是视频：阻止屏幕休眠，释放系统休眠锁（AVPlayer 会自动接管）
                self->player.preventsDisplaySleepDuringVideoPlayback = YES;
                [self endSystemSleepActivity];
                NSLog(@"Mode: Video (Keep Display Awake)");
            } else {
                // 是音频：允许屏幕休眠，但手动申请系统不休眠
                self->player.preventsDisplaySleepDuringVideoPlayback = NO;
                [self beginSystemSleepActivity];
                NSLog(@"Mode: Audio (Allow Display Sleep, Prevent System Sleep)");
            }
        });
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

// 手动申请“防止系统睡眠”，让音乐在屏幕关闭后继续播放
- (void)beginSystemSleepActivity {
    if (!sleepActivity) {
        NSActivityOptions options = NSActivityUserInitiated | NSActivityLatencyCritical; 
        sleepActivity = [[NSProcessInfo processInfo] beginActivityWithOptions:options reason:@"Playing Audio"];
    }
}

- (void)endSystemSleepActivity {
    if (sleepActivity) {
        [[NSProcessInfo processInfo] endActivity:sleepActivity];
        sleepActivity = nil;
    }
}

// --- 以下 UI 和控制逻辑保持不变 ---

- (void)setupUI {
    progressSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(20, 10, self.bounds.size.width - 40, 20)];
    progressSlider.minValue = 0.0;
    progressSlider.maxValue = 1.0;
    progressSlider.target = self;
    progressSlider.action = @selector(sliderAction:);
    progressSlider.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    progressSlider.alphaValue = 0.0;
    progressSlider.wantsLayer = YES;
    [self addSubview:progressSlider];
}

- (BOOL)acceptsFirstResponder { return YES; }

- (void)keyDown:(NSEvent *)event {
    unsigned short keyCode = [event keyCode];
    NSString *chars = [event charactersIgnoringModifiers];

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

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (trackingArea) [self removeTrackingArea:trackingArea];
    NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingActiveAlways;
    trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds options:options owner:self userInfo:nil];
    [self addTrackingArea:trackingArea];
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint mousePoint = [self convertPoint:[event locationInWindow] fromView:nil];
    if (mousePoint.y < 80) {
        [[progressSlider animator] setAlphaValue:1.0];
    } else {
        [[progressSlider animator] setAlphaValue:0.0];
    }
}
- (void)mouseExited:(NSEvent *)event {
    [[progressSlider animator] setAlphaValue:0.0];
}

- (void)setVideoURL:(NSURL *)videoURL {
    _videoURL = videoURL;
    if (player) {
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:videoURL];
        [player replaceCurrentItemWithPlayerItem:item];
        [self setupTimeObserver];
        [player play];
    }
}

- (void)setupTimeObserver {
    if (timeObserverToken) {
        [player removeTimeObserver:timeObserverToken];
        timeObserverToken = nil;
    }
    __weak PlayerView *weakSelf = self;
    timeObserverToken = [player addPeriodicTimeObserverForInterval:CMTimeMake(1, 2)
                                                             queue:dispatch_get_main_queue()
                                                        usingBlock:^(CMTime time) {
        [weakSelf syncSlider];
    }];
}

- (void)syncSlider {
    NSEvent *event = [NSApp currentEvent];
    if (event.type == NSEventTypeLeftMouseDragged) return;

    if (player.currentItem.status == AVPlayerItemStatusReadyToPlay) {
        double current = CMTimeGetSeconds(player.currentTime);
        double duration = CMTimeGetSeconds(player.currentItem.duration);
        if (!isnan(duration) && duration > 0) {
            progressSlider.maxValue = duration;
            progressSlider.doubleValue = current;
        }
    }
}

- (void)sliderAction:(id)sender {
    if (player.status == AVPlayerStatusReadyToPlay) {
        [player seekToTime:CMTimeMakeWithSeconds([sender doubleValue], 1000)
           toleranceBefore:kCMTimeZero
            toleranceAfter:kCMTimeZero];
    }
}

- (void)seekBySeconds:(Float64)seconds {
    CMTime newTime = CMTimeAdd(player.currentTime, CMTimeMakeWithSeconds(seconds, 1));
    [player seekToTime:newTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: %s <path/to/media_file_or_url>\n", argv[0]);
            return 1;
        }
        
        NSString *inputArg = [NSString stringWithUTF8String:argv[1]];
        NSURL *url = nil;
        
        // --- 核心修改部分 ---
        // 检查参数是否以 http:// 或 https:// 开头
        if ([inputArg hasPrefix:@"http://"] || [inputArg hasPrefix:@"https://"]) {
            url = [NSURL URLWithString:inputArg];
        } else {
            // 如果不是网络链接，则作为本地文件路径处理
            url = [NSURL fileURLWithPath:inputArg];
        }
        // ------------------

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
        
        [window setTitle:[[url lastPathComponent] stringByDeletingPathExtension]];
        [window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
        [window setAcceptsMouseMovedEvents:YES];
        
        // 视频优化：P3 色域
        [window setColorSpace:[NSColorSpace displayP3ColorSpace]];

        PlayerView *view = [[PlayerView alloc] initWithFrame:window.contentView.bounds];
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [view setVideoURL:url];

        window.contentView = view;
        [window makeFirstResponder:view];
        [window makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];

        [app run];
    }
    return 0;
}
