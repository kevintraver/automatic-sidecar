// auto-sidecar: start Sidecar when an iPad is plugged in over USB.
//
//   auto-sidecar            watch for USB iPads and connect Sidecar (run by the LaunchAgent)
//   auto-sidecar connect    connect Sidecar once and exit
//   auto-sidecar list       list Sidecar-capable devices
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
@end

static BOOL connecting = NO;

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

// The iPad shows up in Sidecar's device list a moment after USB enumeration, so retry for a while.
static void connectSidecar(int attemptsLeft, void (^done)(BOOL ok)) {
    if (manager().connectedDevices.count > 0) {
        NSLog(@"Sidecar already connected");
        done(YES);
        return;
    }
    SidecarDevice *device = targetDevice();
    if (!device) {
        if (attemptsLeft <= 0) {
            NSLog(@"No Sidecar device found");
            done(NO);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            connectSidecar(attemptsLeft - 1, done);
        });
        return;
    }
    NSLog(@"Connecting Sidecar to %@", device.name);
    [manager() connectToDevice:device completion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) NSLog(@"Sidecar connect failed: %@", error);
            else NSLog(@"Sidecar connected to %@", device.name);
            done(error == nil);
        });
    }];
}

static void usbDeviceAdded(void *refcon, io_iterator_t iterator) {
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
    if (!sawIPad || connecting) return;
    NSLog(@"iPad plugged in");
    connecting = YES;
    connectSidecar(20, ^(BOOL ok) { connecting = NO; });
}

static int watch(void) {
    NSMutableDictionary *match = (__bridge_transfer NSMutableDictionary *)IOServiceMatching("IOUSBHostDevice");
    match[@kIOPropertyMatchKey] = @{@kUSBVendorID: @(kAppleVendorID)};

    IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port), kCFRunLoopDefaultMode);

    io_iterator_t iterator;
    kern_return_t kr = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
        (__bridge_retained CFDictionaryRef)match, usbDeviceAdded, NULL, &iterator);
    if (kr != KERN_SUCCESS) {
        NSLog(@"IOServiceAddMatchingNotification failed: 0x%x", kr);
        return 1;
    }
    // Drain existing matches to arm the notification; this also connects if an iPad is already plugged in.
    usbDeviceAdded(NULL, iterator);
    NSLog(@"Watching for USB iPads");
    CFRunLoopRun();
    return 0;
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
            connectSidecar(10, ^(BOOL ok) { exit(ok ? 0 : 1); });
            CFRunLoopRun();
            return 1;
        }
        if ([command isEqualToString:@"watch"]) return watch();

        fprintf(stderr, "usage: auto-sidecar [watch|connect|list]\n");
        return 2;
    }
}
