#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "ClawdView.h"

static void Require(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}


// Synthetic AppKit input drives the real NSResponder entry points. Unlike the
// preview mouse, a direct Touch Bar touch may report y at either strip edge.
@interface CWTestTouch : NSTouch
@property(nonatomic) NSTouchType fakeType;
@property(nonatomic) NSPoint fakeLocation;
@property(nonatomic, weak) NSView *requestedView;
@property(nonatomic) BOOL locationRequested;
@end
@implementation CWTestTouch
- (NSTouchType)type { return self.fakeType; }
- (NSPoint)locationInView:(NSView *)view {
    self.locationRequested=YES; self.requestedView=view; return self.fakeLocation;
}
@end
@interface CWTestEvent : NSEvent
@property(nonatomic, copy) NSSet<NSTouch *> *fakeTouches;
@property(nonatomic) NSTouchPhase requestedPhase;
@property(nonatomic, weak) NSView *requestedView;
@property(nonatomic) NSPoint fakeMouseLocation;
@end
@implementation CWTestEvent
- (NSSet<NSTouch *> *)touchesMatchingPhase:(NSTouchPhase)phase inView:(NSView *)view {
    self.requestedPhase=phase; self.requestedView=view; return self.fakeTouches;
}
- (NSPoint)locationInWindow { return self.fakeMouseLocation; }
@end
static double CWInputClock;
static double CWFixedClock(id object, SEL selector) { return CWInputClock; }
static CWTestEvent *CWTouchEvent(double x, double y, NSTouchType type) {
    CWTestTouch *touch=[CWTestTouch new];
    touch.fakeType=type; touch.fakeLocation=NSMakePoint(x,y);
    CWTestEvent *event=[CWTestEvent new]; event.fakeTouches=[NSSet setWithObject:touch];
    return event;
}
static void CheckTouchDelivery(Class viewClass) {
    Class testClass=objc_allocateClassPair(viewClass,"CWInputClockView",0);
    class_addMethod(testClass,@selector(animationTime),(IMP)CWFixedClock,"d@:");
    objc_registerClassPair(testClass);
    for(NSNumber *y in @[@0,@30]) {
        ClawdView *input=[[testClass alloc] initWithFrame:NSMakeRect(0,0,176,30)];
        Require(input.allowedTouchTypes==NSTouchTypeMaskDirect,@"view opts into direct Touch Bar events");
        CWInputClock=1;
        CWScene before=[input sceneAtTime:CWInputClock width:176];
        CWTestEvent *event=CWTouchEvent(before.anchorX+15,y.doubleValue,NSTouchTypeDirect);
        [input touchesBeganWithEvent:event];
        CWTestTouch *touch=(CWTestTouch *)event.fakeTouches.anyObject;
        Require(event.requestedPhase==NSTouchPhaseBegan && event.requestedView==input && touch.requestedView==input,@"touch began requests direct location in actual flipped view");
        Require([input sceneAtTime:1 width:176].activity==CWActivityMad,@"direct actor touch reacts at top and bottom reported y");
        Require(fabs([input baseTimeAtTime:1]-before.baseTime)<.001,@"direct hit freezes its sampled actor without position jump");
        CWInputClock=1.08;
        CWTestEvent *mouse=[CWTestEvent new];
        mouse.fakeMouseLocation=[input convertPoint:NSMakePoint(before.anchorX+15,15) toView:nil];
        [input mouseDown:mouse];
        Require(fabs([[input valueForKey:@"reactionLastTap"] doubleValue]-1)<.001,@"synthesized mouse does not duplicate direct began");
        [input touchesMovedWithEvent:event]; [input touchesEndedWithEvent:event]; [input touchesCancelledWithEvent:event];
        Require(fabs([[input valueForKey:@"reactionLastTap"] doubleValue]-1)<.001,@"moved ended cancelled do not restart reaction");
        CWInputClock=1.25;
        [input touchesBeganWithEvent:event];
        Require(fabs([[input valueForKey:@"reactionLastTap"] doubleValue]-1.25)<.001,@"new direct began restarts existing reaction");
        CWInputClock=1.5;
        [input mouseDown:mouse];
        Require(fabs([[input valueForKey:@"reactionLastTap"] doubleValue]-1.5)<.001,@"later preview mouse remains interactive");
    }
    ClawdView *ignored=[[testClass alloc] initWithFrame:NSMakeRect(0,0,176,30)];
    CWInputClock=1;
    CWScene running=[ignored sceneAtTime:1 width:176];
    CWTestEvent *indirect=CWTouchEvent(running.anchorX+15,15,NSTouchTypeIndirect);
    [ignored touchesBeganWithEvent:indirect];
    Require(!((CWTestTouch *)indirect.fakeTouches.anyObject).locationRequested,@"indirect touch filtered before locationInView");
    Require([ignored sceneAtTime:1 width:176].activity!=CWActivityMad,@"indirect touch ignored");
    [ignored touchesBeganWithEvent:CWTouchEvent(175,15,NSTouchTypeDirect)];
    Require([ignored sceneAtTime:1 width:176].activity!=CWActivityMad,@"empty horizontal strip ignores direct touch");
    CWInputClock=[ignored journeyDurationForWidth:176]/2+3;
    CWScene coding=[ignored sceneAtTime:CWInputClock width:176];
    [ignored touchesBeganWithEvent:CWTouchEvent(coding.anchorX-12,20,NSTouchTypeDirect)];
    Require([ignored sceneAtTime:CWInputClock width:176].activity==CWActivityCode,@"laptop-only horizontal position ignores direct touch");
    ClawdView *mouseOnly=[[testClass alloc] initWithFrame:NSMakeRect(0,0,176,30)];
    CWInputClock=1;
    CWTestEvent *mouse=[CWTestEvent new];
    mouse.fakeMouseLocation=[mouseOnly convertPoint:NSMakePoint(running.anchorX+15,15) toView:nil];
    [mouseOnly mouseDown:mouse];
    Require([mouseOnly sceneAtTime:1 width:176].activity==CWActivityMad,@"mouse-only preview path reacts");
}


