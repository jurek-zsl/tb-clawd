#import "PKWidget.h"

@interface ClawdWidget : NSObject <PKWidget>
@property(nonatomic, copy) NSString *customizationLabel;
@property(nonatomic, strong) NSView *view;
@end
