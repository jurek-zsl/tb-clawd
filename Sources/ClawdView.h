#import <AppKit/AppKit.h>
#import "ClawdScene.h"

@interface ClawdView : NSView
@property(nonatomic, readonly, getter=isAnimating) BOOL animating;
@property(nonatomic, readonly) NSTimeInterval animationTime;
- (instancetype)initWithFrame:(NSRect)frame live:(BOOL)live;
@property(nonatomic, readonly, getter=isLive) BOOL live;
// Live widget: the Claude Code directory it watches (default ~/.claude).
@property(nonatomic, copy) NSString *claudeDirectory;
@property(nonatomic, readonly) NSString *liveStateName;
// Live widget: how remaining limits are fetched (replaceable for tests).
@property(nonatomic, copy) void (^usageFetcher)(void (^completion)(NSDictionary *usage));
// Live widget: the claude binary to run for limits (nil = search) and the time
// allowed for one check.
@property(nonatomic, copy) NSString *claudeExecutable;
@property(nonatomic) NSTimeInterval usageTimeout;
@property(nonatomic, readonly) NSString *limitsNote;
// Autonomous widget: is music playing? The default asks CoreAudio whether any
// app is playing sound; tests replace it. Polled once a second, on after two
// positive polls and off after four negative ones, so a gap between tracks
// does not make him stop dancing. -pollMusic takes one reading now.
@property(nonatomic, copy) BOOL (^musicDetector)(void);
@property(nonatomic, readonly) BOOL musicPlaying;
- (void)pollMusic;
- (BOOL)showingLimitsAtTime:(NSTimeInterval)time;
- (void)startAnimation;
- (void)stopAnimation;
- (NSTimeInterval)baseTimeAtTime:(NSTimeInterval)time;
- (CWScene)autonomousSceneAtTime:(NSTimeInterval)time width:(CGFloat)width;
- (CWScene)autonomousSceneAtTime:(NSTimeInterval)time width:(CGFloat)width reactionAge:(NSTimeInterval)reactionAge;
- (CWScene)autonomousSceneAtTime:(NSTimeInterval)time width:(CGFloat)width music:(BOOL)music;
// The live widget's work loop (laptop, server, bug, duck), without a monitor.
- (CWScene)workSceneAtTime:(NSTimeInterval)time width:(CGFloat)width;
- (NSTimeInterval)workDurationForWidth:(CGFloat)width;
- (CWScene)sceneAtTime:(NSTimeInterval)time width:(CGFloat)width;
- (BOOL)handleTapAtPoint:(NSPoint)point time:(NSTimeInterval)time width:(CGFloat)width;
- (NSTimeInterval)sceneDurationForWidth:(CGFloat)width;
- (NSString *)activityNameAtTime:(NSTimeInterval)time width:(CGFloat)width;
- (NSTimeInterval)journeyDurationForWidth:(CGFloat)width;
- (CGFloat)anchorMinForWidth:(CGFloat)width;
- (CGFloat)anchorMaxForWidth:(CGFloat)width;
- (NSBitmapImageRep *)bitmapAtTime:(NSTimeInterval)time width:(CGFloat)width scale:(NSInteger)scale;
- (NSBitmapImageRep *)bitmapAtTime:(NSTimeInterval)time width:(CGFloat)width scale:(NSInteger)scale reactionAge:(NSTimeInterval)reactionAge;
@end
