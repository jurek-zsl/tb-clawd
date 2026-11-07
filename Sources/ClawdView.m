#import "ClawdView.h"
#import "ClawdLive.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static const CGFloat ClawdPreferredWidth = 1000;
static const CGFloat ClawdHeight = 30;
static const NSTimeInterval ClawdLimitsDuration = 4;

@implementation ClawdView {
    NSTimer *_timer;
    NSTimeInterval _elapsed;
    CFTimeInterval _startedAt;
    NSTimeInterval _pausedTotal;
    NSTimeInterval _reactionBase;
    NSTimeInterval _reactionStart;
    NSTimeInterval _reactionLastTap;
    NSTimeInterval _lastDirectTouchTime;
    BOOL _reacting;
    BOOL _wanted;
    BOOL _sleeping;
    BOOL _sessionInactive;
    BOOL _applicationHidden;
    NSMutableArray<id> *_observers;
    BOOL _live;
    CWClaudeMonitor *_monitor;
    CWDirector _director;
    NSTimeInterval _limitsTap;
    // While the readout is open the live acting is paused, like the tantrum
    // pauses the autonomous loop: Clawd stops where he is instead of sliding.
    BOOL _limitsOpen;
    NSTimeInterval _limitsEnd, _liveFrozen, _livePausedTotal;
}

- (instancetype)initWithFrame:(NSRect)frame { return [self initWithFrame:frame live:NO]; }

- (instancetype)initWithFrame:(NSRect)frame live:(BOOL)live {
    self = [super initWithFrame:frame];
    if (self) {
        _observers = [NSMutableArray array];
        _lastDirectTouchTime = -100;
        _limitsTap = -100;
        _live = live;
        if (live) _monitor = [[CWClaudeMonitor alloc] initWithClaudeDirectory:[NSHomeDirectory() stringByAppendingPathComponent:@".claude"]];
        self.allowedTouchTypes = NSTouchTypeMaskDirect;
        self.toolTip = live ? @"Clawd · follows Claude Code · tap him for your remaining limits" : @"Clawd · tap him for a tiny tantrum";
        [self setAccessibilityElement:YES];
        [self setAccessibilityRole:NSAccessibilityButtonRole];
        [self setAccessibilityLabel:live ? @"Clawd, following Claude Code" : @"Clawd companion"];
        [self setAccessibilityHelp:live ? @"Press Clawd to show your remaining Claude usage limits." : @"Press Clawd to make him briefly mad. Empty space does nothing."];
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [NSLayoutConstraint activateConstraints:@[
            [self.widthAnchor constraintGreaterThanOrEqualToConstant:64],
            [self.heightAnchor constraintEqualToConstant:ClawdHeight]
        ]];
        __weak ClawdView *weakSelf = self;
        NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
        [_observers addObject:[workspace addObserverForName:NSWorkspaceWillSleepNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            ClawdView *view = weakSelf;
            if (!view) return;
            view->_sleeping = YES;
            [view updateTimer];
        }]];
        [_observers addObject:[workspace addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            ClawdView *view = weakSelf;
            if (!view) return;
            view->_sleeping = NO;
            [view updateTimer];
        }]];
        [_observers addObject:[workspace addObserverForName:NSWorkspaceSessionDidResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            ClawdView *view = weakSelf;
            if (!view) return;
            view->_sessionInactive = YES;
            [view updateTimer];
        }]];
        [_observers addObject:[workspace addObserverForName:NSWorkspaceSessionDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            ClawdView *view = weakSelf;
            if (!view) return;
            view->_sessionInactive = NO;
            [view updateTimer];
        }]];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [_observers addObject:[center addObserverForName:NSApplicationDidHideNotification object:NSApp queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            ClawdView *view = weakSelf;
            if (!view) return;
            view->_applicationHidden = YES;
            [view updateTimer];
        }]];
        [_observers addObject:[center addObserverForName:NSApplicationDidUnhideNotification object:NSApp queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            ClawdView *view = weakSelf;
            if (!view) return;
            view->_applicationHidden = NO;
            [view updateTimer];
        }]];
    }
    return self;
}

