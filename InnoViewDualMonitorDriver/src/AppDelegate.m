#import "AppDelegate.h"

#import <ServiceManagement/ServiceManagement.h>

#import "Controller.h"
#include "log.h"

@implementation AppDelegate {
    NSStatusItem *_item;
    MSController *_controller;
    NSTimer *_timer;
    double _fps, _mbps;
    __weak NSMenuItem *_statsItem;  // updated in place, also while the menu is open
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    _item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    menu.autoenablesItems = NO;
    _item.menu = menu;

    _controller = [[MSController alloc] init];
    __weak AppDelegate *weakSelf = self;
    _controller.changed = ^{
      [weakSelf refresh];
    };
    [self refresh];
    [_controller start];
    [self setupLoginItem];

    NSNotificationCenter *nc = NSWorkspace.sharedWorkspace.notificationCenter;
    [nc addObserver:self selector:@selector(willSleep:) name:NSWorkspaceWillSleepNotification object:nil];
    [nc addObserver:self selector:@selector(didWake:) name:NSWorkspaceDidWakeNotification object:nil];
    [nc addObserver:self selector:@selector(screensDidSleep:) name:NSWorkspaceScreensDidSleepNotification object:nil];
    [nc addObserver:self selector:@selector(screensDidWake:) name:NSWorkspaceScreensDidWakeNotification object:nil];

    // Common modes: the timer keeps firing while the menu is open (event tracking mode).
    _timer = [NSTimer timerWithTimeInterval:0.5
                                    repeats:YES
                                      block:^(NSTimer *t) {
                                        [weakSelf tick];
                                      }];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    msx_log("quitting");
    [_timer invalidate];
    [_controller shutdown];
    return NSTerminateNow;
}

- (void)willSleep:(NSNotification *)n {
    [_controller systemWillSleep];
}
- (void)didWake:(NSNotification *)n {
    [_controller systemDidWake];
}
- (void)screensDidSleep:(NSNotification *)n {
    [_controller displaysDidSleep];
}
- (void)screensDidWake:(NSNotification *)n {
    [_controller displaysDidWake];
}

- (void)tick {
    [_controller takeStatsFps:&_fps mbps:&_mbps];
    _statsItem.title = [self statsText];
}

- (NSString *)statsText {
    return [NSString stringWithFormat:@"%.0f fps · %.1f MB/s", _fps, _mbps];
}

#pragma mark - Status item

- (NSString *)stateText {
    switch (_controller.state) {
    case MSStateStarting: return @"Starting…";
    case MSStateNoDevice: return @"Monitor not connected";
    case MSStateBusy: return @"Device busy";
    case MSStateError: return @"Error, retrying…";
    case MSStateWaitSink: return @"Waiting for the monitor";
    case MSStateWaitFrame: return @"Waiting for the first frame";
    case MSStateStreaming: return @"Running";
    case MSStateBlanked: return @"Screen asleep";
    case MSStateSleeping: return @"Sleeping";
    }
    return @"";
}

- (void)refresh {
    MSState s = _controller.state;
    NSString *symbol = @"display";
    if (s == MSStateBusy || s == MSStateError || _controller.captureDenied)
        symbol = @"exclamationmark.triangle";
    else if (s == MSStateStreaming && _controller.usbSpeed == 2)
        symbol = @"display.trianglebadge.exclamationmark";
    NSImage *img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:@"InnoViewDualMonitorDriver"];
    img.template = YES;
    _item.button.image = img;
    _item.button.appearsDisabled = s == MSStateNoDevice || s == MSStateSleeping || s == MSStateStarting;
    _item.button.toolTip = [NSString stringWithFormat:@"InnoViewDualMonitorDriver — %@", [self stateText]];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [self rebuildMenu:menu];
}

- (NSMenuItem *)info:(NSString *)title {
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    it.enabled = NO;
    return it;
}

- (NSMenuItem *)action:(NSString *)title selector:(SEL)sel {
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title action:sel keyEquivalent:@""];
    it.target = self;
    return it;
}

