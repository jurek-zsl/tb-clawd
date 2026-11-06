// Renders the README showcase from the bundles' real renderers: no redraws,
// only cropping, nearest-neighbour scaling and captions outside the strip.
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import "ClawdView.h"

@interface ClawdView (Showcase)
- (void)drawScene:(CWScene)scene inRect:(NSRect)rect;
@end

static CWScene CWSampleSceneVia(ClawdView *view, double time, CGFloat width) { return [view autonomousSceneAtTime:time width:width]; }
static CWScene CWReactionSceneVia(ClawdView *view, double time, CGFloat width, double age) { return [view autonomousSceneAtTime:time width:width reactionAge:age]; }

static void Fail(NSString *message) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }

static NSColor *Backdrop(void) { return [NSColor colorWithSRGBRed:.06 green:.06 blue:.06 alpha:1]; }

// The whole strip at `scale`, exactly as the widget draws it.
static CGImageRef StripImage(ClawdView *view, CWScene scene, CGFloat width, NSInteger scale) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width*scale pixelsHigh:30*scale bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext *graphics = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    NSGraphicsContext.currentContext = graphics;
    CGContextTranslateCTM(graphics.CGContext, 0, 30*scale);
    CGContextScaleCTM(graphics.CGContext, scale, -scale);
    [view drawScene:scene inRect:NSMakeRect(0, 0, width, 30)];
    [NSGraphicsContext restoreGraphicsState];
    return CGImageRetain(bitmap.CGImage);
}

// A frame: optional caption band on top, then the cropped strip.
typedef struct { CGFloat x, width; } Crop;
static CGImageRef Frame(ClawdView *view, CWScene scene, CGFloat stripWidth, Crop crop, NSInteger scale, NSString *caption, NSString *detail) {
    CGFloat captionHeight = caption ? 34 : 0;
    NSInteger w = crop.width*scale, h = 30*scale + captionHeight;
    NSBitmapImageRep *canvas = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:canvas];
    [Backdrop() setFill];
    NSRectFill(NSMakeRect(0, 0, w, h));
    CGImageRef strip = StripImage(view, scene, stripWidth, scale);
    CGImageRef part = CGImageCreateWithImageInRect(strip, CGRectMake(crop.x*scale, 0, crop.width*scale, 30*scale));
    CGContextSetInterpolationQuality(NSGraphicsContext.currentContext.CGContext, kCGInterpolationNone);
    CGContextDrawImage(NSGraphicsContext.currentContext.CGContext, CGRectMake(0, 0, w, 30*scale), part);
    CGImageRelease(part); CGImageRelease(strip);
    if (caption) {
        NSDictionary *strong = @{NSFontAttributeName: [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold],
                                 NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:.93 green:.91 blue:.87 alpha:1]};
        NSDictionary *soft = @{NSFontAttributeName: [NSFont systemFontOfSize:14 weight:NSFontWeightRegular],
                               NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:.84 green:.47 blue:.34 alpha:1]};
        NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:caption attributes:strong];
        if (detail) [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@"   →   " stringByAppendingString:detail] attributes:soft]];
        [text drawAtPoint:NSMakePoint(12, 30*scale + 9)];
    }
    [NSGraphicsContext restoreGraphicsState];
    return CGImageRetain(canvas.CGImage);
}

