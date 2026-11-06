#import "ClawdWidget.h"
#import "ClawdView.h"

@implementation ClawdWidget
+ (NSString *)identifier { return @"com.jurekzsl.pock.Clawd"; }
- (instancetype)init {
    self = [super init];
    if (self) {
        _customizationLabel = @"Clawd";
        _view = [[ClawdView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 30)];
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
