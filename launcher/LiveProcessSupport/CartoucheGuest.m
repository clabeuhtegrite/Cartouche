//
//  CartoucheGuest.m
//  Cartouche
//
//  What a game played inside Cartouche does besides the game itself, in
//  LiveContainer's LiveProcess extension, where it runs in a process of its
//  own (launcher/Sources/CartoucheGameHost.swift). app/scripts/prepare.sh
//  copies this folder into LiveProcess/, and app/patches/livecontainer/0008
//  calls CartoucheGuestStart before LiveContainer starts the game.
//
//  - Its memory, every two seconds, in Cartouche/GameMemory.plist of the
//    app group, which Cartouche shows on its System page: how much the game
//    uses, the most it has used, and the limit iOS sets for its process,
//    measured as Cartouche measures its own (CartoucheDevice.swift). A game
//    that iOS stops for its memory leaves its last reading there. Each
//    change of the size of the game's screen goes there too, with the
//    memory at that moment (the iPhone Duo folded or unfolded). The keys:
//
//        bundle      the game's bundle folder, as LiveContainer names it
//        container   the game's data folder
//        pid         the game's process
//        started     when it started (date)
//        updated     the time of this reading (date)
//        footprint   the memory it uses, in bytes, as iOS counts it
//        peak        the most it has used since it started, in bytes
//        available   how much more iOS lets it use, in bytes
//        limit       footprint + available, in bytes
//        sizes       each size its screen took: time (date), width and
//                    height (points), footprint (bytes) at that moment
//        increasedMemoryLimit
//                    whether the process has Increased Memory Limit
//                    (boolean), as its signature gives it, written once as
//                    the game starts; missing when it cannot be read.
//                    Without it, iOS gives the game a fraction of what
//                    Cartouche has with it: 3,376 MiB against 8,192 on an
//                    iPhone with 12 GB (docs/decisions.md, 66)
//
//  - The Home button of a controller: nxnative leaves it to the game
//    without a use (DmGamepad.m). A press shows Cartouche's console, as the
//    Home button over the game does: this process posts the Darwin
//    notification CartoucheGameHome.<data folder>, which Cartouche listens
//    to while the game runs.
//

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <stddef.h>
#include <unistd.h>
#import "../../LiveContainer/LCSharedUtils.h"

static dispatch_queue_t measureQueue;
static dispatch_source_t measureTimer;
static NSString *memoryFile;
static NSString *homeNotification;
static NSMutableDictionary *reading;
static NSMutableArray *sizes;
static CGSize lastSize;
static uint64_t highestPeak;

/// The memory the game uses and the most it has used, as iOS counts them.
static BOOL CartoucheGuestFootprint(uint64_t *footprint, uint64_t *peak) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return NO;
    }
    *footprint = info.phys_footprint;
    // The peak came with a later revision of the structure than the
    // footprint: the kernel fills only what it knows.
    size_t peakEnd = offsetof(task_vm_info_data_t, ledger_phys_footprint_peak) + sizeof(info.ledger_phys_footprint_peak);
    *peak = (size_t)count * sizeof(natural_t) >= peakEnd && info.ledger_phys_footprint_peak > 0
        ? (uint64_t)info.ledger_phys_footprint_peak : info.phys_footprint;
    return YES;
}

/// Whether this process has Increased Memory Limit, as its signature gives
/// it: 1 or 0, or -1 when the entitlement cannot be read. Security's
/// functions, which Cartouche calls for its own (CartoucheDevice.swift),
/// are looked up rather than linked: the iOS SDK does not declare them.
static int CartoucheGuestIncreasedMemoryLimit(void) {
    void *(*createFromSelf)(CFAllocatorRef) = (void *(*)(CFAllocatorRef))dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    CFTypeRef (*copyValue)(void *, CFStringRef, CFErrorRef *) =
        (CFTypeRef (*)(void *, CFStringRef, CFErrorRef *))dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!createFromSelf || !copyValue) return -1;
    void *task = createFromSelf(kCFAllocatorDefault);
    if (!task) return -1;
    CFErrorRef error = NULL;
    id value = CFBridgingRelease(copyValue(task, CFSTR("com.apple.developer.kernel.increased-memory-limit"), &error));
    CFRelease((CFTypeRef)task);
    if (error) {
        CFRelease(error);
        return -1;
    }
    return [value isKindOfClass:NSNumber.class] && [value boolValue] ? 1 : 0;
}

/// The game's own scene, not the one nxnative opens on a TV. This process
/// is an app extension, without UIApplication's sharedApplication: the
/// scene is noted as it connects.
static __weak UIWindowScene *gameScene;

