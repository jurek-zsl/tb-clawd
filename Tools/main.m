#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "ClawdView.h"

static const double CWLiveSleepAfterForTests = 5*60;
int CWRunShowcase(NSString *output, NSBundle *clawdBundle, NSBundle *liveBundle);

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

// ---------------------------------------------------------------- live ---

static NSString *CWTempClaudeDirectory(void) {
    NSString *dir=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"clawd-live-%d-%u",getpid(),arc4random()]];
    [NSFileManager.defaultManager createDirectoryAtPath:[dir stringByAppendingPathComponent:@"sessions"] withIntermediateDirectories:YES attributes:nil error:NULL];
    [NSFileManager.defaultManager createDirectoryAtPath:[dir stringByAppendingPathComponent:@"clawd"] withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}
static void CWWriteJSON(NSString *path, id object) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    Require([data writeToFile:path atomically:YES],@"write fixture");
}
static void CWWriteSession(NSString *dir, int pid, NSString *status, double ageSeconds) {
    double ms=(NSDate.date.timeIntervalSince1970-ageSeconds)*1000;
    CWWriteJSON([dir stringByAppendingPathComponent:[NSString stringWithFormat:@"sessions/%d.json",pid]],
        @{@"pid":@(pid),@"sessionId":@"fixture",@"status":status,@"updatedAt":@(ms),@"statusUpdatedAt":@(ms)});
}
static void CWClearSessions(NSString *dir) {
    NSString *sessions=[dir stringByAppendingPathComponent:@"sessions"];
    for(NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:sessions error:NULL])
        [NSFileManager.defaultManager removeItemAtPath:[sessions stringByAppendingPathComponent:name] error:NULL];
}
// Steps the live director like the 30 Hz timer and checks he never teleports.
static CWScene CWAdvance(ClawdView *view, double *clock, double seconds, CGFloat width) {
    CWScene scene=[view sceneAtTime:*clock width:width];
    double end=*clock+seconds;
    while(*clock<end) {
        double before=scene.anchorX;
        *clock+=1.0/30;
        scene=[view sceneAtTime:*clock width:width];
        Require(fabs(scene.anchorX-before)<4.5,@"live acting moves continuously, no teleports");
        for(NSInteger i=0;i<scene.pixelCount;i++) {
            NSRect r=scene.pixels[i].rect;
            Require(NSMinX(r)>=0 && NSMaxX(r)<=width && NSMinY(r)>=0 && NSMaxY(r)<=30,@"live pixels fit strip");
        }
        Require(scene.pixelCount<256,@"live scene within pixel budget");
    }
    return scene;
}
static BOOL CWToolHitsActor(CWScene scene, NSPoint point) {
    for(NSInteger i=scene.pixelCount-1;i>=0;i--) if(NSPointInRect(point,scene.pixels[i].rect)) return scene.pixels[i].actor;
    return NO;
}
static BOOL CWSceneHasInk(CWScene scene, CWInk ink) {
    for(NSInteger i=0;i<scene.pixelCount;i++) if(scene.pixels[i].ink==ink) return YES;
    return NO;
}

// ------------------------------------------------ the claude binary check ---

