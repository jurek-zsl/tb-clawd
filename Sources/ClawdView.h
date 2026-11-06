#import <AppKit/AppKit.h>
#import "ClawdScene.h"

@interface ClawdView : NSView
@property(nonatomic, readonly, getter=isAnimating) BOOL animating;
@property(nonatomic, readonly) NSTimeInterval animationTime;
- (void)startAnimation;
- (void)stopAnimation;
- (NSTimeInterval)baseTimeAtTime:(NSTimeInterval)time;
- (CWScene)autonomousSceneAtTime:(NSTimeInterval)time width:(CGFloat)width;
- (CWScene)sceneAtTime:(NSTimeInterval)time width:(CGFloat)width;
- (BOOL)handleTapAtPoint:(NSPoint)point time:(NSTimeInterval)time width:(CGFloat)width;
- (NSTimeInterval)sceneDurationForWidth:(CGFloat)width;
- (NSString *)activityNameAtTime:(NSTimeInterval)time width:(CGFloat)width;
- (NSTimeInterval)journeyDurationForWidth:(CGFloat)width;
- (NSBitmapImageRep *)bitmapAtTime:(NSTimeInterval)time width:(CGFloat)width scale:(NSInteger)scale;
- (NSBitmapImageRep *)bitmapAtTime:(NSTimeInterval)time width:(CGFloat)width scale:(NSInteger)scale reactionAge:(NSTimeInterval)reactionAge;
@end
