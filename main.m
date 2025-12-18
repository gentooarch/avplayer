#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

#pragma mark - SegmentResourceLoader

@interface SegmentResourceLoader : NSObject <AVAssetResourceLoaderDelegate>
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSMutableArray *pendingRequests;
@property (nonatomic, assign) NSUInteger segmentSize;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber*, NSData*> *segmentCache;
@end

@implementation SegmentResourceLoader

- (instancetype)initWithURL:(NSURL *)url segmentSize:(NSUInteger)size {
    if (self = [super init]) {
        self.url = url;
        self.segmentSize = size;
        self.pendingRequests = [NSMutableArray array];
        self.segmentCache = [NSMutableDictionary dictionary];
        self.session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    }
    return self;
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    
    @synchronized(self) {
        [self.pendingRequests addObject:loadingRequest];
        [self processRequest:loadingRequest];
    }
    return YES;
}

- (void)processRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    long long offset = loadingRequest.dataRequest.requestedOffset;
    NSNumber *segmentIndex = @(offset / self.segmentSize);
    
    NSData *segmentData = self.segmentCache[segmentIndex];
    if (segmentData) {
        [loadingRequest.dataRequest respondWithData:segmentData];
        [loadingRequest finishLoading];
        [self.pendingRequests removeObject:loadingRequest];
        return;
    }
    
    long long start = segmentIndex.longLongValue * self.segmentSize;
    long long end = start + self.segmentSize - 1;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:self.url];
    NSString *range = [NSString stringWithFormat:@"bytes=%lld-%lld", start, end];
    [req setValue:range forHTTPHeaderField:@"Range"];
    
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (data) {
            @synchronized(self) {
                self.segmentCache[segmentIndex] = data;
                [loadingRequest.dataRequest respondWithData:data];
                [loadingRequest finishLoading];
                [self.pendingRequests removeObject:loadingRequest];
                
                // 保持缓存最多 5 段
                while (self.segmentCache.count > 5) {
                    [self.segmentCache removeObjectForKey:[[self.segmentCache allKeys] firstObject]];
                }
            }
        }
    }];
    [task resume];
}

@end

#pragma mark - PlayerView

@interface PlayerView : NSView
@property (nonatomic, strong) NSURL *videoURL;
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
        [player addObserver:self forKeyPath:@"currentItem.tracks" options:NSKeyValueObservingOptionNew context:nil];
    }
    return self;
}

- (void)dealloc {
    [player removeObserver:self forKeyPath:@"currentItem.tracks"];
    if (timeObserverToken) [player removeTimeObserver:timeObserverToken];
    [self endSystemSleepActivity];
}

#pragma mark - UI

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
    } else if (keyCode == 36) {
        [self.window toggleFullScreen:nil];
    } else if (keyCode == 123) {
        [self seekBySeconds:-10.0];
    } else if (keyCode == 124) {
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

#pragma mark - System Sleep

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

#pragma mark - AVPlayer Observation

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
                self->player.preventsDisplaySleepDuringVideoPlayback = YES;
                [self endSystemSleepActivity];
            } else {
                self->player.preventsDisplaySleepDuringVideoPlayback = NO;
                [self beginSystemSleepActivity];
            }
        });
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - Video Playback

- (void)setVideoURL:(NSURL *)videoURL {
    _videoURL = videoURL;
    
    SegmentResourceLoader *loader = [[SegmentResourceLoader alloc] initWithURL:videoURL segmentSize:1024*1024]; // 1MB 段
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoURL options:nil];
    [asset.resourceLoader setDelegate:loader queue:dispatch_get_main_queue()];
    
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    item.preferredForwardBufferDuration = 2.0; // 仅缓冲 2 秒
    [player replaceCurrentItemWithPlayerItem:item];
    [self setupTimeObserver];
    [player play];
}

- (void)setupTimeObserver {
    if (timeObserverToken) {
        [player removeTimeObserver:timeObserverToken];
        timeObserverToken = nil;
    }
    __weak typeof(self) weakSelf = self;
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

#pragma mark - main

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: %s <path/to/media_file_or_url>\n", argv[0]);
            return 1;
        }

        NSString *inputArg = [NSString stringWithUTF8String:argv[1]];
        NSURL *url = nil;
        if ([inputArg hasPrefix:@"http://"] || [inputArg hasPrefix:@"https://"]) {
            url = [NSURL URLWithString:inputArg];
        } else {
            url = [NSURL fileURLWithPath:inputArg];
        }

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 960, 540)
                                                       styleMask:(NSWindowStyleMaskTitled |
                                                                  NSWindowStyleMaskClosable |
                                                                  NSWindowStyleMaskResizable |
                                                                  NSWindowStyleMaskMiniaturizable)
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];

        [window setTitle:[[url lastPathComponent] stringByDeletingPathExtension]];
        [window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
        [window setAcceptsMouseMovedEvents:YES];
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
