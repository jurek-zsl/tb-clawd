#import "ClawdWidget.h"
#import "ClawdView.h"

// One source, two bundles. build.sh compiles the live variant with
// CLAWD_LIVE=1 and renamed classes so both widgets can load in Pock at once.
#ifdef CLAWD_LIVE
static NSString *const ClawdIdentifier = @"com.jurekzsl.pock.ClawdLive";
static NSString *const ClawdLabel = @"Clawd Live";
static const BOOL ClawdIsLive = YES;
#else
static NSString *const ClawdIdentifier = @"com.jurekzsl.pock.Clawd";
static NSString *const ClawdLabel = @"Clawd";
static const BOOL ClawdIsLive = NO;
#endif

@implementation ClawdWidget
+ (NSString *)identifier { return ClawdIdentifier; }
- (instancetype)init {
    self = [super init];
    if (self) {
        _customizationLabel = ClawdLabel;
        _view = [[ClawdView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 30) live:ClawdIsLive];
    }
    return self;
}
- (NSImage *)imageForCustomization {
    NSBitmapImageRep *bitmap = [(ClawdView *)self.view bitmapAtTime:1.8 width:176 scale:2];
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(176, 30)];
    [image addRepresentation:bitmap];
    return image;
}
- (void)prepareForCustomization { self.view.needsDisplay = YES; }
- (void)viewWillAppear { [(ClawdView *)self.view startAnimation]; }
- (void)viewDidAppear { [(ClawdView *)self.view startAnimation]; }
- (void)viewWillDisappear { [(ClawdView *)self.view stopAnimation]; }
- (void)viewDidDisappear { [(ClawdView *)self.view stopAnimation]; }
@end