- (void)rebuildMenu:(NSMenu *)menu {
    [menu removeAllItems];
    _statsItem = nil;
    MSState s = _controller.state;
    int speed = _controller.usbSpeed;

    NSString *head = [self stateText];
    NSString *detail = _controller.detail;
    if (detail.length) head = [NSString stringWithFormat:@"%@: %@", head, detail];
    [menu addItem:[self info:head]];
    if (speed) [menu addItem:[self info:speed == 3 ? @"USB 3 (5 Gbit/s)" : @"USB 2.0 (480 Mbit/s)"]];
    if (s == MSStateStreaming) {
        NSMenuItem *stats = [self info:[self statsText]];
        [menu addItem:stats];
        _statsItem = stats;
    }
    if (speed == 2 && s != MSStateNoDevice) {
        NSMenuItem *w = [self info:@"⚠︎ USB 2.0: the monitor gave all USB‑C lanes to DisplayPort,\n"
                                   @"the frame rate will be low. Reconnecting the cable helps."];
        [menu addItem:w];
    }
    if (s == MSStateBusy)
        [menu addItem:[self info:@"Quit MSDisplayManager (its menu bar icon → Exit)"]];
    if (_controller.captureDenied) {
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItem:[self action:@"No Screen Recording permission — Open Settings…"
                          selector:@selector(openScreenRecordingSettings:)]];
        if (_controller.needsRelaunch)
            [menu addItem:[self action:@"Permission Granted — Relaunch InnoViewDualMonitorDriver" selector:@selector(relaunch:)]];
    }

    if (_controller.displayID) {
        [menu addItem:[NSMenuItem separatorItem]];
        CGSize cur = [_controller currentSize];
        for (NSValue *v in [_controller supportedSizes]) {
            CGSize sz = v.sizeValue;
            NSMenuItem *it = [self action:[NSString stringWithFormat:@"%.0f × %.0f", sz.width, sz.height]
                                 selector:@selector(selectMode:)];
            it.representedObject = v;
            it.state = CGSizeEqualToSize(sz, cur) ? NSControlStateValueOn : NSControlStateValueOff;
            [menu addItem:it];
        }
        if (_controller.rotated) [menu addItem:[self info:@"Panel is upside down — picture rotated 180°"]];
        [menu addItem:[self action:@"Displays Settings…" selector:@selector(openDisplaySettings:)]];
    }

    [menu addItem:[NSMenuItem separatorItem]];
    if (_controller.gpuAvailable) {
        NSMenu *sub = [[NSMenu alloc] init];
        NSMenuItem *gpu = [self action:@"GPU (Metal)" selector:@selector(selectGPU:)];
        NSMenuItem *cpu = [self action:@"CPU" selector:@selector(selectCPU:)];
        gpu.state = _controller.convertOnGPU ? NSControlStateValueOn : NSControlStateValueOff;
        cpu.state = _controller.convertOnGPU ? NSControlStateValueOff : NSControlStateValueOn;
        [sub addItem:gpu];
        [sub addItem:cpu];
        NSMenuItem *conv = [[NSMenuItem alloc] initWithTitle:@"Pixel Conversion" action:nil keyEquivalent:@""];
        conv.submenu = sub;
        [menu addItem:conv];
    }
    if ([self isInstalled]) {
        SMAppServiceStatus st = SMAppService.mainAppService.status;
        NSMenuItem *login = [self action:@"Launch at Login" selector:@selector(toggleLoginItem:)];
        login.state = st == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:login];
        if (st == SMAppServiceStatusRequiresApproval)
            [menu addItem:[self action:@"Allow in Login Items…" selector:@selector(openLoginItems:)]];
    }
    [menu addItem:[self action:@"Open Log" selector:@selector(openLog:)]];
    NSMenuItem *quit = [self action:@"Quit" selector:@selector(quit:)];
    quit.keyEquivalent = @"q";
    [menu addItem:quit];
}

#pragma mark - Actions

- (void)selectGPU:(id)sender {
    _controller.convertOnGPU = YES;
}

- (void)selectCPU:(id)sender {
    _controller.convertOnGPU = NO;
}

- (void)selectMode:(NSMenuItem *)item {
    [_controller selectSize:[item.representedObject sizeValue]];
}

- (void)openScreenRecordingSettings:(id)sender {
    [NSWorkspace.sharedWorkspace
        openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
}

- (void)openDisplaySettings:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Displays-Settings.extension"]];
}

- (void)openLog:(id)sender {
    const char *path = msx_log_path();
    NSString *p = [NSString stringWithUTF8String:path ? path : msx_log_dir()];
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:p]];
}

- (void)relaunch:(id)sender {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[
        @"-c", @"while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"", @"sh",
        [NSString stringWithFormat:@"%d", NSProcessInfo.processInfo.processIdentifier], NSBundle.mainBundle.bundlePath
    ];
    [task launchAndReturnError:nil];
    [NSApp terminate:nil];
}

#pragma mark - Login item

// Only a copy in an Applications folder registers itself, never a build directory.
- (BOOL)isInstalled {
    NSString *dir = NSBundle.mainBundle.bundlePath.stringByDeletingLastPathComponent;
    return [dir isEqualToString:@"/Applications"] ||
           [dir isEqualToString:[NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]];
}

- (void)setupLoginItem {
    if (![self isInstalled] || [NSUserDefaults.standardUserDefaults boolForKey:@"LoginItemOff"]) return;
    SMAppService *svc = SMAppService.mainAppService;
    if (svc.status == SMAppServiceStatusEnabled) return;
    NSError *err = nil;
    if ([svc registerAndReturnError:&err])
        msx_log("login item registered");
    else
        msx_log("login item registration failed: %s", err.localizedDescription.UTF8String);
}

- (void)toggleLoginItem:(id)sender {
    SMAppService *svc = SMAppService.mainAppService;
    NSError *err = nil;
    BOOL enable = svc.status != SMAppServiceStatusEnabled;
    BOOL ok = enable ? [svc registerAndReturnError:&err] : [svc unregisterAndReturnError:&err];
    msx_log("login item %s: %s", enable ? "on" : "off", ok ? "ok" : err.localizedDescription.UTF8String);
    if (ok) [NSUserDefaults.standardUserDefaults setBool:!enable forKey:@"LoginItemOff"];
}

- (void)openLoginItems:(id)sender {
    [SMAppService openSystemSettingsLoginItems];
}

- (void)quit:(id)sender {
    [NSApp terminate:nil];
}

@end
