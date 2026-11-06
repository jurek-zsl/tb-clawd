// Objective-C surface of PockKit's @objc(PKWidget) protocol.
// Derived from pock/pockkit, PKWidget.swift, copyright Pierluigi Galdi,
// distributed under the MIT license. See ../THIRD_PARTY_NOTICES.md.
// Pock supplies the protocol at runtime; no second PockKit framework is bundled.
#import <AppKit/AppKit.h>

@protocol PKWidget
@required
+ (NSString *)identifier;
@property(nonatomic, copy) NSString *customizationLabel;
@property(nonatomic, strong) NSView *view;
- (instancetype)init;
@optional
@property(nonatomic, readonly) NSImage *imageForCustomization;
- (void)prepareForCustomization;
- (void)viewWillAppear;
- (void)viewDidAppear;
- (void)viewWillDisappear;
- (void)viewDidDisappear;
@end