static NSString *CWWriteScript(NSString *dir, NSString *name, NSString *body) {
    NSString *path=[dir stringByAppendingPathComponent:name];
    Require([[@"#!/bin/sh\n" stringByAppendingString:body] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL],@"write fake claude");
    chmod(path.fileSystemRepresentation,0755);
    return path;
}
static void CWSpin(double seconds, BOOL (^until)(void)) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while([end timeIntervalSinceNow]>0 && !(until && until()))
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];
}
static void CWTapActor(ClawdView *view, double time, CGFloat width) {
    CWScene scene=[view sceneAtTime:time width:width];
    Require([view handleTapAtPoint:NSMakePoint(NSMidX(scene.actorBounds),NSMidY(scene.actorBounds)) time:time width:width],@"tap Clawd");
}
static ClawdView *CWFreshLive(Class widgetClass, NSString *dir) {
    ClawdView *view=[[[widgetClass alloc] init] valueForKey:@"view"];
    view.claudeDirectory=dir;
    return view;
}
static void CheckClaudeBinary(Class widgetClass) {
    NSString *dir=CWTempClaudeDirectory();
    setenv("CLAWD_TEST_DIR",dir.fileSystemRepresentation,1);
    NSString *ok=CWWriteScript(dir,@"claude-ok",[@[
        @"echo \"$@\" > \"$CLAWD_TEST_DIR/args.txt\"",
        @"now=$(date +%s)",
        @"printf '{\"pid\":%s,\"status\":\"busy\",\"statusUpdatedAt\":%s000}' $$ $now > \"$CLAWD_TEST_DIR/sessions/$$.json\"",
        @"sleep 0.7",
        @"echo '{\"type\":\"system\",\"subtype\":\"init\"}'",
        @"printf '{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"allowed\",\"unifiedWindows\":{\"five_hour\":{\"utilization\":0.30,\"resetsAt\":%s},\"seven_day\":{\"utilization\":0.91,\"resetsAt\":%s}}}}\\n' $((now+4800)) $((now+259200))",
        @"echo '{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"ok\"}'",
        @"rm -f \"$CLAWD_TEST_DIR/sessions/$$.json\""] componentsJoinedByString:@"\n"]);
    for(NSNumber *widthValue in @[@176,@64]) {
        CGFloat width=widthValue.doubleValue;
        CWClearSessions(dir);
        ClawdView *view=CWFreshLive(widgetClass,dir);
        view.claudeExecutable=ok;
        double clock=10;
        CWScene scene=CWAdvance(view,&clock,1,width);
        Require([view.liveStateName isEqual:@"asleep"],@"fixture starts asleep");
        CWTapActor(view,clock,width);
        // While the check runs it is a live, busy Claude session on disk. Clawd
        // must not mistake it for real work.
        CWSpin(.3,nil);
        NSString *sessions=[dir stringByAppendingPathComponent:@"sessions"];
        Require([[NSFileManager.defaultManager contentsOfDirectoryAtPath:sessions error:NULL] count]==1,@"the check registered a busy session while running");
        view.claudeDirectory=dir;   // force an immediate re-read
        scene=CWAdvance(view,&clock,.3,width);
        Require([view.liveStateName isEqual:@"asleep"],@"the widget's own limits check never wakes Clawd");
        CWSpin(5,^BOOL{ return CWSceneHasInk([view sceneAtTime:10 width:width],CWInkCode); });
        scene=CWAdvance(view,&clock,.5,width);
        Require(CWSceneHasInk(scene,CWInkCode) && CWSceneHasInk(scene,CWInkLow),@"limits from the binary's rate_limit_event: 30% used shows green, 91% used shows red");
        Require(view.limitsNote.length==0,@"success leaves no failure note");
        NSString *args=[NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"args.txt"] encoding:NSUTF8StringEncoding error:NULL];
        for(NSString *flag in @[@"-p",@"stream-json",@"--tools",@"--no-session-persistence",@"haiku",@"--setting-sources",@"--strict-mcp-config"])
            Require([args containsString:flag],[NSString stringWithFormat:@"minimal check runs with %@",flag]);
        [view handleTapAtPoint:NSMakePoint(1,1) time:clock width:width];
    }

    // Every way the check can fail names its reason and shows no bars.
    struct { NSString *name, *body, *note; } failures[]={
        {@"claude-login",@"echo '{\"type\":\"result\",\"subtype\":\"error\",\"is_error\":true,\"result\":\"Not logged in · Please run /login\"}'\nexit 1",@"NO LOGIN"},
        {@"claude-nolimits",@"echo '{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"ok\"}'",@"NO LIMITS"},
        {@"claude-garbage",@"echo 'segfault, probably'\nexit 2",@"FAILED"},
        {@"claude-missing",nil,@"NO CLAUDE"},
    };
    for(int i=0;i<4;i++) {
        ClawdView *view=CWFreshLive(widgetClass,dir);
        view.claudeExecutable=failures[i].body?CWWriteScript(dir,failures[i].name,failures[i].body):@"/nonexistent/claude";
        double clock=10;
        CWAdvance(view,&clock,1,176);
        CWTapActor(view,clock,176);
        CWSpin(4,^BOOL{ return view.limitsNote.length>0; });
        Require([view.limitsNote isEqual:failures[i].note],[NSString stringWithFormat:@"%@ is reported as %@, got %@",failures[i].name,failures[i].note,view.limitsNote]);
        CWScene scene=CWAdvance(view,&clock,.4,176);
        Require(CWSceneHasInk(scene,CWInkWarn) && !CWSceneHasInk(scene,CWInkCode) && !CWSceneHasInk(scene,CWInkLow),@"failure shows its reason, not bars");
    }
    {
        // A stuck check is stopped at the timeout and reported, not left running.
        ClawdView *view=CWFreshLive(widgetClass,dir);
        view.claudeExecutable=CWWriteScript(dir,@"claude-slow",@"exec sleep 30");
        view.usageTimeout=.6;
        double clock=10, started=CFAbsoluteTimeGetCurrent();
        CWAdvance(view,&clock,1,176);
        CWTapActor(view,clock,176);
        CWSpin(5,^BOOL{ return view.limitsNote.length>0; });
        Require([view.limitsNote isEqual:@"FAILED"] && CFAbsoluteTimeGetCurrent()-started<4,@"a stuck check is stopped at the timeout");
    }
    {
        // The check stops as soon as Claude Code has reported the limits, instead
        // of waiting for the whole reply.
        CWClearSessions(dir);
        ClawdView *view=CWFreshLive(widgetClass,dir);
        view.claudeExecutable=CWWriteScript(dir,@"claude-lingers",[@[
            @"now=$(date +%s)",
            @"echo '{\"type\":\"system\",\"subtype\":\"init\"}'",
            @"printf '{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":{\"five_hour\":{\"utilization\":0.5,\"resetsAt\":%s},\"seven_day\":{\"utilization\":0.1,\"resetsAt\":%s}}}}\\n' $((now+3600)) $((now+86400))",
            @"exec sleep 20"] componentsJoinedByString:@"\n"]);
        double clock=10, started=CFAbsoluteTimeGetCurrent();
        CWAdvance(view,&clock,1,176);
        CWTapActor(view,clock,176);
        id monitor=[view valueForKey:@"monitor"];
        CWSpin(8,^BOOL{ return ![[monitor valueForKey:@"fetching"] boolValue]; });
        Require(CFAbsoluteTimeGetCurrent()-started<4,@"the check ends as soon as the limits event arrives, not when the reply ends");
        Require(CWSceneHasInk([view sceneAtTime:clock+.1 width:176],CWInkCode),@"and its numbers are shown");
    }
    unsetenv("CLAWD_TEST_DIR");
}

