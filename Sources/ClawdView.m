#import "ClawdView.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static const CGFloat ClawdPreferredWidth = 1000;
static const CGFloat ClawdHeight = 30;

@implementation ClawdView {
    NSTimer *_timer;
    NSTimeInterval _elapsed;
    CFTimeInterval _startedAt;
    NSTimeInterval _hopAt;
    BOOL _wanted;
    BOOL _sleeping;
    BOOL _sessionInactive;
    BOOL _applicationHidden;
    NSMutableArray<id> *_observers;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _hopAt = -100;
        _observers = [NSMutableArray array];
        self.toolTip = @"Clawd · tap for a little hop";
        [self setAccessibilityElement:YES];
        [self setAccessibilityRole:NSAccessibilityButtonRole];
        [self setAccessibilityLabel:@"Running Clawd"];
        [self setAccessibilityHelp:@"Press to make Clawd hop."];
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
- (void)hop { _hopAt = self.animationTime; self.needsDisplay = YES; }
- (void)mouseDown:(NSEvent *)event { [self hop]; }
- (BOOL)accessibilityPerformPress { [self hop]; return YES; }

static void PixelRect(CGFloat x, CGFloat y, CGFloat width, CGFloat height) {
    NSRectFill(NSMakeRect(round(x), round(y), width, height));
}

- (NSTimeInterval)journeyDurationForWidth:(CGFloat)width {
    CGFloat travel = MAX(0, width - 46);
    // Accelerate for at most .3s, then run at 64pt/s regardless of bar width.
    double acceleration = MIN(0.3, travel / 64.0);
    return MAX(0.1, 2 * (travel / 64.0 + acceleration));
}

- (void)drawSceneInRect:(NSRect)rect time:(NSTimeInterval)time hopAge:(NSTimeInterval)hopAge {
    [NSColor.blackColor setFill];
    NSRectFill(rect);
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(rect);
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSetShouldAntialias(context, NO);

    CGFloat travel = MAX(0, rect.size.width - 46);
    double halfDuration = [self journeyDurationForWidth:rect.size.width] / 2;
    double legIndex = floor(MAX(0, time) / halfDuration);
    double legTime = fmod(MAX(0, time), halfDuration);
    double acceleration = MIN(0.3, travel / 64.0);
    CGFloat distance;
    if (acceleration <= 0) {
        distance = 0;
    } else if (legTime < acceleration) {
        distance = 32.0 * legTime * legTime / acceleration;
    } else if (legTime > halfDuration - acceleration) {
        double remaining = halfDuration - legTime;
        distance = travel - 32.0 * remaining * remaining / acceleration;
    } else {
        distance = 64.0 * (legTime - acceleration / 2);
    }
    BOOL right = fmod(legIndex, 2) < 1;
    CGFloat x = round(rect.origin.x + 8 + (right ? distance : travel - distance));
    // Gait follows travelled distance, so feet settle as Clawd slows to turn.
    double stride = travel > 0 ? travel / MAX(1, round(travel / 20)) : 20;
    double gait = (legIndex * travel + distance) / stride * 2 * M_PI;
    CGFloat hop = (hopAge >= 0 && hopAge < 0.55) ? 5.0 * sin(M_PI * hopAge / 0.55) : 0;
    CGFloat bob = round((1 - cos(gait * 2)) * 0.5);
    CGFloat y = rect.origin.y + 6 - bob - round(hop);

    // The Claude Code silhouette has a flat rectangular body, side tabs,
    // square eyes and two pairs of separated legs. No ears or rounded head.
    [[NSColor colorWithSRGBRed:0.84 green:0.46 blue:0.35 alpha:1] setFill];
    const CGFloat hips[] = {3, 8, 19, 24};
    for (int leg = 0; leg < 4; leg++) {
        double phase = gait + (leg >= 2 ? M_PI : 0);
        CGFloat hip = x + hips[leg];
        CGFloat swing = round(sin(phase));
        CGFloat lift = round(MAX(0, cos(phase)) * 2);
        PixelRect(hip, y + 15, 3, 3);
        PixelRect(hip + swing, y + 17 - lift, 3, 5);
    }
    PixelRect(x + 3, y, 24, 16);
    PixelRect(x, y + 5 + round(sin(gait)), 3, 6);
    PixelRect(x + 27, y + 5 - round(sin(gait)), 3, 6);
    [[NSColor colorWithSRGBRed:28/255.0 green:25/255.0 blue:24/255.0 alpha:1] setFill];
    BOOL blink = fmod(time + 0.8, 4.7) < 0.12;
    CGFloat gaze = right ? 1 : -1;
    PixelRect(x + 6 + gaze, y + 5, 3, blink ? 1 : 3);
    PixelRect(x + 21 + gaze, y + 5, 3, blink ? 1 : 3);
    [NSGraphicsContext restoreGraphicsState];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSTimeInterval time = self.animationTime;
    [self drawSceneInRect:self.bounds time:time hopAge:time - _hopAt];
}

- (NSBitmapImageRep *)bitmapAtTime:(NSTimeInterval)time width:(CGFloat)width scale:(NSInteger)scale {
    width = MAX(64, round(width));
    scale = MAX(1, scale);
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width * scale pixelsHigh:ClawdHeight * scale bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext *graphics = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    NSGraphicsContext.currentContext = graphics;
    CGContextRef cg = graphics.CGContext;
    CGContextTranslateCTM(cg, 0, ClawdHeight * scale);
    CGContextScaleCTM(cg, scale, -scale);
    [self drawSceneInRect:NSMakeRect(0, 0, width, ClawdHeight) time:time hopAge:-1];
    [NSGraphicsContext restoreGraphicsState];
    bitmap.size = NSMakeSize(width, ClawdHeight);
    return bitmap;
}
@end
