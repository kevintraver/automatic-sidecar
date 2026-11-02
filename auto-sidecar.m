// auto-sidecar: start Sidecar when an iPad is plugged in over USB-C, and stop it when unplugged.
//
//   auto-sidecar               watch for an iPad on a USB-C port and connect/disconnect Sidecar (run by the LaunchAgent)
//   auto-sidecar connect       connect Sidecar once and exit
//   auto-sidecar disconnect    disconnect Sidecar once and exit
//   auto-sidecar list          list Sidecar-capable devices
//
// Set AUTO_SIDECAR_DEVICE to a device name to pick one iPad when several are available.

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <notify.h>

@interface SidecarDevice : NSObject
@property (readonly) NSString *name;
@property (readonly) NSUUID *identifier;
@property (readonly) unsigned long long status;
@end

@interface SidecarDisplayManager : NSObject
+ (instancetype)sharedManager;
- (NSArray<SidecarDevice *> *)devices;
- (NSArray<SidecarDevice *> *)connectedDevices;
- (void)connectToDevice:(SidecarDevice *)device completion:(void (^)(NSError *))completion;
- (void)disconnectFromDevice:(SidecarDevice *)device completion:(void (^)(NSError *))completion;
@end

// SidecarDevice.status is Rapport's device-flag word; this bit means the device is reachable over USB
// (SidecarRelay names it "USB"). Sidecar only runs a session over the cable once it's set.
static const unsigned long long kSidecarStatusUSB = 0x1000000;

static SidecarDisplayManager *manager(void) {
    return [NSClassFromString(@"SidecarDisplayManager") sharedManager];
}

static SidecarDevice *targetDevice(void) {
    NSString *wanted = NSProcessInfo.processInfo.environment[@"AUTO_SIDECAR_DEVICE"];
    for (SidecarDevice *d in manager().devices) {
        if (!wanted || [d.name isEqualToString:wanted]) return d;
    }
    return nil;
}

static void after(double seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

static void disconnectSidecar(void (^done)(void)) {
    NSArray<SidecarDevice *> *connected = manager().connectedDevices;
    if (connected.count == 0) {
        done();
        return;
    }
    __block NSUInteger pending = connected.count;
    for (SidecarDevice *device in connected) {
        NSLog(@"Disconnecting Sidecar from %@", device.name);
        [manager() disconnectFromDevice:device completion:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) NSLog(@"Sidecar disconnect failed: %@", error.localizedDescription);
                else NSLog(@"Sidecar disconnected from %@", device.name);
                if (--pending == 0) done();
            });
        }];
    }
}

// The USB-C port controller reads the identity of what's plugged in over USB Power Delivery. Unlike the
// USB device list, this doesn't flap while the iPad enumerates, and it still works after a restart, when
// macOS doesn't register an iPad that stayed plugged in as a USB device.
static BOOL iPadOnUSBCPort(void) {
    io_iterator_t iterator;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccessoryManager"), &iterator) != KERN_SUCCESS) return NO;
    BOOL found = NO;
    io_service_t port;
    while ((port = IOIteratorNext(iterator))) {
        id maker = CFBridgingRelease(IORegistryEntryCreateCFProperty(port, CFSTR("SOPMfgString"), kCFAllocatorDefault, 0));
        id active = CFBridgingRelease(IORegistryEntryCreateCFProperty(port, CFSTR("ConnectionActive"), kCFAllocatorDefault, 0));
        if ([active isEqual:@YES] && [maker isKindOfClass:NSString.class] && [maker hasPrefix:@"iPad"]) found = YES;
        IOObjectRelease(port);
    }
    IOObjectRelease(iterator);
    return found;
}