static void CheckLive(Class widgetClass) {
    NSString *dir=CWTempClaudeDirectory();
    for(NSNumber *widthValue in @[@64,@176,@685,@1000]) {
        CGFloat width=widthValue.doubleValue;
        id widget=[[widgetClass alloc] init];
        ClawdView *view=[widget valueForKey:@"view"];
        Require(view.live,@"live widget builds a live view");
        // Never touch the real Keychain or network from tests.
        view.usageFetcher=^(void (^done)(NSDictionary *)){ done(nil); };
        CWClearSessions(dir);
        [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:@"clawd/limits.json"] error:NULL];
        view.claudeDirectory=dir;
        double clock=10;
        CWScene scene=CWAdvance(view,&clock,1,width);
        Require([view.liveStateName isEqual:@"asleep"] && scene.activity==CWActivityNap,@"no sessions: Clawd sleeps");
        Require(fabs(scene.anchorX-[view anchorMinForWidth:width])<.01,@"sleeps at home");

        CWWriteSession(dir,getpid(),@"busy",0); view.claudeDirectory=dir;
        scene=CWAdvance(view,&clock,[view journeyDurationForWidth:width]/2+4,width);   // there, and a few seconds into coding
        Require([view.liveStateName isEqual:@"working"],@"busy session reads as working");
        Require(scene.activity==CWActivityCode && fabs(scene.anchorX-[view anchorMaxForWidth:width])<.01,@"working: Clawd runs to the laptop and codes");
        Require(CWSceneHasInk(scene,CWInkLaptop),@"working shows the laptop");

        CWWriteSession(dir,getpid(),@"waiting",0); view.claudeDirectory=dir;
        scene=CWAdvance(view,&clock,3,width);
        Require([view.liveStateName isEqual:@"waiting"] && scene.activity==CWActivityWave,@"waiting session: Clawd waves for you");

        CWWriteSession(dir,getpid(),@"idle",0); view.claudeDirectory=dir;
        scene=CWAdvance(view,&clock,2.5,width);
        Require([view.liveStateName isEqual:@"idle"] && scene.activity!=CWActivityWave && scene.activity!=CWActivityCode,@"recently idle: Clawd leaves the laptop and wanders");

        CWWriteSession(dir,getpid(),@"idle",CWLiveSleepAfterForTests+60); view.claudeDirectory=dir;
        scene=CWAdvance(view,&clock,22,width);
        Require([view.liveStateName isEqual:@"asleep"] && scene.activity==CWActivityNap,@"long idle: Clawd goes to sleep");

        CWClearSessions(dir);
        CWWriteSession(dir,99999,@"busy",0); view.claudeDirectory=dir;
        CWAdvance(view,&clock,2,width);
        Require([view.liveStateName isEqual:@"asleep"],@"a session file whose process is gone is ignored");

        // Tap: limits, never the tantrum. Unknown limits first, then real data.
        scene=[view sceneAtTime:clock width:width];
        NSPoint body=NSMakePoint(scene.anchorX+NSWidth(scene.actorBounds)/2,NSMidY(scene.actorBounds));
        Require(CWToolHitsActor(scene,body),@"fixture point lands on Clawd");
        Require([view handleTapAtPoint:body time:clock width:width],@"tapping live Clawd is accepted");
        scene=CWAdvance(view,&clock,.5,width);
        Require(scene.activity==CWActivityLimits,@"live tap shows limits, not mad");
        Require(CWSceneHasInk(scene,CWInkText),@"limits readout says it has no data");
        Require([view handleTapAtPoint:NSMakePoint(1,1) time:clock width:width],@"second tap dismisses the readout");
        Require(![view showingLimitsAtTime:clock],@"readout dismissed");

        double now=NSDate.date.timeIntervalSince1970;
        CWWriteJSON([dir stringByAppendingPathComponent:@"clawd/limits.json"],@{@"model":[NSNull null],@"rate_limits":@{
            @"five_hour":@{@"used_percentage":@42,@"resets_at":@(now+80*60)},
            @"seven_day":@{@"used_percentage":@91.5,@"resets_at":[[NSISO8601DateFormatter new] stringFromDate:[NSDate dateWithTimeIntervalSinceNow:3*86400]]}}});
        view.claudeDirectory=dir;
        scene=[view sceneAtTime:clock width:width];
        body=NSMakePoint(NSMidX(scene.actorBounds),NSMidY(scene.actorBounds));
        Require([view handleTapAtPoint:body time:clock width:width],@"tap with data");
        scene=CWAdvance(view,&clock,1,width);
        Require(CWSceneHasInk(scene,CWInkCode),@"58% left draws a healthy bar");
        Require(CWSceneHasInk(scene,CWInkLow),@"8% left draws a low bar");
        scene=CWAdvance(view,&clock,3.2,width);
        Require(scene.activity!=CWActivityLimits,@"readout puts itself away after 4 seconds");
    }
    for(NSNumber *widthValue in @[@176,@685]) {
        // Tapping him mid-run stops him in place: no sliding, no floating.
        CGFloat width=widthValue.doubleValue;
        id widget=[[widgetClass alloc] init];
        ClawdView *view=[widget valueForKey:@"view"];
        view.usageFetcher=^(void (^done)(NSDictionary *)){ done(nil); };
        CWClearSessions(dir);
        CWWriteSession(dir,getpid(),@"idle",0); view.claudeDirectory=dir;
        double clock=10;
        CWScene scene=CWAdvance(view,&clock,.4,width);
        for(int i=0;i<300 && !(scene.activity==CWActivityRun && scene.travelledDistance>10);i++) scene=CWAdvance(view,&clock,1.0/30,width);
        Require(scene.activity==CWActivityRun && scene.travelledDistance>10,@"idle Clawd is running");
        double where=scene.anchorX;
        Require([view handleTapAtPoint:NSMakePoint(NSMidX(scene.actorBounds),NSMidY(scene.actorBounds)) time:clock width:width],@"tap the running Clawd");
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];   // the (empty) check answers
        for(int i=0;i<110;i++) {
            scene=CWAdvance(view,&clock,1.0/30,width);
            Require(scene.activity==CWActivityLimits && fabs(scene.anchorX-where)<.01,@"Clawd stands still while the readout is open");
        }
        scene=CWAdvance(view,&clock,1,width);
        Require(scene.activity==CWActivityRun && fabs(scene.anchorX-where)>1 && fabs(scene.anchorX-where)<70,@"after the readout he runs on from the same spot");
        // Dismissing early resumes right away.
        scene=CWAdvance(view,&clock,.1,width);
        if(scene.activity==CWActivityRun) {
            where=scene.anchorX;
            [view handleTapAtPoint:NSMakePoint(NSMidX(scene.actorBounds),NSMidY(scene.actorBounds)) time:clock width:width];
            CWAdvance(view,&clock,.5,width);
            Require(fabs([view sceneAtTime:clock width:width].anchorX-where)<.01,@"still paused before dismissal");
            [view handleTapAtPoint:NSMakePoint(1,1) time:clock width:width];
            scene=CWAdvance(view,&clock,.3,width);
            Require(scene.activity!=CWActivityLimits && fabs(scene.anchorX-where)<25,@"dismissal resumes without a jump");
        }
    }
    {
        // A failed fetch says why instead of a bare "?": the readout draws the
        // fetcher's reason in the warning colour, and no reason keeps the "?".
        id widget=[[widgetClass alloc] init];
        ClawdView *view=[widget valueForKey:@"view"];
        CWClearSessions(dir);
        [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:@"clawd/limits.json"] error:NULL];
        __block NSString *reason=@"NO LOGIN";
        view.usageFetcher=^(void (^done)(NSDictionary *)){ done(reason.length?@{@"error":reason}:nil); };
        view.claudeDirectory=dir;
        double clock=10;
        CWScene scene=CWAdvance(view,&clock,1,176);
        Require([view handleTapAtPoint:NSMakePoint(NSMidX(scene.actorBounds),NSMidY(scene.actorBounds)) time:clock width:176],@"tap with failing fetch");
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        scene=CWAdvance(view,&clock,.5,176);
        Require(scene.activity==CWActivityLimits && CWSceneHasInk(scene,CWInkWarn),@"a failure reason is spelled out in the warning colour");
        Require(!CWSceneHasInk(scene,CWInkCode) && !CWSceneHasInk(scene,CWInkLow),@"no limit bars without data");
        Require(![view showingLimitsAtTime:clock+4.5] ,@"failure readout still times out");
    }
    {
        // Limits from the usage endpoint's JSON shape (utilization + ISO reset).
        id widget=[[widgetClass alloc] init];
        ClawdView *view=[widget valueForKey:@"view"];
        CWClearSessions(dir);
        [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:@"clawd/limits.json"] error:NULL];
        __block int calls=0;
        NSString *reset=[[NSISO8601DateFormatter new] stringFromDate:[NSDate dateWithTimeIntervalSinceNow:2*3600]];
        view.usageFetcher=^(void (^done)(NSDictionary *)){
            calls++;
            done(@{@"five_hour":@{@"utilization":@10,@"resets_at":reset},@"seven_day":@{@"utilization":@95,@"resets_at":[NSNull null]},@"seven_day_opus":[NSNull null]});
        };
        view.claudeDirectory=dir;
        double clock=10;
        CWScene scene=CWAdvance(view,&clock,1,176);
        Require([view handleTapAtPoint:NSMakePoint(NSMidX(scene.actorBounds),NSMidY(scene.actorBounds)) time:clock width:176],@"tap asks for usage");
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        scene=CWAdvance(view,&clock,.5,176);
        Require(calls==1,@"one usage request per tap");
        Require(CWSceneHasInk(scene,CWInkCode) && CWSceneHasInk(scene,CWInkLow),@"usage endpoint limits drive the readout");
        [view handleTapAtPoint:NSMakePoint(1,1) time:clock width:176];
        scene=[view sceneAtTime:clock width:176];
        [view handleTapAtPoint:NSMakePoint(NSMidX(scene.actorBounds),NSMidY(scene.actorBounds)) time:clock width:176];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        Require(calls==1,@"repeat taps within a minute reuse the last answer");
    }
    {
        // Waiting for a check shows three dots, never old numbers, and stays up
        // until the answer lands; then the numbers get their full time.
        id widget=[[widgetClass alloc] init];
        ClawdView *view=[widget valueForKey:@"view"];
        CWClearSessions(dir);
        NSString *limitsFile=[dir stringByAppendingPathComponent:@"clawd/limits.json"];
        CWWriteJSON(limitsFile,@{@"rate_limits":@{@"five_hour":@{@"used_percentage":@20},@"seven_day":@{@"used_percentage":@30}}});
        [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSinceNow:-600]} ofItemAtPath:limitsFile error:NULL];
        __block void (^answer)(NSDictionary *)=nil;
        view.usageFetcher=^(void (^done)(NSDictionary *)){ answer=[done copy]; };
        view.claudeDirectory=dir;
        double clock=10;
        CWAdvance(view,&clock,1,176);
        CWTapActor(view,clock,176);
        CWScene scene=CWAdvance(view,&clock,.5,176);
        Require(scene.activity==CWActivityLimits && answer!=nil,@"tap starts a check and opens the readout");
        Require(!CWSceneHasInk(scene,CWInkCode) && !CWSceneHasInk(scene,CWInkLow) && !CWSceneHasInk(scene,CWInkWarn),@"a reading older than five minutes is not shown while a new one is on its way");
        int dots=0, lit=0;
        for(NSInteger i=0;i<scene.pixelCount;i++) {
            if(scene.pixels[i].ink==CWInkText) lit++;
            if(scene.pixels[i].ink==CWInkText || scene.pixels[i].ink==CWInkSteam) dots++;
        }
        Require(dots==3 && lit==1,@"loading is three dots, one of them lit");
        scene=CWAdvance(view,&clock,7,176);
        Require(scene.activity==CWActivityLimits && !CWSceneHasInk(scene,CWInkCode),@"the readout waits for the check instead of timing out on dots");
        NSString *reset=[[NSISO8601DateFormatter new] stringFromDate:[NSDate dateWithTimeIntervalSinceNow:2*3600]];
        answer(@{@"five_hour":@{@"utilization":@40,@"resets_at":reset},@"seven_day":@{@"utilization":@10,@"resets_at":reset}});
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        scene=CWAdvance(view,&clock,.5,176);
        Require(CWSceneHasInk(scene,CWInkCode) && scene.activity==CWActivityLimits,@"the numbers replace the dots");
        scene=CWAdvance(view,&clock,3,176);
        Require(scene.activity==CWActivityLimits,@"the numbers stay for about four seconds after they land");
        scene=CWAdvance(view,&clock,1,176);
        Require(scene.activity!=CWActivityLimits,@"then he puts them away");
    }
    {
        // While Claude Code is in use the limits are fetched ahead of any tap,
        // and again right after a turn finishes, so a tap shows numbers at once.
        id widget=[[widgetClass alloc] init];
        ClawdView *view=[widget valueForKey:@"view"];
        CWClearSessions(dir);
        [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:@"clawd/limits.json"] error:NULL];
        __block int calls=0;
        NSString *reset=[[NSISO8601DateFormatter new] stringFromDate:[NSDate dateWithTimeIntervalSinceNow:2*3600]];
        view.usageFetcher=^(void (^done)(NSDictionary *)){
            calls++;
            done(@{@"five_hour":@{@"utilization":@40,@"resets_at":reset},@"seven_day":@{@"utilization":@10,@"resets_at":reset}});
        };
        view.claudeDirectory=dir;
        double clock=10;
        CWAdvance(view,&clock,1,176);
        Require(calls==0,@"no Claude Code running: no background checks");
        CWWriteSession(dir,getpid(),@"busy",0); view.claudeDirectory=dir;
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        Require(calls==1,@"Claude Code in use: the limits are fetched before anyone taps");
        CWScene scene=CWAdvance(view,&clock,1,176);
        CWTapActor(view,clock,176);
        scene=CWAdvance(view,&clock,.3,176);
        Require(scene.activity==CWActivityLimits && CWSceneHasInk(scene,CWInkCode),@"the tap shows numbers at once, no dots");
        Require(calls==1,@"and does not fetch again");
        [view handleTapAtPoint:NSMakePoint(1,1) time:clock width:176];
        id monitor=[view valueForKey:@"monitor"];
        double now=NSDate.date.timeIntervalSince1970;
        [monitor setValue:@(now-100) forKey:@"lastAttempt"];
        view.claudeDirectory=dir;
        Require(calls==1,@"fresh enough numbers are left alone");
        [monitor setValue:@(now-300) forKey:@"lastAttempt"];
        view.claudeDirectory=dir;
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        Require(calls==2,@"numbers over four minutes old are refreshed in the background");
        [monitor setValue:@(now-60) forKey:@"lastAttempt"];
        CWWriteSession(dir,getpid(),@"idle",0); view.claudeDirectory=dir;
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        Require(calls==3,@"a finished turn refreshes the numbers, which is when they change");
    }
    for(NSNumber *widthValue in @[@64,@176,@685,@1000]) {
        // While Claude works Clawd leaves the laptop: server rack, bug and rubber
        // duck in turn, running between them. Always continuous.
        CGFloat width=widthValue.doubleValue;
        id widget=[[widgetClass alloc] init];
        ClawdView *view=[widget valueForKey:@"view"];
        view.usageFetcher=^(void (^done)(NSDictionary *)){ done(nil); };
        CWClearSessions(dir);
        CWWriteSession(dir,getpid(),@"busy",0); view.claudeDirectory=dir;
        double clock=10;
        NSMutableSet<NSNumber *> *seen=[NSMutableSet set];
        double end=clock+[view journeyDurationForWidth:width]/2+[view workDurationForWidth:width]+6;
        CWScene scene;
        while(clock<end) {
            scene=CWAdvance(view,&clock,1.0/30,width);
            [seen addObject:@(scene.activity)];
            if(scene.activity==CWActivityServer) Require(CWSceneHasInk(scene,CWInkLaptop) || scene.age<.5 || scene.age>9,@"the server rack stands next to him");
            if(scene.activity==CWActivityDuck && scene.age>2 && scene.age<7.5) Require(CWSceneHasInk(scene,CWInkDuck),@"the rubber duck is out");
        }
        for(NSNumber *activity in @[@(CWActivityCode),@(CWActivityServer),@(CWActivityBug),@(CWActivityDuck),@(CWActivityRun)])
            Require([seen containsObject:activity],[NSString stringWithFormat:@"working visits every station (missing %@ at %g)",activity,width]);
        // Stopping work mid-station finishes the action and moves on.
        for(int i=0;i<30*120 && scene.activity!=CWActivityBug;i++) scene=CWAdvance(view,&clock,1.0/30,width);
        Require(scene.activity==CWActivityBug,@"reached the bug");
        CWWriteSession(dir,getpid(),@"idle",0); view.claudeDirectory=dir;
        scene=CWAdvance(view,&clock,3.5,width);
        Require([view.liveStateName isEqual:@"idle"] && scene.activity!=CWActivityBug,@"stopping work lets him finish and leave the station");
    }
    CheckClaudeBinary(widgetClass);
    [NSFileManager.defaultManager removeItemAtPath:dir error:NULL];
}


