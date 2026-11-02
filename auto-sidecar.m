// auto-sidecar: start Sidecar when an iPad is plugged in over USB, and stop it when unplugged.
//
//   auto-sidecar               watch for USB iPads and connect/disconnect Sidecar (run by the LaunchAgent)
//   auto-sidecar connect       connect Sidecar once and exit
//   auto-sidecar disconnect    disconnect Sidecar once and exit
//   auto-sidecar list          list Sidecar-capable devices
//
// Set AUTO_SIDECAR_DEVICE to a device name to pick one iPad when several are available.

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#include <dlfcn.h>

@interface SidecarDevice : NSObject
@property (readonly) NSString *name;
@property (readonly) NSUUID *identifier;
@end

@interface SidecarDisplayManager : NSObject
+ (instancetype)sharedManager;
- (NSArray<SidecarDevice *> *)devices;
- (NSArray<SidecarDevice *> *)connectedDevices;
- (void)connectToDevice:(SidecarDevice *)device completion:(void (^)(NSError *))completion;
- (void)disconnectFromDevice:(SidecarDevice *)device completion:(void (^)(NSError *))completion;
@end

typedef BOOL (^StillWanted)(void);

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

// The iPad can take a moment to show up in Sidecar's device list, and a connect can fail while USB
// is still settling, so retry until it works, attempts run out, or the connection is no longer wanted.
static void connectSidecar(int attemptsLeft, StillWanted stillWanted, void (^done)(BOOL ok)) {
    if (!stillWanted()) {
        done(NO);
        return;
    }
    if (manager().connectedDevices.count > 0) {
        NSLog(@"Sidecar already connected");
        done(YES);
        return;
    }
    void (^retry)(void) = ^{
        if (attemptsLeft <= 1) {
            NSLog(@"Giving up on connecting Sidecar");
            done(NO);
            return;
        }
        after(1, ^{ connectSidecar(attemptsLeft - 1, stillWanted, done); });
    };
    SidecarDevice *device = targetDevice();
    if (!device) {
        retry();
        return;
    }
    NSLog(@"Connecting Sidecar to %@", device.name);
    [manager() connectToDevice:device completion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                NSLog(@"Sidecar connect failed: %@", error.localizedDescription);
                retry();
                return;
            }
            NSLog(@"Sidecar connected to %@", device.name);
            done(YES);
        });
    }];
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

static NSDictionary *appleUSBMatch(void) {
    NSMutableDictionary *match = (__bridge_transfer NSMutableDictionary *)IOServiceMatching("IOUSBHostDevice");
    match[@kIOPropertyMatchKey] = @{@kUSBVendorID: @(kAppleVendorID)};
    return match;
}

static BOOL drainIPads(io_iterator_t iterator) {
    BOOL sawIPad = NO;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        CFStringRef product = IORegistryEntryCreateCFProperty(service, CFSTR(kUSBProductString), kCFAllocatorDefault, 0);
        if (product) {
            if ([(__bridge NSString *)product hasPrefix:@"iPad"]) sawIPad = YES;
            CFRelease(product);
        }
        IOObjectRelease(service);
    }
    return sawIPad;
}

static BOOL iPadOnUSB(void) {
    io_iterator_t iterator;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, (__bridge_retained CFDictionaryRef)appleUSBMatch(), &iterator) != KERN_SUCCESS) return NO;
    BOOL present = drainIPads(iterator);
    IOObjectRelease(iterator);
    return present;
}

// Sidecar logs "Data link type changed <old> -> <new>" when its session moves to another link. After an
// unplug, a change to a wireless link (AWDL) means a disconnect can now reach the iPad. Only watched
// briefly around an unplug.
static NSTask *linkWatch = nil;
static BOOL sawWirelessLink = NO;
static void (^onWirelessLink)(void) = nil;

static void stopLinkWatch(void) {
    [linkWatch terminate];
    linkWatch = nil;
}