static CGSize CartoucheGuestScreenSize(void) {
    UIWindowScene *scene = gameScene;
    return scene ? scene.coordinateSpace.bounds.size : CGSizeZero;
}

/// On measureQueue.
static void CartoucheGuestRecord(CGSize size) {
    uint64_t footprint = 0, peak = 0;
    if (!CartoucheGuestFootprint(&footprint, &peak)) return;
    uint64_t available = (uint64_t)os_proc_available_memory();
    if (peak > highestPeak) highestPeak = peak;
    if (footprint > highestPeak) highestPeak = footprint;

    NSDate *now = [NSDate date];
    if (size.width > 0 && size.height > 0 && !CGSizeEqualToSize(size, lastSize)) {
        lastSize = size;
        [sizes addObject:@{
            @"time": now,
            @"width": @(size.width),
            @"height": @(size.height),
            @"footprint": @(footprint),
        }];
        // The latest ones are enough to read a fold or a rotation.
        if (sizes.count > 100) [sizes removeObjectAtIndex:0];
    }
    reading[@"updated"] = now;
    reading[@"footprint"] = @(footprint);
    reading[@"peak"] = @(highestPeak);
    reading[@"available"] = @(available);
    reading[@"limit"] = @(footprint + available);
    reading[@"sizes"] = [sizes copy];
    [reading writeToFile:memoryFile atomically:YES];
}

static void CartoucheGuestMeasure(void) {
    // The screen's size is UIKit's, on the main thread, which the game may
    // keep busy: the reading waits for it, the game never waits.
    dispatch_async(dispatch_get_main_queue(), ^{
        CGSize size = CartoucheGuestScreenSize();
        dispatch_async(measureQueue, ^{
            CartoucheGuestRecord(size);
        });
    });
}

static void CartoucheGuestWatchHomeButton(GCController *controller) {
    GCControllerButtonInput *home = controller.physicalInputProfile.buttons[GCInputButtonHome];
    if (!home) return;
    // The press comes to the game rather than to iOS, as nxnative asks too.
    home.preferredSystemGestureState = GCSystemGestureStateDisabled;
    NSString *name = homeNotification;
    home.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        if (!pressed) return;
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)name, NULL, NULL, true);
    };
}

void CartoucheGuestStart(NSDictionary *appInfo) {
    NSString *container = appInfo[@"selectedContainer"];
    NSString *bundle = appInfo[@"selected"];
    // The app group as it is before LiveContainer points the game's own
    // lookups of it elsewhere. LiveContainer's own class, looked up as
    // LCBootstrap.m looks it up.
    NSURL *group = [NSClassFromString(@"LCSharedUtils") appGroupPath];
    if (![container isKindOfClass:NSString.class] || container.length == 0 || !group) return;

    [NSNotificationCenter.defaultCenter addObserverForName:UISceneWillConnectNotification object:nil
                                                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        UIScene *scene = note.object;
        if (!gameScene && [scene isKindOfClass:UIWindowScene.class]
            && [scene.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) {
            gameScene = (UIWindowScene *)scene;
        }
    }];

    homeNotification = [@"CartoucheGameHome." stringByAppendingString:container];
    for (GCController *controller in GCController.controllers) {
        CartoucheGuestWatchHomeButton(controller);
    }
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification object:nil
                                                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        if ([note.object isKindOfClass:GCController.class]) {
            CartoucheGuestWatchHomeButton(note.object);
        }
    }];

    NSURL *folder = [group URLByAppendingPathComponent:@"Cartouche" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    memoryFile = [folder URLByAppendingPathComponent:@"GameMemory.plist"].path;
    sizes = [NSMutableArray array];
    reading = [@{
        @"bundle": [bundle isKindOfClass:NSString.class] ? bundle : @"",
        @"container": container,
        @"pid": @(getpid()),
        @"started": [NSDate date],
    } mutableCopy];
    int increased = CartoucheGuestIncreasedMemoryLimit();
    if (increased >= 0) reading[@"increasedMemoryLimit"] = increased == 1 ? @YES : @NO;

    measureQueue = dispatch_queue_create("Cartouche.GameMemory", DISPATCH_QUEUE_SERIAL);
    dispatch_async(measureQueue, ^{
        CartoucheGuestRecord(CGSizeZero);
    });
    measureTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, measureQueue);
    dispatch_source_set_timer(measureTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(measureTimer, ^{
        CartoucheGuestMeasure();
    });
    dispatch_resume(measureTimer);
}
