#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - SegmentResourceLoader

@interface SegmentResourceLoader : NSObject <AVAssetResourceLoaderDelegate, NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURL *originalURL;
@property (nonatomic, strong) NSURLSession *session;
// 用于维护 Task 到 LoadingRequest 的映射，支持并发请求
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, AVAssetResourceLoadingRequest *> *pendingRequests;
@property (nonatomic, copy) NSString *contentType;
@property (nonatomic, assign) long long contentLength;
@end

@implementation SegmentResourceLoader

- (instancetype)initWithURL:(NSURL *)url {
    if (self = [super init]) {
        _originalURL = url;
        _pendingRequests = [NSMutableDictionary dictionary];
        
        // --- 核心修改：使用 ephemeral 模式，明确禁止磁盘缓存 ---
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.URLCache = nil; // 禁用 URL 缓存对象
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData; // 忽略本地缓存
        
        // 创建带有 delegate 的 session 以便流式接收数据
        _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    }
    return self;
}

#pragma mark - AVAssetResourceLoaderDelegate

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    
    // 1. 处理内容信息请求 (获取长度和类型)
    if (loadingRequest.contentInformationRequest) {
        [self fillContentInformation:loadingRequest];
        return YES;
    }
    
    // 2. 处理数据请求
    if (loadingRequest.dataRequest) {
        [self processDataRequest:loadingRequest];
        return YES;
    }
    
    return NO;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader
didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    // 如果播放器取消了请求（比如 Seek），我们要停止对应的网络任务
    for (NSURLSessionTask *task in self.pendingRequests.allKeys) {
        if (self.pendingRequests[task] == loadingRequest) {
            [task cancel];
            [self.pendingRequests removeObjectForKey:task];
            break;
        }
    }
}

#pragma mark - Logic

- (void)fillContentInformation:(AVAssetResourceLoadingRequest *)loadingRequest {
    if (self.contentLength > 0) {
        [self fillRequest:loadingRequest];
        return;
    }
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.originalURL];
    request.HTTPMethod = @"HEAD";
    
    // HEAD 请求可以使用简单的 completionHandler，因为它数据量极小
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && [response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            self.contentLength = [httpResponse expectedContentLength];
            self.contentType = httpResponse.MIMEType ?: @"video/mp4";
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self fillRequest:loadingRequest];
            });
        } else {
            [loadingRequest finishLoadingWithError:error];
        }
    }] resume];
}

- (void)fillRequest:(AVAssetResourceLoadingRequest *)request {
    request.contentInformationRequest.byteRangeAccessSupported = YES;
    request.contentInformationRequest.contentType = self.contentType;
    request.contentInformationRequest.contentLength = self.contentLength;
    [request finishLoading];
}

- (void)processDataRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    AVAssetResourceLoadingDataRequest *dataRequest = loadingRequest.dataRequest;
    
    long long offset = dataRequest.requestedOffset;
    NSInteger length = dataRequest.requestedLength;
    
    // 如果正在请求，且之前有 currentOffset，则从 currentOffset 开始
    if (dataRequest.currentOffset != 0) offset = dataRequest.currentOffset;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:self.originalURL];
    NSString *range = [NSString stringWithFormat:@"bytes=%lld-%lld", offset, offset + length - 1];
    [req setValue:range forHTTPHeaderField:@"Range"];
    
    // 创建 Task 并关联到 Request
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:req];
    [self.pendingRequests setObject:loadingRequest forKey:task];
    [task resume];
}

#pragma mark - NSURLSessionDataDelegate (实现流式传输)

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    AVAssetResourceLoadingRequest *loadingRequest = self.pendingRequests[dataTask];
    if (loadingRequest) {
        // --- 核心优化：收到一点数据就立刻塞给播放器，不用存入本地磁盘 ---
        [loadingRequest.dataRequest respondWithData:data];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    AVAssetResourceLoadingRequest *loadingRequest = self.pendingRequests[task];
    if (loadingRequest) {
        if (error) {
            [loadingRequest finishLoadingWithError:error];
        } else {
            [loadingRequest finishLoading];
        }
        [self.pendingRequests removeObjectForKey:task];
    }
}

@end

// PlayerView 和 main 函数部分保持一致，但确保 SegmentResourceLoader 被正确初始化即可。
// (以下代码保持与你提供的内容结构一致，仅确保 PlayerView 的资源设置正确)

#pragma mark - PlayerView (结构保持不变)
@interface PlayerView : NSView
@property (nonatomic, strong) NSURL *videoURL;
@property (nonatomic, strong) SegmentResourceLoader *resourceLoader;
@end

@implementation PlayerView {
    AVPlayer *player;
    AVPlayerLayer *playerLayer;
    NSSlider *progressSlider;
    NSTrackingArea *trackingArea;
    id timeObserverToken;
    id <NSObject> sleepActivity;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        player = [[AVPlayer alloc] init];
        playerLayer = [AVPlayerLayer playerLayerWithPlayer:player];
        playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        self.layer = playerLayer;
        self.wantsLayer = YES;
        [self setupUI];
        [player addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:nil];
        [player addObserver:self forKeyPath:@"currentItem.tracks" options:NSKeyValueObservingOptionNew context:nil];
    }
    return self;
}