// Animated GIF writer that merges identical consecutive frames into one
// longer frame; Clawd's stepped poses repeat a lot.
@interface CWGif : NSObject
- (instancetype)initWithFrameDelay:(double)delay;
- (void)add:(CGImageRef)image;
- (void)writeTo:(NSString *)path;
@end
@implementation CWGif {
    double _delay;
    NSMutableArray *_images;
    NSMutableArray<NSNumber *> *_delays;
    NSData *_last;
}
- (instancetype)initWithFrameDelay:(double)delay {
    self = [super init];
    _delay = delay; _images = [NSMutableArray array]; _delays = [NSMutableArray array];
    return self;
}
- (void)add:(CGImageRef)image {
    NSData *data = CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image)));
    if (_last && [data isEqualToData:_last]) { _delays[_delays.count-1] = @(_delays.lastObject.doubleValue + _delay); return; }
    _last = data;
    [_images addObject:(__bridge id)image];
    [_delays addObject:@(_delay)];
}
- (void)writeTo:(NSString *)path {
    CGImageDestinationRef gif = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("com.compuserve.gif"), _images.count, NULL);
    if (!gif) Fail(@"create GIF");
    CGImageDestinationSetProperties(gif, (__bridge CFDictionaryRef)@{(id)kCGImagePropertyGIFDictionary: @{(id)kCGImagePropertyGIFLoopCount: @0}});
    for (NSUInteger i = 0; i < _images.count; i++) {
        double delay = round(_delays[i].doubleValue * 100) / 100;
        NSDictionary *frame = @{(id)kCGImagePropertyGIFDictionary: @{(id)kCGImagePropertyGIFDelayTime: @(delay), (id)kCGImagePropertyGIFUnclampedDelayTime: @(delay)}};
        CGImageDestinationAddImage(gif, (__bridge CGImageRef)_images[i], (__bridge CFDictionaryRef)frame);
    }
    if (!CGImageDestinationFinalize(gif)) Fail(@"write GIF");
    CFRelease(gif);
    printf("%s  %lu frames\n", path.UTF8String, (unsigned long)_images.count);
}
@end

static void WritePNG(CGImageRef image, NSString *path) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    if (![[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES]) Fail(@"write PNG");
    printf("%s\n", path.UTF8String);
}

static NSRect ContentBounds(CWScene scene) {
    NSRect bounds = NSZeroRect;
    for (NSInteger i = 0; i < scene.pixelCount; i++) bounds = NSIsEmptyRect(bounds) ? scene.pixels[i].rect : NSUnionRect(bounds, scene.pixels[i].rect);
    return bounds;
}
static Crop CenteredCrop(CWScene scene, CGFloat stripWidth, CGFloat width) {
    NSRect bounds = ContentBounds(scene);
    CGFloat x = round(NSMidX(bounds) - width/2);
    return (Crop){fmax(0, fmin(stripWidth - width, x)), width};
}

// --------------------------------------------------------- live fixture ---

static NSString *FixtureDirectory(void) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"clawd-showcase-%d", getpid()]];
    [NSFileManager.defaultManager removeItemAtPath:dir error:NULL];
    [NSFileManager.defaultManager createDirectoryAtPath:[dir stringByAppendingPathComponent:@"sessions"] withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}
static void SetSession(ClawdView *view, NSString *status) {
    NSString *path = [view.claudeDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"sessions/%d.json", getpid()]];
    if (!status) [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    else {
        double ms = NSDate.date.timeIntervalSince1970 * 1000;
        NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"pid": @(getpid()), @"status": status, @"statusUpdatedAt": @(ms)} options:0 error:NULL];
        [data writeToFile:path atomically:YES];
    }
    view.claudeDirectory = view.claudeDirectory;   // re-read now
}
static ClawdView *LiveView(NSBundle *live, NSString *dir) {
    ClawdView *view = [[[live.principalClass alloc] init] valueForKey:@"view"];
    view.claudeDirectory = dir;
    // Sample numbers for the readout; the showcase never reads real limits.
    view.usageFetcher = ^(void (^done)(NSDictionary *)) {
        NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
        done(@{@"five_hour": @{@"utilization": @37, @"resets_at": [iso stringFromDate:[NSDate dateWithTimeIntervalSinceNow:2*3600+10*60+30]]},
               @"seven_day": @{@"utilization": @82, @"resets_at": [iso stringFromDate:[NSDate dateWithTimeIntervalSinceNow:3*86400+3600]]}});
    };
    return view;
}
static void Tap(ClawdView *view, double time, CGFloat width) {
    CWScene scene = [view sceneAtTime:time width:width];
    NSPoint point = NSMakePoint(NSMidX(scene.actorBounds), NSMidY(scene.actorBounds));
    if (![view handleTapAtPoint:point time:time width:width]) Fail(@"showcase tap missed Clawd");
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
}