// After an unplug, Sidecar's session is stuck on the dead USB link, and a disconnect sent on it never
// reaches the iPad, which then sits on "Connection lost". Within a few seconds Sidecar's video stream times
// out and it reconnects over wireless (AWDL): SidecarDisplayAgent logs "=== Sidecar Connected ... [AWDL] ===",
// then "AVCVideoStream-didStart" once video is flowing to the iPad again. A disconnect sent before video
// restarts still leaves "Connection lost" on screen for a few seconds; one sent after it puts the iPad
// straight to sleep. If the iPad is gone entirely (for example, unplugged while the Mac slept), the
// reconnect fails instead and Sidecar logs "Reconnect Failed". Watch for these, briefly.
// Runs `log stream` with a predicate, stores it in *slot, and hands each real entry (not log stream's own
// header, which repeats the predicate) to the handler on the main queue while *slot still holds it.
static void startLogWatch(NSTask *__strong *slot, NSString *process, NSString *predicate, void (^onLine)(NSString *line)) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/log"];
    task.arguments = @[@"stream", @"--style", @"compact", @"--predicate",
                       [NSString stringWithFormat:@"process == \"%@\" AND (%@)", process, predicate]];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSString *entryMarker = [process stringByAppendingString:@"["];  // compact entries read "... process[pid:tid] ..."
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length == 0) {  // EOF: the stream was stopped. Clear the handler (else it fires forever) and close the pipe (else its fd leaks).
            handle.readabilityHandler = nil;
            [handle closeFile];
            return;
        }
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
            if (![line containsString:entryMarker]) continue;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (*slot == task) onLine(line);
            });
        }
    };
    NSError *error;
    if (![task launchAndReturnError:&error]) {
        NSLog(@"Could not start log stream: %@", error.localizedDescription);
        return;
    }
    *slot = task;
}

static NSTask *sessionWatch = nil;    // during an unplug: is the session back on wireless?
static NSTask *directLinkWatch = nil; // during a plug-in: has rapportd found the iPad over the cable?

static void stopSessionWatch(void) {
    [sessionWatch terminate];
    sessionWatch = nil;
}

static void stopDirectLinkWatch(void) {
    [directLinkWatch terminate];
    directLinkWatch = nil;
}

static void startSessionWatch(void (^onReady)(NSString *reason)) {
    stopSessionWatch();
    __block BOOL onWireless = NO;
    startLogWatch(&sessionWatch, @"SidecarDisplayAgent",
        @"eventMessage CONTAINS \"=== Sidecar Connected\" OR eventMessage CONTAINS \"AVCVideoStream-didStart\" OR "
         "eventMessage CONTAINS \"Reconnect Failed\"",
        ^(NSString *line) {
            if ([line containsString:@"Reconnect Failed"]) onReady(@"Sidecar could not reconnect");
            else if ([line containsString:@"=== Sidecar Connected"]) onWireless = ![line containsString:@"[Direct]"];
            else if (onWireless && [line containsString:@"AVCVideoStream-didStart"]) onReady(@"Sidecar moved to wireless");
        });
}

static BOOL pluggedIn = NO;     // an iPad is on a USB-C port
static BOOL wantConnect = NO;   // plugged in, and Sidecar not yet started for this plug-in
static BOOL connecting = NO;
static BOOL directLinkUp = NO;  // rapportd has found the iPad over the cable since it was plugged in
static int connectFailures = 0;
static const int kMaxConnectFailures = 3;
static NSUInteger unplugGeneration = 0;  // bumped to cancel a pending unplug
static const double kUnplugFallbackSeconds = 10;  // if neither log line shows up

static void handleUnplug(void);

// Connect once the iPad is reachable over the cable: rapportd logs "Bonjour device changed ... DirectLink"
// when it finds the iPad on the cable's network link. Sidecar's own USB flag says the same, but SidecarRelay
// publishes it to clients several seconds late. Called on plug-in, on that log line, and on every change to
// Sidecar's device list, so there's nothing to poll or retry on a timer.
static void tryConnect(void) {
    if (!wantConnect || connecting) return;
    if (manager().connectedDevices.count > 0) {
        NSLog(@"Sidecar already connected");
        wantConnect = NO;
        stopDirectLinkWatch();
        return;
    }
    SidecarDevice *device = targetDevice();
    if (!device || !(directLinkUp || (device.status & kSidecarStatusUSB))) return;  // not ready; a later event calls again
    connecting = YES;
    NSLog(@"Connecting Sidecar to %@", device.name);
    [manager() connectToDevice:device completion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            connecting = NO;
            if (error) {
                NSLog(@"Sidecar connect failed: %@", error.localizedDescription);
                if (++connectFailures >= kMaxConnectFailures) {
                    NSLog(@"Giving up on connecting Sidecar");
                    wantConnect = NO;
                    stopDirectLinkWatch();
                }
                return;  // tried again on the next device change
            }
            NSLog(@"Sidecar connected to %@", device.name);
            wantConnect = NO;
            stopDirectLinkWatch();
            if (!pluggedIn) handleUnplug();  // unplugged while connecting
        });
    }];
}

