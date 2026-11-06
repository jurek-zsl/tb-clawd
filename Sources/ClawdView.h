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
- (BOOL)showingLimitsAtTime:(NSTimeInterval)time;
- (void)startAnimation;
- (void)stopAnimation;
- (NSTimeInterval)baseTimeAtTime:(NSTimeInterval)time;
- (CWScene)autonomousSceneAtTime:(NSTimeInterval)time width:(CGFloat)width;
- (CWScene)autonomousSceneAtTime:(NSTimeInterval)time width:(CGFloat)width reactionAge:(NSTimeInterval)reactionAge;
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