- (void)dealloc {
    [player removeObserver:self forKeyPath:@"status"];
    [player removeObserver:self forKeyPath:@"currentItem.tracks"];
    if (timeObserverToken) [player removeTimeObserver:timeObserverToken];
    [self endSystemSleepActivity];
}

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
    if ([event.charactersIgnoringModifiers isEqualToString:@"q"]) {
        [NSApp terminate:nil];
    } else if (keyCode == 49) {
        if (player.rate == 0) [player play]; else [player pause];
    } else if (keyCode == 36) {
        [self.window toggleFullScreen:nil];
    } else if (keyCode == 123) {
        [self seekBySeconds:-10.0];
    } else if (keyCode == 124) {
        [self seekBySeconds:10.0];
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
    if (mousePoint.y < 80) [[progressSlider animator] setAlphaValue:1.0];
    else [[progressSlider animator] setAlphaValue:0.0];
}

- (void)mouseExited:(NSEvent *)event { [[progressSlider animator] setAlphaValue:0.0]; }

- (void)beginSystemSleepActivity {
    if (!sleepActivity) {
        NSActivityOptions options = NSActivityUserInitiated | NSActivityLatencyCritical;
        sleepActivity = [[NSProcessInfo processInfo] beginActivityWithOptions:options reason:@"Playing Media"];
    }
}

- (void)endSystemSleepActivity {
    if (sleepActivity) { [[NSProcessInfo processInfo] endActivity:sleepActivity]; sleepActivity = nil; }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"currentItem.tracks"]) {
        BOOL hasVideo = NO;
        for (AVPlayerItemTrack *track in player.currentItem.tracks) {
            if ([track.assetTrack.mediaType isEqualToString:AVMediaTypeVideo]) { hasVideo = YES; break; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (hasVideo) { self->player.preventsDisplaySleepDuringVideoPlayback = YES; [self endSystemSleepActivity]; }
            else { self->player.preventsDisplaySleepDuringVideoPlayback = NO; [self beginSystemSleepActivity]; }
        });
    } else if ([keyPath isEqualToString:@"status"]) {
        if (player.status == AVPlayerStatusFailed) NSLog(@"Player Failed: %@", player.error);
    }
}

- (void)setVideoURL:(NSURL *)videoURL {
    _videoURL = videoURL;
    self.resourceLoader = [[SegmentResourceLoader alloc] initWithURL:videoURL];
    
    NSURL *assetURL = videoURL;
    if ([videoURL.scheme hasPrefix:@"http"]) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:videoURL resolvingAgainstBaseURL:NO];
        components.scheme = @"streaming";
        assetURL = components.URL;
    }
    
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:assetURL options:nil];
    [asset.resourceLoader setDelegate:self.resourceLoader queue:dispatch_get_main_queue()];
    
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    item.preferredForwardBufferDuration = 5.0; 
    
    [player replaceCurrentItemWithPlayerItem:item];
    [self setupTimeObserver];
    [player play];
}

- (void)setupTimeObserver {
    if (timeObserverToken) [player removeTimeObserver:timeObserverToken];
    __weak typeof(self) weakSelf = self;
    timeObserverToken = [player addPeriodicTimeObserverForInterval:CMTimeMake(1, 10) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) { [weakSelf syncSlider]; }];
}

- (void)syncSlider {
    if ([NSApp currentEvent].type == NSEventTypeLeftMouseDragged) return;
    if (player.currentItem.status == AVPlayerItemStatusReadyToPlay) {
        double current = CMTimeGetSeconds(player.currentTime);
        double duration = CMTimeGetSeconds(player.currentItem.duration);
        if (!isnan(duration) && duration > 0) { progressSlider.maxValue = duration; progressSlider.doubleValue = current; }
    }
}

- (void)sliderAction:(id)sender {
    if (player.status == AVPlayerStatusReadyToPlay) {
        CMTime time = CMTimeMakeWithSeconds([sender doubleValue], 1000);
        [player seekToTime:time toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }
}

- (void)seekBySeconds:(Float64)seconds {
    CMTime newTime = CMTimeAdd(player.currentTime, CMTimeMakeWithSeconds(seconds, 1));
    [player seekToTime:newTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}
@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "Usage: %s <url_or_file>\n", argv[0]); return 1; }
        NSString *inputArg = [NSString stringWithUTF8String:argv[1]];
        NSURL *url = ([inputArg hasPrefix:@"http://"] || [inputArg hasPrefix:@"https://"]) ? [NSURL URLWithString:inputArg] : [NSURL fileURLWithPath:inputArg];
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 960, 540) styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable) backing:NSBackingStoreBuffered defer:NO];
        [window setTitle:[[url lastPathComponent] stringByDeletingPathExtension]];
        window.backgroundColor = [NSColor blackColor];
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