static void handleUnplug(void) {
    NSUInteger mine = ++unplugGeneration;
    if (connecting) return;  // the connect's completion handles it
    if (manager().connectedDevices.count == 0) return;
    void (^finish)(NSString *) = ^(NSString *reason) {
        if (mine != unplugGeneration) return;
        ++unplugGeneration;
        NSLog(@"%@; disconnecting", reason);
        stopSessionWatch();
        disconnectSidecar(^{});
    };
    startSessionWatch(finish);
    after(kUnplugFallbackSeconds, ^{ finish(@"Did not see Sidecar move to wireless"); });
}

static void portsChanged(void) {
    BOOL now = iPadOnUSBCPort();
    if (now == pluggedIn) return;
    pluggedIn = now;
    if (now) {
        NSLog(@"iPad plugged in");
        ++unplugGeneration;
        stopSessionWatch();
        wantConnect = YES;
        connectFailures = 0;
        directLinkUp = NO;
        stopDirectLinkWatch();
        startLogWatch(&directLinkWatch, @"rapportd",
            @"eventMessage BEGINSWITH \"Bonjour device\" AND eventMessage CONTAINS \"DirectLink\"",
            ^(NSString *line) {
                directLinkUp = ![line containsString:@"Bonjour device lost"];
                tryConnect();
            });
        tryConnect();
    } else {
        NSLog(@"iPad unplugged; disconnecting Sidecar once it has moved to wireless");
        wantConnect = NO;
        stopDirectLinkWatch();
        handleUnplug();
    }
}

static void portMessage(void *refcon, io_service_t service, natural_t messageType, void *argument) {
    portsChanged();
}

static int watch(void) {
    // The kernel sends a general-interest message on a USB-C port whenever its properties change,
    // including ConnectionActive on plug-in and unplug.
    IONotificationPortRef notifyPort = IONotificationPortCreate(kIOMainPortDefault);
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort), kCFRunLoopDefaultMode);
    io_iterator_t ports;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccessoryManager"), &ports);
    if (kr != KERN_SUCCESS) {
        NSLog(@"Could not list USB-C ports: 0x%x", kr);
        return 1;
    }
    io_service_t port;
    while ((port = IOIteratorNext(ports))) {
        io_object_t notification;
        kr = IOServiceAddInterestNotification(notifyPort, port, kIOGeneralInterest, portMessage, NULL, &notification);
        if (kr != KERN_SUCCESS) NSLog(@"Could not watch a USB-C port: 0x%x", kr);
        IOObjectRelease(port);
    }
    IOObjectRelease(ports);

    // SidecarRelay bumps this whenever a device's status changes, such as the iPad becoming reachable over USB.
    NSString *deviceGeneration = [NSString stringWithFormat:@"user.uid.%d.com.apple.sidecar-relay.device-generation", getuid()];
    int token;
    notify_register_dispatch(deviceGeneration.UTF8String, &token, dispatch_get_main_queue(), ^(int t) { tryConnect(); });

    NSLog(@"Watching for an iPad on USB-C");
    portsChanged();  // an iPad already plugged in, including after a restart
    // Drain a pool per pass: objects Foundation autoreleases on the main thread (such as each stopped
    // log stream's NSTask and pipe) would otherwise pile up in main's pool, which never drains.
    for (;;) @autoreleasepool {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1e10, true);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (!dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_NOW)) {
            NSLog(@"Could not load SidecarCore: %s", dlerror());
            return 1;
        }
        NSString *command = argc > 1 ? @(argv[1]) : @"watch";

        if ([command isEqualToString:@"list"]) {
            NSArray *connected = manager().connectedDevices;
            for (SidecarDevice *d in manager().devices) {
                printf("%s%s%s\n", d.name.UTF8String, (d.status & kSidecarStatusUSB) ? " (USB)" : "",
                       [connected containsObject:d] ? " (connected)" : "");
            }
            return 0;
        }
        if ([command isEqualToString:@"connect"]) {
            SidecarDevice *device = targetDevice();
            if (!device) {
                fprintf(stderr, "No Sidecar device found\n");
                return 1;
            }
            [manager() connectToDevice:device completion:^(NSError *error) {
                if (error) NSLog(@"Sidecar connect failed: %@", error.localizedDescription);
                exit(error ? 1 : 0);
            }];
            CFRunLoopRun();
            return 1;
        }
        if ([command isEqualToString:@"disconnect"]) {
            disconnectSidecar(^{ exit(0); });
            CFRunLoopRun();
            return 1;
        }
        if ([command isEqualToString:@"watch"]) return watch();

        fprintf(stderr, "usage: auto-sidecar [watch|connect|disconnect|list]\n");
        return 2;
    }
}