int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSString *mode = argc > 1 ? @(argv[1]) : @"--preview";
        if ([mode isEqualToString:@"--check"]) {
            Require(argc > 3, @"usage: ClawdTools --check bundle framework");
            void *framework = dlopen(argv[3], RTLD_NOW | RTLD_GLOBAL);
            const char *error = framework ? NULL : dlerror();
            Require(framework != NULL, error ? @(error) : @"PockKit load");
            Protocol *hostProtocol = objc_getProtocol("PKWidget");
            Require(hostProtocol != nil, @"real host PKWidget protocol exists before loading bundle");
            NSBundle *bundle = [NSBundle bundleWithPath:@(argv[2])];
            NSError *bundleError;
            Require([bundle loadAndReturnError:&bundleError], bundleError.description ?: @"bundle load");
            Class principal = bundle.principalClass;
            Require(principal != Nil, @"NSPrincipalClass");
            Require(class_conformsToProtocol(principal, hostProtocol), @"principal class conforms to real PockKit PKWidget");
            id widget = [[principal alloc] init];
            Require([[widget valueForKey:@"customizationLabel"] isEqual:@"Clawd"], @"customization label");
            NSView *view = [widget valueForKey:@"view"];
            Require([view isKindOfClass:NSView.class], @"view is NSView");
            Require(NSEqualSizes(view.intrinsicContentSize, NSMakeSize(1000, 30)), @"flexible preferred Touch Bar size");
            Require([view contentHuggingPriorityForOrientation:NSLayoutConstraintOrientationHorizontal] == 1, @"expands available slot");
            Require([view contentCompressionResistancePriorityForOrientation:NSLayoutConstraintOrientationHorizontal] == 1, @"shrinks before siblings");
            ClawdView *actorView = (ClawdView *)view;
            for (NSNumber *widthValue in @[@64, @176, @685, @1000]) {
                CGFloat width = widthValue.doubleValue;
                NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:@"clawd.test"];
                item.view = view;
                NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 30)];
                [container addSubview:item.view];
                NSArray *edges = @[
                    [view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
                    [view.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
                    [view.topAnchor constraintEqualToAnchor:container.topAnchor]
                ];
                [NSLayoutConstraint activateConstraints:edges];
                [container layoutSubtreeIfNeeded];
                Require(fabs(view.bounds.size.width - width) < 0.01, @"host can allocate requested width");
                double run = [actorView journeyDurationForWidth:width] / 2;
                double period = [actorView sceneDurationForWidth:width];
                for (int sample = 0; sample < 240; sample++) {
                    CWScene scene = [actorView autonomousSceneAtTime:sample*period/240 width:width];
                    Require(scene.pixelCount > 0 && scene.pixelCount < 256, @"complete deterministic pose");
                    for(NSInteger i=0;i<scene.pixelCount;i++) {
                        NSRect pixel=scene.pixels[i].rect;
                        Require(NSMinX(pixel)>=0 && NSMaxX(pixel)<=width && NSMinY(pixel)>=0 && NSMaxY(pixel)<=30, @"all actor and prop pixels fit strip");
                    }
                }
                CWScene start = [actorView autonomousSceneAtTime:0 width:width];
                CWScene end = [actorView autonomousSceneAtTime:run width:width];
                Require(start.anchorX == 8 && end.anchorX == width-38, @"runs to both endpoint anchors");
                double boundaries[]={run,run+10,2*run+10,2*run+18,3*run+18,3*run+24,4*run+24,period};
                for(int i=0;i<8;i++) {
                    CWScene before=[actorView autonomousSceneAtTime:boundaries[i]-.00001 width:width];
                    CWScene after=[actorView autonomousSceneAtTime:boundaries[i]+.00001 width:width];
                    Require(fabs(before.anchorX-after.anchorX)<.01, @"timeline anchors continuous at every activity boundary");
                }
                NSArray *names=@[@"coding",@"coffee",@"stretching",@"napping"];
                double actionTimes[]={run+3,2*run+13,3*run+21,4*run+27};
                for(int i=0;i<4;i++) Require([[actorView activityNameAtTime:actionTimes[i] width:width] isEqual:names[i]], @"all autonomous activities scheduled");
                if (width >= 685) {
                    CWScene first=[actorView autonomousSceneAtTime:1 width:width];
                    CWScene second=[actorView autonomousSceneAtTime:2 width:width];
                    Require(fabs(second.anchorX-first.anchorX-64)<.01, @"running speed independent of width");
                }
                [NSLayoutConstraint deactivateConstraints:edges];
                [view removeFromSuperview];
            }
            Require(![[view valueForKey:@"animating"] boolValue], @"initially stopped");
            [widget performSelector:@selector(viewWillAppear)];
            [widget performSelector:@selector(viewDidAppear)];
            Require([[view valueForKey:@"animating"] boolValue], @"appearing starts timer");
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            Require([[view valueForKey:@"animationTime"] doubleValue] > 0.05, @"clock advances");
            [widget performSelector:@selector(prepareForCustomization)];
            Require([[view valueForKey:@"animating"] boolValue], @"customization leaves active widget running");
            NSImage *image = [widget valueForKey:@"imageForCustomization"];
            Require(NSEqualSizes(image.size, NSMakeSize(176, 30)), @"customization image");
            Require([view accessibilityPerformPress], @"accessible mad reaction");
            [NSWorkspace.sharedWorkspace.notificationCenter postNotificationName:NSWorkspaceWillSleepNotification object:nil];
            double sleepingTime=actorView.animationTime;
            CWScene sleeping=[actorView sceneAtTime:sleepingTime width:1000];
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.06]];
            CWScene stillSleeping=[actorView sceneAtTime:actorView.animationTime width:1000];
            Require(stillSleeping.activity==sleeping.activity && fabs(stillSleeping.baseTime-sleeping.baseTime)<.001, @"sleep freezes reaction and base timeline together");
            Require(![[view valueForKey:@"animating"] boolValue], @"sleep suspends timer");
            [NSWorkspace.sharedWorkspace.notificationCenter postNotificationName:NSWorkspaceDidWakeNotification object:nil];
            Require([[view valueForKey:@"animating"] boolValue], @"wake resumes visible timer");
            [widget performSelector:@selector(viewWillDisappear)];
            [widget performSelector:@selector(viewDidDisappear)];
            Require(![[view valueForKey:@"animating"] boolValue], @"disappearing stops timer");
            double stopped = [[view valueForKey:@"animationTime"] doubleValue];
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.08]];
            Require(fabs([[view valueForKey:@"animationTime"] doubleValue] - stopped) < 0.001, @"hidden clock stays frozen");
            [NSWorkspace.sharedWorkspace.notificationCenter postNotificationName:NSWorkspaceDidWakeNotification object:nil];
            Require(![[view valueForKey:@"animating"] boolValue], @"wake does not activate hidden widget");
            __weak id releasedView = nil;
            @autoreleasepool {
                id transient = [[principal alloc] init];
                releasedView = [transient valueForKey:@"view"];
                [transient performSelector:@selector(viewWillAppear)];
            }
            Require(releasedView == nil, @"timer does not retain released widget");
            // Explicit timestamps exercise exact reaction pause/resume, independently
            // of wall time and timer scheduling.
            for(NSNumber *baseValue in @[@1, @5, @40]) {
                ClawdView *interaction;
                id interactionWidget=[[principal alloc] init];
                interaction=[interactionWidget valueForKey:@"view"];
                double when=baseValue.doubleValue;
                CWScene base=[interaction sceneAtTime:when width:176];
                NSPoint center=NSMakePoint(base.anchorX+15,NSMidY(base.actorBounds));
                Require(![interaction handleTapAtPoint:NSMakePoint(175,0) time:when width:176], @"empty strip ignores tap");
                Require([interaction handleTapAtPoint:center time:when width:176], @"visible actor becomes mad");
                CWScene angry=[interaction sceneAtTime:when+.5 width:176];
                Require(angry.activity==CWActivityMad && fabs(angry.anchorX-base.anchorX)<.01 && fabs(angry.baseTime-base.baseTime)<.01, @"mad stays anchored and freezes underlying activity");
                Require([interaction handleTapAtPoint:NSMakePoint(angry.anchorX+15,16) time:when+.5 width:176], @"repeated actor tap restarts reaction");
                Require(fabs([interaction baseTimeAtTime:when+2.9]-when)<.0001, @"repeated tap keeps original base sample frozen");
                Require(fabs([interaction baseTimeAtTime:when+3.0]-when)<.0001, @"reaction resumes exact frozen scene without jump");
                Require(fabs([interaction baseTimeAtTime:when+3.4]-(when+.4))<.0001, @"reaction pause accumulated once");
                NSBitmapImageRep *neutral=[interaction bitmapAtTime:when width:176 scale:1];
                for(NSNumber *reactionAge in @[@0,@2.49999]) {
                    NSBitmapImageRep *edge=[interaction bitmapAtTime:when width:176 scale:1 reactionAge:reactionAge.doubleValue];
                    Require(neutral.bytesPerRow==edge.bytesPerRow && memcmp(neutral.bitmapData,edge.bitmapData,neutral.bytesPerRow*neutral.pixelsHigh)==0, @"reaction enters and settles to exact underlying pose pixels");
                }
            }
            {
                id propWidget=[[principal alloc] init];
                ClawdView *propView=[propWidget valueForKey:@"view"];
                double run=[propView journeyDurationForWidth:176]/2;
                CWScene coding=[propView autonomousSceneAtTime:run+3 width:176];
                Require(![propView handleTapAtPoint:NSMakePoint(coding.anchorX-12,20) time:run+3 width:176], @"laptop alone ignores tap");
                CWScene coffee=[propView autonomousSceneAtTime:2*run+13 width:176];
                BOOL foundProp=NO;
                for(NSInteger i=coffee.pixelCount-1;i>=0;i--) {
                    CWPixel pixel=coffee.pixels[i];
                    if(pixel.ink!=CWInkCup || pixel.actor) continue;
                    NSPoint point=NSMakePoint(NSMidX(pixel.rect),NSMidY(pixel.rect));
                    Require(![propView handleTapAtPoint:point time:2*run+13 width:176], @"cup alone ignores tap");
                    foundProp=YES; break;
                }
                Require(foundProp,@"coffee has a held cup");
            }
            CheckTouchDelivery(view.class);
            puts("PASS: direct Touch Bar responder delivery, x-only finger targeting, indirect/blank/prop filtering, duplicate mouse suppression; activities, actor-only hits, anchored mad pause/resume/repeated taps; actual PockKit conformance, flexible widths64/176/685/1000, full travel, stable speed, customization, lifecycle, clock, sleep/wake, accessibility, release.");
            return 0;
        }
        NSURL *executable = [NSURL fileURLWithPath:@(argv[0])].URLByStandardizingPath;
        NSURL *root = executable.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
        NSBundle *previewBundle = [NSBundle bundleWithURL:[root URLByAppendingPathComponent:@"dist/Clawd.pock"]];
        NSError *previewError;
        Require([previewBundle loadAndReturnError:&previewError], previewError.description ?: @"preview bundle load");
        ClawdView *view = [[NSClassFromString(@"ClawdView") alloc] initWithFrame:NSMakeRect(0, 0, 685, 30)];
        Require(view != nil, @"bundle renderer available");
        if ([mode isEqualToString:@"--reaction"]) {
            Require(argc>2,@"usage: ClawdTools --reaction directory [width]");
            NSString *directory=@(argv[2]);
            CGFloat width=argc>3?MAX(64,atoi(argv[3])):176;
            [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
            double time=[view journeyDurationForWidth:width]/4;
            for(int i=0;i<50;i++) {
                NSData *png=[[view bitmapAtTime:time width:width scale:1 reactionAge:i/20.0] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                NSString *file=[NSString stringWithFormat:@"frame-%03d.png",i];
                Require([png writeToFile:[directory stringByAppendingPathComponent:file] atomically:YES],@"write reaction frame");
            }
            NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"width":@(width),@"frames":@50,@"duration":@2.5} options:NSJSONWritingPrettyPrinted error:NULL];
            [json writeToFile:[directory stringByAppendingPathComponent:@"manifest.json"] atomically:YES];
            puts("Exported the actual 2.5s mad reaction, including anticipation and settling.");
            return 0;
        }
        if ([mode isEqualToString:@"--poses"]) {
            Require(argc>2,@"usage: ClawdTools --poses directory [width]");
            NSString *directory=@(argv[2]);
            CGFloat width=argc>3?MAX(64,atoi(argv[3])):176;
            [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
            double run=[view journeyDurationForWidth:width]/2;
            NSArray *names=@[@"run",@"code-setup",@"code-type",@"code-pack",@"coffee-setup",@"coffee-sip",@"coffee-lower",@"stretch-gather",@"stretch-yawn",@"stretch-recover",@"nap-settle",@"nap-sleep",@"nap-wake",@"mad-running",@"mad-coding",@"mad-napping"];
            double times[]={run/2,run+.35,run+4,run+9.6,2*run+10+.35,2*run+13.8,2*run+17.6,3*run+18+.35,3*run+20.8,3*run+23.6,4*run+24+.35,4*run+28,4*run+33.6,run/2,run+4,4*run+28};
            NSMutableArray *poses=[NSMutableArray array];
            for(NSInteger i=0;i<(NSInteger)names.count;i++) {
                double reaction=i>=13?.7:-1;
                NSString *filename=[NSString stringWithFormat:@"%02ld-%@.png",(long)i,names[i]];
                NSData *png=[[view bitmapAtTime:times[i] width:width scale:1 reactionAge:reaction] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                Require([png writeToFile:[directory stringByAppendingPathComponent:filename] atomically:YES],@"write action pose");
                [poses addObject:@{@"name":names[i],@"time":@(times[i]),@"reactionAge":@(reaction),@"file":filename}];
            }
            NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"width":@(width),@"poses":poses} options:NSJSONWritingPrettyPrinted error:NULL];
            [json writeToFile:[directory stringByAppendingPathComponent:@"poses.json"] atomically:YES];
            puts("Exported every action's setup, main action, recovery, plus mad reactions.");
            return 0;
        }
        if ([mode isEqualToString:@"--export"]) {
            Require(argc > 2, @"usage: ClawdTools --export directory [width]");
            NSString *directory = @(argv[2]);
            CGFloat width = argc > 3 ? MAX(64, atoi(argv[3])) : 685;
            double duration = [view sceneDurationForWidth:width];
            int count = (int)ceil(duration * 20);
            [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
            for (int i = 0; i < count; i++) {
                NSBitmapImageRep *bitmap = [view bitmapAtTime:i * duration / count width:width scale:1];
                NSData *data = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"frame-%03d.png", i]];
                Require([data writeToFile:path atomically:YES], @"write PNG frame");
            }
            NSDictionary *manifest = @{@"width": @(width), @"frames": @(count), @"duration": @(duration)};
            NSData *json = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:NULL];
            [json writeToFile:[directory stringByAppendingPathComponent:@"manifest.json"] atomically:YES];
            printf("Exported %d actual AppKit frames (%gpt width, %.2fs loop).\n", count, width, duration);
            return 0;
        }
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 170) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        window.title = @"Clawd · Pock Touch Bar preview";
        window.backgroundColor = [NSColor colorWithWhite:0.09 alpha:1];
        window.releasedWhenClosed = NO;
        window.contentMinSize = NSMakeSize(112, 150);
        NSTextField *title = [NSTextField labelWithString:@"A little company for your Touch Bar."];
        title.textColor = NSColor.whiteColor;
        title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightMedium];
        title.frame = NSMakeRect(28, 120, 350, 24);
        [window.contentView addSubview:title];
        [window.contentView addSubview:view];
        [NSLayoutConstraint activateConstraints:@[
            [view.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor constant:24],
            [view.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor constant:-24],
            [view.centerYAnchor constraintEqualToAnchor:window.contentView.centerYAnchor]
        ]];
        NSTextField *hint = [NSTextField labelWithString:@"Resize the bar · poke Clawd himself for a tiny tantrum"];
        hint.textColor = NSColor.secondaryLabelColor;
        hint.font = [NSFont systemFontOfSize:11];
        hint.frame = NSMakeRect(28, 28, 500, 20);
        [window.contentView addSubview:hint];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:window queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [NSApp terminate:nil]; }];
        [window center];
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        [view startAnimation];
        [NSApp run];
    }
    return 0;
}
