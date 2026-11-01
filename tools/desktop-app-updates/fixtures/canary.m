#import <AppKit/AppKit.h>
#include <unistd.h>

@interface CanaryDelegate : NSObject <NSApplicationDelegate>
@end
@implementation CanaryDelegate
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    NSString *resources = NSBundle.mainBundle.resourcePath;
    [@"normal quit requested" writeToFile:[resources stringByAppendingPathComponent:@"quit-observed"]
                             atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if ([NSFileManager.defaultManager fileExistsAtPath:[resources stringByAppendingPathComponent:@"refuse"]]) {
        return NSTerminateCancel;
    }
    return NSTerminateNow;
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        CanaryDelegate *delegate = [CanaryDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