// ------------------------------------------------------------- showcase ---

int CWRunShowcase(NSString *output, NSBundle *clawdBundle, NSBundle *liveBundle) {
    [NSFileManager.defaultManager createDirectoryAtPath:output withIntermediateDirectories:YES attributes:nil error:NULL];
    ClawdView *clawd = [[[clawdBundle.principalClass alloc] init] valueForKey:@"view"];
    const double fps = 20;

    // 1. Clawd's whole autonomous loop on a 420 point bar.
    {
        CGFloat width = 420;
        CWGif *gif = [[CWGif alloc] initWithFrameDelay:1/fps];
        double duration = [clawd sceneDurationForWidth:width];
        for (int i = 0; i < duration*fps; i++) {
            CWScene scene = CWSampleSceneVia(clawd, i/fps, width);
            CGImageRef frame = Frame(clawd, scene, width, (Crop){0, width}, 2, nil, nil);
            [gif add:frame]; CGImageRelease(frame);
        }
        [gif writeTo:[output stringByAppendingPathComponent:@"preview.gif"]];
    }

    // 2. The tantrum, close up.
    {
        CGFloat width = 176;
        CWGif *gif = [[CWGif alloc] initWithFrameDelay:1/fps];
        double time = [clawd journeyDurationForWidth:width]/4;
        CWScene still = CWSampleSceneVia(clawd, time, width);
        Crop crop = CenteredCrop(still, width, 84);
        for (int i = 0; i < 2.5*fps + 10; i++) {
            CWScene scene = CWReactionSceneVia(clawd, time, width, i < 2.5*fps ? i/fps : -1);
            CGImageRef frame = Frame(clawd, scene, width, crop, 4, nil, nil);
            [gif add:frame]; CGImageRelease(frame);
        }
        [gif writeTo:[output stringByAppendingPathComponent:@"mad.gif"]];
    }

    // 3. Clawd Live, following a scripted Claude Code session.
    {
        CGFloat width = 420;
        NSString *dir = FixtureDirectory();
        ClawdView *live = LiveView(liveBundle, dir);
        CWGif *gif = [[CWGif alloc] initWithFrameDelay:1/fps];
        struct { double at; NSString *status; BOOL tap; NSString *caption, *detail; } story[] = {
            {0,  nil,        NO,  @"No Claude Code session",      @"Clawd sleeps"},
            {3,  @"busy",    NO,  @"Claude is working",           @"Clawd runs to the laptop and codes"},
            {15, @"waiting", NO,  @"Claude needs your answer",    @"Clawd waves at you"},
            {20, @"busy",    NO,  @"Claude is working again",     @"back to the keyboard"},
            {25, @"idle",    NO,  @"Claude finished the turn",    @"Clawd takes a break"},
            {33, @"idle",    YES, @"You tap Clawd",               @"he stops and shows your remaining limits"},
            {38, nil,        NO,  @"Idle for 5 minutes",          @"Clawd goes home to sleep"},
        };
        const int steps = sizeof story / sizeof story[0];
        double end = 49, start = 100;
        int next = 0;
        NSString *caption = nil, *detail = nil;
        for (int i = 0; i < end*fps; i++) {
            double t = i/fps;
            while (next < steps && story[next].at <= t + 1e-9) {
                if (story[next].tap) Tap(live, start + t, width);
                else SetSession(live, story[next].status);
                caption = story[next].caption; detail = story[next].detail;
                next++;
            }
            CWScene scene = [live sceneAtTime:start + t width:width];
            CGImageRef frame = Frame(live, scene, width, (Crop){0, width}, 2, caption, detail);
            [gif add:frame]; CGImageRelease(frame);
        }
        [gif writeTo:[output stringByAppendingPathComponent:@"live.gif"]];
        [NSFileManager.defaultManager removeItemAtPath:dir error:NULL];
    }

    // 4. The limits readout, close up.
    {
        CGFloat width = 176;
        NSString *dir = FixtureDirectory();
        ClawdView *live = LiveView(liveBundle, dir);
        SetSession(live, @"busy");
        [live sceneAtTime:200 width:width];
        Tap(live, 200, width);
        CWScene scene = [live sceneAtTime:201 width:width];
        CGImageRef frame = Frame(live, scene, width, (Crop){0, width}, 4, nil, nil);
        WritePNG(frame, [output stringByAppendingPathComponent:@"limits.png"]);
        CGImageRelease(frame);
        [NSFileManager.defaultManager removeItemAtPath:dir error:NULL];
    }

    // 5. Contact sheet of every pose, labelled outside the strip.
    {
        CGFloat width = 176, cell = 112;
        NSInteger scale = 3, columns = 4;
        double run = [clawd journeyDurationForWidth:width]/2;
        NSMutableArray *cells = [NSMutableArray array];
        void (^addCell)(NSString *, ClawdView *, CWScene) = ^(NSString *label, ClawdView *view, CWScene scene) {
            CGImageRef image = Frame(view, scene, width, CenteredCrop(scene, width, cell), scale, nil, nil);
            [cells addObject:@[label, (__bridge_transfer id)image]];
        };
        addCell(@"run", clawd, CWSampleSceneVia(clawd, run/2, width));
        addCell(@"code", clawd, CWSampleSceneVia(clawd, run+4, width));
        addCell(@"coffee", clawd, CWSampleSceneVia(clawd, 2*run+13.8, width));
        addCell(@"stretch", clawd, CWSampleSceneVia(clawd, 3*run+20.8, width));
        addCell(@"nap", clawd, CWSampleSceneVia(clawd, 4*run+28, width));
        addCell(@"tap: mad", clawd, CWReactionSceneVia(clawd, run/2, width, .7));
        NSString *dir = FixtureDirectory();
        ClawdView *live = LiveView(liveBundle, dir);
        SetSession(live, @"waiting");
        [live sceneAtTime:300 width:width];
        addCell(@"live: waiting", live, [live sceneAtTime:301.4 width:width]);
        SetSession(live, @"busy");
        double t = 302;
        for (; t < 320; t += .05) [live sceneAtTime:t width:width];
        addCell(@"live: working", live, [live sceneAtTime:t width:width]);
        [NSFileManager.defaultManager removeItemAtPath:dir error:NULL];

        NSInteger cellW = cell*scale, labelH = 26, cellH = 30*scale + labelH, rows = (cells.count + columns - 1)/columns;
        NSBitmapImageRep *sheet = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:cellW*columns pixelsHigh:cellH*rows bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:sheet];
        [Backdrop() setFill];
        NSRectFill(NSMakeRect(0, 0, cellW*columns, cellH*rows));
        NSDictionary *label = @{NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
                                NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:.88 green:.86 blue:.82 alpha:1]};
        for (NSUInteger i = 0; i < cells.count; i++) {
            NSInteger x = (i % columns) * cellW, top = (rows - 1 - i / columns) * cellH;
            CGContextDrawImage(NSGraphicsContext.currentContext.CGContext, CGRectMake(x, top, cellW, 30*scale), (__bridge CGImageRef)cells[i][1]);
            [cells[i][0] drawAtPoint:NSMakePoint(x + 10, top + 30*scale + 6) withAttributes:label];
        }
        [NSGraphicsContext restoreGraphicsState];
        WritePNG(sheet.CGImage, [output stringByAppendingPathComponent:@"actions-contact.png"]);
    }
    return 0;
}
