// InnoViewDualMonitorDriver — driver for the MacroSilicon MS9132 USB display (InnoView INVPM009 top screen).
#import <AppKit/AppKit.h>

#import "AppDelegate.h"
#include "log.h"
#include "tools.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--probe") == 0) {
            msx_log_open(0);
            return msx_probe();
        }
        if (argc > 1 && strcmp(argv[1], "--pattern") == 0) {
            msx_log_open(0);
            return msx_pattern(argc > 2 ? atoi(argv[2]) : 10, argc > 3 && strcmp(argv[3], "full") == 0);
        }

        msx_log_open(1);
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        msx_log("InnoViewDualMonitorDriver %s started, macOS %s", [info[@"CFBundleShortVersionString"] UTF8String] ?: "dev",
                NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String);

        // SIGTERM/SIGINT: shut the device down cleanly.
        signal(SIGTERM, SIG_IGN);
        signal(SIGINT, SIG_IGN);
        static dispatch_source_t sources[2];
        int sigs[2] = {SIGTERM, SIGINT};
        for (int i = 0; i < 2; i++) {
            sources[i] = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sigs[i], 0, dispatch_get_main_queue());
            dispatch_source_set_event_handler(sources[i], ^{
              [NSApp terminate:nil];
            });
            dispatch_resume(sources[i]);
        }

        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        [app run];
    }
    return 0;
}