- (void)dealloc {
    [_timer invalidate];
    for (id observer in _observers) {
        [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:observer];
        [NSNotificationCenter.defaultCenter removeObserver:observer];
    }
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (NSSize)intrinsicContentSize { return NSMakeSize(ClawdPreferredWidth, ClawdHeight); }
- (BOOL)isAnimating { return _timer != nil; }
- (NSTimeInterval)animationTime { return _elapsed + (_timer ? CACurrentMediaTime() - _startedAt : 0); }

- (void)updateTimer {
    BOOL shouldRun = _wanted && !_sleeping && !_sessionInactive && !_applicationHidden && !self.hidden;
    if (shouldRun && !_timer) {
        _startedAt = CACurrentMediaTime();
        __weak ClawdView *weakSelf = self;
        _timer = [NSTimer timerWithTimeInterval:1.0/30.0 repeats:YES block:^(NSTimer *timer) {
            [weakSelf setNeedsDisplay:YES];
        }];
        _timer.tolerance = 0.005;
        [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    } else if (!shouldRun && _timer) {
        _elapsed += CACurrentMediaTime() - _startedAt;
        [_timer invalidate];
        _timer = nil;
    }
}

- (void)startAnimation { _wanted = YES; [self updateTimer]; }
- (void)stopAnimation { _wanted = NO; [self updateTimer]; }
- (void)setHidden:(BOOL)hidden { [super setHidden:hidden]; [self updateTimer]; }
- (NSTimeInterval)baseTimeAtTime:(NSTimeInterval)time {
    if (_reacting && time >= _reactionLastTap + 2.5) {
        _pausedTotal += _reactionLastTap + 2.5 - _reactionStart;
        _reacting = NO;
    }
    return _reacting ? _reactionBase : MAX(0, time - _pausedTotal);
}

- (CWScene)autonomousSceneAtTime:(NSTimeInterval)time width:(CGFloat)width {
    return CWSampleScene(time, width, -1);
}
- (CWScene)autonomousSceneAtTime:(NSTimeInterval)time width:(CGFloat)width reactionAge:(NSTimeInterval)reactionAge {
    return CWSampleScene(time, width, reactionAge);
}

// The live director's clock: wall time minus every readout pause.
- (NSTimeInterval)liveTimeAtTime:(NSTimeInterval)time {
    if (_limitsOpen) {
        if (time < _limitsEnd) return _liveFrozen;
        _livePausedTotal += _limitsEnd - _limitsTap;
        _limitsOpen = NO;
    }
    return time - _livePausedTotal;
}

- (CWScene)sceneAtTime:(NSTimeInterval)time width:(CGFloat)width {
    if (_live) {
        [_monitor pollIfNeeded];
        NSTimeInterval liveTime = [self liveTimeAtTime:time];
        CWDirectorUpdate(&_director, _monitor.state, liveTime, width);
        CWLimits limits = [_monitor limitsAtDate:NSDate.date];
        BOOL showing = [self showingLimitsAtTime:time];
        return CWRenderBeat(CWDirectorBeat(&_director, liveTime, width), width, CWActivityLimits, showing ? time - _limitsTap : -1, &limits);
    }
    NSTimeInterval base = [self baseTimeAtTime:time];
    return CWSampleScene(base, width, _reacting ? time - _reactionLastTap : -1);
}

- (BOOL)isLive { return _live; }
- (BOOL)showingLimitsAtTime:(NSTimeInterval)time { return _live && _limitsOpen && time >= _limitsTap && time < _limitsEnd; }
- (NSString *)liveStateName { return _live ? CWLiveStateName(_monitor.state) : nil; }
- (void)setClaudeDirectory:(NSString *)directory { _monitor.claudeDirectory = directory; [_monitor poll]; }
- (NSString *)claudeDirectory { return _monitor.claudeDirectory; }
- (void)setUsageFetcher:(void (^)(void (^)(NSDictionary *)))fetcher { _monitor.usageFetcher = fetcher; }
- (void (^)(void (^)(NSDictionary *)))usageFetcher { return _monitor.usageFetcher; }
- (void)setClaudeExecutable:(NSString *)path { _monitor.claudeExecutable = path; }
- (NSString *)claudeExecutable { return _monitor.claudeExecutable; }
- (void)setUsageTimeout:(NSTimeInterval)seconds { _monitor.usageTimeout = seconds; }
- (NSTimeInterval)usageTimeout { return _monitor.usageTimeout; }
- (void)setHistoryPath:(NSString *)path { _monitor.historyPath = path; [_monitor poll]; }
- (NSString *)historyPath { return _monitor.historyPath; }
- (NSString *)limitsNote { return _monitor.limitsNote; }

- (BOOL)handleTapAtPoint:(NSPoint)point time:(NSTimeInterval)time width:(CGFloat)width {
    if (_live && [self showingLimitsAtTime:time]) {
        // Any tap on the strip puts the readout away again.
        _limitsEnd = time;
        self.needsDisplay = YES;
        return YES;
    }
    CWScene current = [self sceneAtTime:time width:width];
    if (!CWSceneHitsActor(current, point)) return NO;
    if (_live) {
        _liveFrozen = [self liveTimeAtTime:time];
        _limitsTap = time;
        _limitsEnd = time + ClawdLimitsDuration;
        _limitsOpen = YES;
        [_monitor poll];
        [_monitor refreshUsageIfStale];
        self.needsDisplay = YES;
        return YES;
    }
    if (!_reacting) {
        _reactionBase = current.baseTime;
        _reactionStart = time;
        _reacting = YES;
    }
    _reactionLastTap = time;
    self.needsDisplay = YES;
    return YES;
}

- (void)mouseDown:(NSEvent *)event {
    // A Touch Bar press may also synthesize a mouse event. Count it once.
    if (self.animationTime - _lastDirectTouchTime < .15) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self handleTapAtPoint:point time:self.animationTime width:self.bounds.size.width];
}

- (void)touchesBeganWithEvent:(NSEvent *)event {
    for (NSTouch *touch in [event touchesMatchingPhase:NSTouchPhaseBegan inView:self]) {
        if (touch.type != NSTouchTypeDirect) continue;
        // locationInView already uses this flipped view's coordinates. Touch
        // Bar touch geometry provides a meaningful horizontal component only.
        NSPoint point = [touch locationInView:self];
        double time = self.animationTime;
        _lastDirectTouchTime = time;
        CGFloat width = self.bounds.size.width;
        if ([self showingLimitsAtTime:time]) { [self handleTapAtPoint:point time:time width:width]; return; }
        CWScene scene = [self sceneAtTime:time width:width];
        if (point.x < 0 || point.x > width || point.x < NSMinX(scene.actorBounds)-3 || point.x > NSMaxX(scene.actorBounds)+3) return;
        // Route a visible actor pixel through the same anchored reaction path;
        // the horizontal hit accepts a finger regardless of its reported y.
        for (NSInteger i=scene.pixelCount-1; i>=0; i--) {
            if (!scene.pixels[i].actor) continue;
            NSRect pixel = scene.pixels[i].rect;
            NSPoint target = NSMakePoint(NSMidX(pixel), NSMidY(pixel));
            if (CWSceneHitsActor(scene,target)) {
                [self handleTapAtPoint:target time:time width:width];
                return;
            }
        }
        return;
    }
}

// A contact begins one reaction; dragging or releasing it does not repoke.
- (void)touchesMovedWithEvent:(NSEvent *)event {}
- (void)touchesEndedWithEvent:(NSEvent *)event {}
- (void)touchesCancelledWithEvent:(NSEvent *)event {}

- (BOOL)accessibilityPerformPress {
    double time = self.animationTime;
    if ([self showingLimitsAtTime:time]) return [self handleTapAtPoint:NSZeroPoint time:time width:self.bounds.size.width];
    CWScene current = [self sceneAtTime:time width:self.bounds.size.width];
    // The semantic button is the character, so select a visible actor pixel.
    for (NSInteger i=current.pixelCount-1; i>=0; i--) {
        if (!current.pixels[i].actor) continue;
        NSRect pixel = current.pixels[i].rect;
        NSPoint point = NSMakePoint(NSMidX(pixel), NSMidY(pixel));
        if (CWSceneHitsActor(current,point)) return [self handleTapAtPoint:point time:time width:self.bounds.size.width];
    }
    return NO;
}

- (NSTimeInterval)journeyDurationForWidth:(CGFloat)width { return 2 * CWRunDuration(width); }
- (CGFloat)anchorMinForWidth:(CGFloat)width { return CWAnchorMin(width); }
- (CGFloat)anchorMaxForWidth:(CGFloat)width { return CWAnchorMax(width); }
- (NSTimeInterval)sceneDurationForWidth:(CGFloat)width { return CWSceneDuration(width); }
- (NSString *)activityNameAtTime:(NSTimeInterval)time width:(CGFloat)width {
    return CWActivityName(CWSampleScene(time,width,-1).activity);
}

static NSColor *Ink(CWInk ink) {
    switch(ink) {
        // Eyes are notches cut out of the body, as in the terminal glyph.
        case CWInkEye:return [NSColor blackColor];
        case CWInkLaptop:return [NSColor colorWithSRGBRed:.39 green:.43 blue:.45 alpha:1];
        case CWInkScreen:return [NSColor colorWithSRGBRed:.10 green:.17 blue:.18 alpha:1];
        case CWInkCode:return [NSColor colorWithSRGBRed:.53 green:.76 blue:.66 alpha:1];
        case CWInkCup:return [NSColor colorWithSRGBRed:.91 green:.83 blue:.68 alpha:1];
        case CWInkCoffee:return [NSColor colorWithSRGBRed:.34 green:.22 blue:.16 alpha:1];
        case CWInkSteam:return [NSColor colorWithSRGBRed:.56 green:.60 blue:.60 alpha:1];
        case CWInkText:return [NSColor colorWithSRGBRed:.88 green:.86 blue:.82 alpha:1];
        case CWInkTrack:return [NSColor colorWithSRGBRed:.22 green:.22 blue:.22 alpha:1];
        case CWInkWarn:return [NSColor colorWithSRGBRed:.95 green:.71 blue:.30 alpha:1];
        case CWInkLow:return [NSColor colorWithSRGBRed:.90 green:.33 blue:.30 alpha:1];
        default:return [NSColor colorWithSRGBRed:215/255.0 green:119/255.0 blue:87/255.0 alpha:1];
    }
}

- (void)drawScene:(CWScene)scene inRect:(NSRect)rect {
    [NSColor.blackColor setFill];
    NSRectFill(rect);
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(rect);
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSetShouldAntialias(context, NO);
    for (NSInteger i=0; i<scene.pixelCount; i++) {
        CWPixel pixel=scene.pixels[i];
        [Ink(pixel.ink) setFill];
        NSRectFill(NSOffsetRect(pixel.rect,rect.origin.x,rect.origin.y));
    }
    [NSGraphicsContext restoreGraphicsState];
}

- (void)drawRect:(NSRect)dirtyRect {
    [self drawScene:[self sceneAtTime:self.animationTime width:self.bounds.size.width] inRect:self.bounds];
}

- (NSBitmapImageRep *)bitmapAtTime:(NSTimeInterval)time width:(CGFloat)width scale:(NSInteger)scale {
    return [self bitmapAtTime:time width:width scale:scale reactionAge:-1];
}

- (NSBitmapImageRep *)bitmapAtTime:(NSTimeInterval)time width:(CGFloat)width scale:(NSInteger)scale reactionAge:(NSTimeInterval)reactionAge {
    width = MAX(64, round(width));
    scale = MAX(1, scale);
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width * scale pixelsHigh:ClawdHeight * scale bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext *graphics = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    NSGraphicsContext.currentContext = graphics;
    CGContextRef cg = graphics.CGContext;
    CGContextTranslateCTM(cg, 0, ClawdHeight * scale);
    CGContextScaleCTM(cg, scale, -scale);
    CWScene scene;
    if (_live) {
        CWDirector director = {0};
        CWDirectorUpdate(&director, _monitor.state, time, width);
        CWLimits limits = [_monitor limitsAtDate:NSDate.date];
        scene = CWRenderBeat(CWDirectorBeat(&director, time, width), width, CWActivityLimits, reactionAge, &limits);
    } else scene = CWSampleScene(time,width,reactionAge);
    [self drawScene:scene inRect:NSMakeRect(0,0,width,ClawdHeight)];
    [NSGraphicsContext restoreGraphicsState];
    bitmap.size = NSMakeSize(width, ClawdHeight);
    return bitmap;
}
@end
