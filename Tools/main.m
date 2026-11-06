#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "ClawdView.h"

static void Require(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

static NSRect ActorBounds(NSBitmapImageRep *bitmap) {
    NSInteger left = bitmap.pixelsWide, right = -1, top = bitmap.pixelsHigh, bottom = -1;
    for (NSInteger y = 0; y < bitmap.pixelsHigh; y++) {
        for (NSInteger x = 0; x < bitmap.pixelsWide; x++) {
            NSColor *color = [[bitmap colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            if (color.redComponent > 0.3 && color.greenComponent < 0.8) {
                left = MIN(left, x); right = MAX(right, x);
                top = MIN(top, y); bottom = MAX(bottom, y);
            }
        }
    }
    Require(right >= left, @"visible coral actor");
    return NSMakeRect(left, top, right - left + 1, bottom - top + 1);
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
                double period = [actorView journeyDurationForWidth:width];
                for (int sample = 0; sample < 32; sample++) {
                    NSBitmapImageRep *bitmap = [actorView bitmapAtTime:sample * period / 32 width:width scale:1];
                    Require(bitmap.pixelsWide == (NSInteger)width, @"renderer uses allocated width");
                    NSRect bounds = ActorBounds(bitmap);
                    Require(NSMinX(bounds) >= 7 && NSMaxX(bounds) <= width - 7 && NSMinY(bounds) >= 0 && NSMaxY(bounds) <= 30, @"actor remains inside complete strip");
                }
                NSRect start = ActorBounds([actorView bitmapAtTime:0 width:width scale:1]);
                NSRect end = ActorBounds([actorView bitmapAtTime:period / 2 width:width scale:1]);
                Require(NSMinX(start) == 8 && NSMaxX(end) == width - 8, @"reaches both allocated strip endpoints");
                if (width >= 685) {
                    NSRect first = ActorBounds([actorView bitmapAtTime:1 width:width scale:1]);
                    NSRect second = ActorBounds([actorView bitmapAtTime:2 width:width scale:1]);
                    Require(fabs(NSMinX(second) - NSMinX(first) - 64) <= 1, @"running speed independent of available width");
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
            Require([view accessibilityPerformPress], @"accessible hop action");
            [NSWorkspace.sharedWorkspace.notificationCenter postNotificationName:NSWorkspaceWillSleepNotification object:nil];
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
            puts("PASS: actual PockKit conformance, flexible widths64/176/685/1000, full travel, stable speed, customization, lifecycle, clock, sleep/wake, accessibility, release.");
            return 0;
        }
        NSURL *executable = [NSURL fileURLWithPath:@(argv[0])].URLByStandardizingPath;
        NSURL *root = executable.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
        NSBundle *previewBundle = [NSBundle bundleWithURL:[root URLByAppendingPathComponent:@"dist/Clawd.pock"]];
        NSError *previewError;
        Require([previewBundle loadAndReturnError:&previewError], previewError.description ?: @"preview bundle load");
        ClawdView *view = [[NSClassFromString(@"ClawdView") alloc] initWithFrame:NSMakeRect(0, 0, 685, 30)];
        Require(view != nil, @"bundle renderer available");
        if ([mode isEqualToString:@"--export"]) {
            Require(argc > 2, @"usage: ClawdTools --export directory [width]");
            NSString *directory = @(argv[2]);
            CGFloat width = argc > 3 ? MAX(64, atoi(argv[3])) : 685;
            double duration = [view journeyDurationForWidth:width];
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
        NSTextField *hint = [NSTextField labelWithString:@"Resize to change available width · click Clawd to hop"];
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