int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSString *mode = argc > 1 ? @(argv[1]) : @"--preview";
        if ([mode isEqualToString:@"--live"]) mode = @"--preview";
        if ([mode isEqualToString:@"--check-live"]) {
            Require(argc > 4, @"usage: ClawdTools --check-live live-bundle framework autonomous-bundle");
            Require(dlopen(argv[3], RTLD_NOW | RTLD_GLOBAL) != NULL, @"PockKit load");
            Protocol *hostProtocol = objc_getProtocol("PKWidget");
            NSError *error;
            NSBundle *other = [NSBundle bundleWithPath:@(argv[4])];
            Require([other loadAndReturnError:&error], error.description ?: @"autonomous bundle load");
            NSBundle *bundle = [NSBundle bundleWithPath:@(argv[2])];
            Require([bundle loadAndReturnError:&error], error.description ?: @"live bundle load");
            Class principal = bundle.principalClass;
            Require(principal != Nil && principal != other.principalClass, @"both widgets load side by side with distinct classes");
            Require(class_conformsToProtocol(principal, hostProtocol), @"live widget conforms to PockKit PKWidget");
            Require([[(id)principal performSelector:@selector(identifier)] isEqual:@"com.jurekzsl.pock.ClawdLive"], @"live identifier");
            id widget = [[principal alloc] init];
            Require([[widget valueForKey:@"customizationLabel"] isEqual:@"Clawd Live"], @"live label");
            id otherWidget = [[other.principalClass alloc] init];
            Require([widget valueForKey:@"view"] != nil && [[widget valueForKey:@"view"] class] != [[otherWidget valueForKey:@"view"] class], @"live view class is separate");
            Require(![[otherWidget valueForKey:@"view"] isLive], @"autonomous widget stays autonomous");
            Require(NSEqualSizes([[widget valueForKey:@"imageForCustomization"] size], NSMakeSize(176, 30)), @"live customization image");
            CheckLive(principal);
            puts("PASS: Clawd Live loads beside Clawd; sessions busy/waiting/idle/stale/dead map to coding, waving, wandering and sleeping with continuous travel; working visits the laptop, server rack, bug and rubber duck; tap shows limits (three dots while loading and never stale numbers, no data, healthy, low, from the status line file, from a fake claude binary that is stopped once the limits arrive, throttled, kept warm in the background) and dismisses; every check failure names its reason; a stuck check is stopped; the check's own session never wakes Clawd; a tapped runner stops in place and runs on from there; widths 64/176/685/1000 fit.");
            return 0;
        }
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
                Require(start.anchorX == [actorView anchorMinForWidth:width] && end.anchorX == [actorView anchorMaxForWidth:width], @"runs to both endpoint anchors");
                double boundaries[]={run,run+10,2*run+10,2*run+18,3*run+18,3*run+24,4*run+24,period};
                for(int i=0;i<8;i++) {
                    CWScene before=[actorView autonomousSceneAtTime:boundaries[i]-.00001 width:width];
                    CWScene after=[actorView autonomousSceneAtTime:boundaries[i]+.00001 width:width];
                    Require(fabs(before.anchorX-after.anchorX)<.01, @"timeline anchors continuous at every activity boundary");
                }
                NSArray *names=@[@"coding",@"coffee",@"stretching",@"napping"];
                double actionTimes[]={run+3,2*run+13,3*run+21,4*run+27};
                for(int i=0;i<4;i++) Require([[actorView activityNameAtTime:actionTimes[i] width:width] isEqual:names[i]], @"all autonomous activities scheduled");
                for(int sample=0;sample<240;sample++) {
                    CWScene scene=[actorView autonomousSceneAtTime:sample*period/240 width:width music:YES];
                    Require(scene.pixelCount>0 && scene.pixelCount<256,@"complete pose while music plays");
                    for(NSInteger i=0;i<scene.pixelCount;i++) {
                        NSRect pixel=scene.pixels[i].rect;
                        Require(NSMinX(pixel)>=0 && NSMaxX(pixel)<=width && NSMinY(pixel)>=0 && NSMaxY(pixel)<=30,@"dance and notes fit the strip");
                    }
                }
                for(int i=0;i<8;i++) {
                    CWScene before=[actorView autonomousSceneAtTime:boundaries[i]-.00001 width:width music:YES];
                    CWScene after=[actorView autonomousSceneAtTime:boundaries[i]+.00001 width:width music:YES];
                    Require(fabs(before.anchorX-after.anchorX)<.01,@"music timeline anchors continuous at every boundary");
                }
                CWScene stretching=[actorView autonomousSceneAtTime:3*run+21 width:width music:NO];
                CWScene dancing=[actorView autonomousSceneAtTime:3*run+21 width:width music:YES];
                CWScene napDancing=[actorView autonomousSceneAtTime:4*run+29 width:width music:YES];
                Require(stretching.activity==CWActivityStretch && dancing.activity==CWActivityDance && napDancing.activity==CWActivityDance,@"with music, stretching and napping become dancing");
                Require(CWSceneHasInk(dancing,CWInkNote) && !CWSceneHasInk(stretching,CWInkNote),@"dancing has music notes");
                Require(fabs(dancing.anchorX-stretching.anchorX)<.01 && fabs(dancing.baseTime-stretching.baseTime)<.01,@"switching to dancing keeps place and clock");
                NSMutableSet<NSString *> *moves=[NSMutableSet set];
                for(int k=0;k<8;k++) {
                    CWScene step=[actorView autonomousSceneAtTime:3*run+19.05+k*.25 width:width music:YES];
                    NSMutableString *signature=[NSMutableString string];
                    for(NSInteger i=0;i<step.pixelCount;i++) if(step.pixels[i].actor) [signature appendString:NSStringFromRect(step.pixels[i].rect)];
                    [moves addObject:signature];
                }
                Require(moves.count>=6,@"the dance changes pose on every beat");
                // A poke interrupts the dance in place, like any other activity.
                ClawdView *dancer=[[principal alloc] init] ? [[[principal alloc] init] valueForKey:@"view"] : nil;
                dancer.musicDetector=^BOOL{ return YES; };
                [dancer pollMusic]; [dancer pollMusic];
                double danceTime=3*run+21;
                CWScene dancingNow=[dancer sceneAtTime:danceTime width:width];
                Require(dancer.musicPlaying && dancingNow.activity==CWActivityDance,@"a view that hears music dances at the stretching slot");
                Require([dancer handleTapAtPoint:NSMakePoint(NSMidX(dancingNow.actorBounds),NSMidY(dancingNow.actorBounds)) time:danceTime width:width],@"poke the dancer");
                CWScene dancerMad=[dancer sceneAtTime:danceTime+.5 width:width];
                Require(dancerMad.activity==CWActivityMad && fabs(dancerMad.anchorX-dancingNow.anchorX)<.01 && !CWSceneHasInk(dancerMad,CWInkNote),@"a poked dancer stops where he stands, without notes");
                // The work loop that live Clawd follows while Claude is busy.
                {
                    double loop=[actorView workDurationForWidth:width];
                    NSMutableSet<NSNumber *> *seen=[NSMutableSet set];
                    NSMutableDictionary<NSNumber *, NSMutableSet<NSNumber *> *> *inks=[NSMutableDictionary dictionary];
                    CWScene start=[actorView workSceneAtTime:3 width:width];
                    Require(start.activity==CWActivityCode && fabs(start.anchorX-[actorView anchorMaxForWidth:width])<.01,@"the work loop starts at the laptop");
                    for(int i=0;i<=loop*20;i++) {
                        CWScene scene=[actorView workSceneAtTime:i/20.0 width:width];
                        CWScene next=[actorView workSceneAtTime:(i+1)/20.0 width:width];
                        Require(scene.pixelCount>0 && scene.pixelCount<256,@"work pose within budget");
                        Require(fabs(next.anchorX-scene.anchorX)<=4,@"work loop never jumps");
                        for(NSInteger p=0;p<scene.pixelCount;p++) {
                            NSRect pixel=scene.pixels[p].rect;
                            Require(NSMinX(pixel)>=0 && NSMaxX(pixel)<=width && NSMinY(pixel)>=0 && NSMaxY(pixel)<=30,@"work props fit the strip");
                            NSMutableSet *set=inks[@(scene.activity)];
                            if(!set) inks[@(scene.activity)]=set=[NSMutableSet set];
                            [set addObject:@(scene.pixels[p].ink)];
                        }
                        [seen addObject:@(scene.activity)];
                    }
                    Require(fabs([actorView workSceneAtTime:loop-.0001 width:width].anchorX-[actorView workSceneAtTime:0 width:width].anchorX)<.5,@"the work loop closes without a jump");
                    for(NSNumber *activity in @[@(CWActivityCode),@(CWActivityServer),@(CWActivityBug),@(CWActivityDuck),@(CWActivityRun)])
                        Require([seen containsObject:activity],@"work loop visits every station");
                    Require([inks[@(CWActivityServer)] containsObject:@(CWInkLaptop)] && [inks[@(CWActivityServer)] containsObject:@(CWInkCode)] && [inks[@(CWActivityServer)] containsObject:@(CWInkLow)],@"server rack with a red light that turns green");
                    Require([inks[@(CWActivityBug)] containsObject:@(CWInkLow)],@"a bug");
                    Require([inks[@(CWActivityDuck)] containsObject:@(CWInkDuck)] && [inks[@(CWActivityDuck)] containsObject:@(CWInkText)] && [inks[@(CWActivityDuck)] containsObject:@(CWInkWarn)],@"a rubber duck, a speech bubble and an idea");
                }
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
            {
                // Music detection: on after two positive readings, off after four
                // negative ones, so a gap between tracks does not stop the dance.
                ClawdView *listener=[[[principal alloc] init] valueForKey:@"view"];
                __block BOOL heard=YES;
                listener.musicDetector=^BOOL{ return heard; };
                [listener pollMusic];
                Require(!listener.musicPlaying,@"one reading is not music yet");
                [listener pollMusic];
                Require(listener.musicPlaying,@"two readings are");
                heard=NO;
                for(int i=0;i<3;i++) [listener pollMusic];
                Require(listener.musicPlaying,@"a short silence keeps the dance going");
                [listener pollMusic];
                Require(!listener.musicPlaying,@"four silent readings end it");
                Require([listener autonomousSceneAtTime:3*[listener journeyDurationForWidth:176]/2+21 width:176].activity==CWActivityStretch,@"no music: back to stretching");
            }
            CheckTouchDelivery(view.class);
            puts("PASS: music makes stretching and napping into dancing with notes (debounced detection, a poke stops the dance in place); the live work loop visits laptop, server rack, bug and duck within the strip; direct Touch Bar responder delivery, x-only finger targeting, indirect/blank/prop filtering, duplicate mouse suppression; activities, actor-only hits, anchored mad pause/resume/repeated taps; actual PockKit conformance, flexible widths64/176/685/1000, full travel, stable speed, customization, lifecycle, clock, sleep/wake, accessibility, release.");
            return 0;
        }
        NSURL *executable = [NSURL fileURLWithPath:@(argv[0])].URLByStandardizingPath;
        NSURL *root = executable.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
        if ([mode isEqualToString:@"--showcase"]) {
            Require(argc > 2, @"usage: ClawdTools --showcase directory");
            NSError *error;
            NSBundle *clawdBundle = [NSBundle bundleWithURL:[root URLByAppendingPathComponent:@"dist/Clawd.pock"]];
            NSBundle *liveBundle = [NSBundle bundleWithURL:[root URLByAppendingPathComponent:@"dist/ClawdLive.pock"]];
            Require([clawdBundle loadAndReturnError:&error] && [liveBundle loadAndReturnError:&error], error.description ?: @"showcase bundle load");
            return CWRunShowcase(@(argv[2]), clawdBundle, liveBundle);
        }
        BOOL live = NO;
        for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--live")) live = YES;
        NSBundle *previewBundle = [NSBundle bundleWithURL:[root URLByAppendingPathComponent:live ? @"dist/ClawdLive.pock" : @"dist/Clawd.pock"]];
        NSError *previewError;
        Require([previewBundle loadAndReturnError:&previewError], previewError.description ?: @"preview bundle load");
        id previewWidget = [[previewBundle.principalClass alloc] init];
        ClawdView *view = [previewWidget valueForKey:@"view"];
        view.translatesAutoresizingMaskIntoConstraints = NO;
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
        window.title = live ? @"Clawd Live · Pock Touch Bar preview" : @"Clawd · Pock Touch Bar preview";
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
        NSTextField *hint = [NSTextField labelWithString:live ? @"Follows your local Claude Code · tap Clawd for remaining limits" : @"Resize the bar · poke Clawd himself for a tiny tantrum"];
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
