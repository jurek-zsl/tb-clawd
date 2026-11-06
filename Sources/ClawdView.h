#import <AppKit/AppKit.h>

@interface ClawdView : NSView
@property(nonatomic, readonly, getter=isAnimating) BOOL animating;
@property(nonatomic, readonly) NSTimeInterval animationTime;
- (void)startAnimation;
- (void)stopAnimation;
- (void)hop;
- (void)drawSceneInRect:(NSRect)rect time:(NSTimeInterval)time hopAge:(NSTimeInterval)hopAge;
- (NSTimeInterval)journeyDurationForWidth:(CGFloat)width;
- (NSBitmapImageRep *)bitmapAtTime:(NSTimeInterval)time width:(CGFloat)width scale:(NSInteger)scale;
@end