// Called on every unplug. A watch can still be running from an earlier unplug (after a quick replug),
// so forget any wireless move seen before this unplug.
static void startLinkWatch(void) {
    sawWirelessLink = NO;
    if (linkWatch.running) return;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/log"];
    task.arguments = @[@"stream", @"--style", @"compact", @"--predicate",
                       @"process == \"SidecarRelay\" AND eventMessage CONTAINS \"Data link type changed\""];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length == 0) {  // EOF: the stream was stopped. Clear the handler (else it fires forever) and close the pipe (else its fd leaks).
            handle.readabilityHandler = nil;
            [handle closeFile];
            return;
        }
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
            NSRange arrow = [line rangeOfString:@"Data link type changed "];
            if (arrow.location == NSNotFound) continue;
            NSString *link = [[line componentsSeparatedByString:@"-> "].lastObject
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if ([link isEqualToString:@"Direct"] || [link isEqualToString:@"Unknown"]) continue;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (task != linkWatch) return;
                NSLog(@"Sidecar moved to %@", link);
                sawWirelessLink = YES;
                if (onWirelessLink) onWirelessLink();
            });
        }
    };
    NSError *error;
    if (![task launchAndReturnError:&error]) {
        NSLog(@"Could not start log stream: %@", error.localizedDescription);
        return;
    }
    linkWatch = task;
}

// Each USB change bumps the generation, so work started for an older state stops on its own.
static NSUInteger generation = 0;

// The iPad drops off USB and comes back while it enumerates, so wait for USB to settle,
// then make Sidecar match whether an iPad is plugged in.
//
// On unplug, a disconnect sent right away goes to the dead USB link and never reaches the iPad, which
// then sits on "Connection lost". Within a few seconds Sidecar's video stream times out and the session
// reconnects over wireless (AWDL), so wait for that and disconnect over it; the iPad then sleeps cleanly.
// If the move to wireless isn't seen in the log, disconnect after a fixed wait instead.
static const double kSettleSeconds = 2;
static const double kAfterWirelessSeconds = 0.5;
static const double kFallbackSeconds = 8;
static void usbChanged(void) {
    NSUInteger current = ++generation;
    after(kSettleSeconds, ^{
        if (current != generation) return;
        BOOL pluggedIn = iPadOnUSB();
        StillWanted stillWanted = ^BOOL { return current == generation; };
        if (pluggedIn) {
            stopLinkWatch();
            onWirelessLink = nil;
            NSLog(@"iPad plugged in");
            connectSidecar(20, stillWanted, ^(BOOL ok) {});
            return;
        }
        NSLog(@"iPad unplugged; disconnecting Sidecar once it has moved to wireless");
        __block BOOL finished = NO;
        void (^finish)(void) = ^{
            if (finished || !stillWanted()) return;
            finished = YES;
            onWirelessLink = nil;
            stopLinkWatch();
            disconnectSidecar(^{});
        };
        if (sawWirelessLink) {
            after(kAfterWirelessSeconds, finish);
        } else {
            onWirelessLink = ^{ after(kAfterWirelessSeconds, finish); };
            after(kFallbackSeconds, ^{
                if (!finished && stillWanted()) NSLog(@"Did not see Sidecar move to wireless; disconnecting anyway");
                finish();
            });
        }
    });
}

static void usbDeviceAdded(void *refcon, io_iterator_t iterator) {
    if (drainIPads(iterator)) usbChanged();
}

static void usbDeviceRemoved(void *refcon, io_iterator_t iterator) {
    if (!drainIPads(iterator)) return;
    startLinkWatch();  // start now: the move to wireless can happen before USB has settled
    usbChanged();
}

static int watch(void) {
    IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port), kCFRunLoopDefaultMode);

    io_iterator_t added, removed;
    kern_return_t kr = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
        (__bridge_retained CFDictionaryRef)appleUSBMatch(), usbDeviceAdded, NULL, &added);
    if (kr == KERN_SUCCESS) {
        kr = IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
            (__bridge_retained CFDictionaryRef)appleUSBMatch(), usbDeviceRemoved, NULL, &removed);
    }
    if (kr != KERN_SUCCESS) {
        NSLog(@"IOServiceAddMatchingNotification failed: 0x%x", kr);
        return 1;
    }
    // Drain existing matches to arm the notifications; this also connects if an iPad is already plugged in.
    usbDeviceAdded(NULL, added);
    drainIPads(removed);
    NSLog(@"Watching for USB iPads");
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
                printf("%s%s\n", d.name.UTF8String, [connected containsObject:d] ? " (connected)" : "");
            }
            return 0;
        }
        if ([command isEqualToString:@"connect"]) {
            connectSidecar(10, ^BOOL { return YES; }, ^(BOOL ok) { exit(ok ? 0 : 1); });
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
