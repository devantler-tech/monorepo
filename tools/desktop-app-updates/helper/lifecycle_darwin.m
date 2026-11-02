#import <AppKit/AppKit.h>
#include "lifecycle.h"

int desktop_app_pids(const char *bundle_id, const char *app_path, int *pids, int capacity) {
    @autoreleasepool {
        NSString *identifier = [NSString stringWithUTF8String:bundle_id];
        NSArray<NSRunningApplication *> *apps =
            [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier];
        int count = 0;
        for (NSRunningApplication *app in apps) {
            if (app.terminated) continue;
            if (![app.bundleURL.path isEqualToString:[NSString stringWithUTF8String:app_path]]) {
                continue;
            }
            if (count >= capacity) return -1;
            pids[count++] = app.processIdentifier;
        }
        return count;
    }
}

int desktop_app_request_quit(const char *bundle_id, const char *app_path) {
    @autoreleasepool {
        NSString *identifier = [NSString stringWithUTF8String:bundle_id];
        NSArray<NSRunningApplication *> *apps =
            [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier];
        for (NSRunningApplication *app in apps) {
            // Another copy with the same bundle ID is outside this request.
            if (![app.bundleURL.path isEqualToString:[NSString stringWithUTF8String:app_path]]) continue;
            if (!app.terminated && ![app terminate]) return -1;
        }
        return 0;
    }
}

void desktop_app_pump(void) {
    @autoreleasepool {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
}
