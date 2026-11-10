//
//  CartouchePlayTimeCounter.m
//  Cartouche
//
//  Counts how long the player plays each game: the time the game is in
//  front and active, added up in the game's own data folder, in
//  Library/Cartouche/PlayTime.plist, which Cartouche reads to show it
//  (CartouchePlayTime.swift, CartoucheGameStats.swift).
//
//  app/scripts/prepare.sh copies this folder into LiveContainer's Tweaks
//  folder, which builds into LiveContainerShared: the framework every
//  LiveContainer process loads first, a game's included, whether the game
//  runs in Cartouche's own process or in LiveProcess. The game's data folder
//  is the one place both let a game write to. The counter only listens to
//  the app's life cycle and writes that one file: the game itself is
//  untouched. It counts in nxnative's games only, never on Cartouche's own
//  screens or in the built-in SideStore.
//
//  LiveContainerShared loads before UIKit and before the game: like
//  Dead10ccFix.m, this file names UIKit's notifications by their strings
//  and finds UIApplication at run time. It starts once the game has
//  finished launching, when LiveContainer has set HOME to the game's data
//  folder.
//
//  The total is written each time the game leaves the front, and every 30
//  seconds while it is there, so that a game iOS stops, out of memory for
//  instance, loses half a minute at most. The clock is the uptime, which
//  stops while the iPhone sleeps.
//

@import Foundation;
#include <time.h>
#include "../../utils.h"

// UIKit's, found at run time.
@interface UIApplication : NSObject
+ (instancetype)sharedApplication;
- (NSInteger)applicationState;
@end

/// The file, in the game's data folder. CartouchePlayTime.swift reads it.
static NSString *const CartouchePlayTimeFile = @"Library/Cartouche/PlayTime.plist";
/// How often the total is written while the game is in front, in seconds.
static const int64_t CartouchePlayTimeInterval = 30;

static NSString *file;
/// What the file holds, this start's time included: seconds, sessions,
/// firstPlayed, lastPlayed, and lastSession, this start's own start and
/// seconds.
static NSMutableDictionary *total;
/// The uptime when the game came to the front, in nanoseconds; 0 while it
/// is not there.
static uint64_t inFrontSince;
/// Whether this start counts in the sessions yet: it does once the game has
/// been in front.
static BOOL sessionCounted;
static NSDate *sessionStart;
static double sessionSeconds;
static dispatch_queue_t writer;
static dispatch_source_t timer;
static id launchObserver;

static uint64_t CartouchePlayTimeNow(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

/// Writes the total, off the main thread, in order; WAIT waits until it is
/// written, for a game that may be suspended or closed right after.
static void CartouchePlayTimeSave(BOOL wait) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:total
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:nil];
    if (!data) return;
    NSString *path = file;
    dispatch_block_t write = ^{
        [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
        NSError *error = nil;
        if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
            NSLog(@"[Cartouche] cannot write the play time: %@", error);
        }
    };
    if (wait) {
        dispatch_sync(writer, write);
    } else {
        dispatch_async(writer, write);
    }
}

/// Whether the game is in front and active (UIApplicationStateActive).
static BOOL CartouchePlayTimeIsInFront(void) {
    UIApplication *application = [NSClassFromString(@"UIApplication") sharedApplication];
    return application != nil && [application applicationState] == 0;
}

/// Adds the time since the game came to the front to the total, and writes
/// it. STILL keeps counting from now on.
static void CartouchePlayTimeAdd(BOOL still, BOOL wait) {
    if (!inFrontSince) return;
    uint64_t now = CartouchePlayTimeNow();
    double seconds = (double)(now - inFrontSince) / NSEC_PER_SEC;
    sessionSeconds += seconds;
    total[@"seconds"] = @([total[@"seconds"] doubleValue] + seconds);
    total[@"lastPlayed"] = [NSDate date];
    if (sessionStart) total[@"lastSession"] = @{@"start": sessionStart, @"seconds": @(sessionSeconds)};
    inFrontSince = still ? now : 0;
    CartouchePlayTimeSave(wait);
}

static void CartouchePlayTimeCameToFront(void) {
    if (inFrontSince || !CartouchePlayTimeIsInFront()) return;
    inFrontSince = CartouchePlayTimeNow();
    if (sessionCounted) return;
    sessionCounted = YES;
    sessionStart = [NSDate date];
    total[@"sessions"] = @([total[@"sessions"] longLongValue] + 1);
    if (![total[@"firstPlayed"] isKindOfClass:NSDate.class]) total[@"firstPlayed"] = sessionStart;
    total[@"lastPlayed"] = sessionStart;
    total[@"lastSession"] = @{@"start": sessionStart, @"seconds": @0.0};
    CartouchePlayTimeSave(NO);
}

static void CartouchePlayTimeLeftFront(void) {
    CartouchePlayTimeAdd(NO, YES);
}

/// Every 30 seconds: the time so far goes in the file, or, if the game left
/// the front without a notification, up to now; a game in front that no
/// notification announced starts counting.
static void CartouchePlayTimeTick(void) {
    if (!inFrontSince) {
        CartouchePlayTimeCameToFront();
        return;
    }
    CartouchePlayTimeAdd(CartouchePlayTimeIsInFront(), NO);
}

/// Whether this process runs one of nxnative's games: nxnative puts its dm
/// folder in each, and DMLanguage in their Info.plist.
static BOOL CartouchePlayTimeIsGame(void) {
    if (!NSUserDefaults.lcGuestAppId || NSUserDefaults.isSideStore) return NO;
    NSBundle *game = NSBundle.mainBundle;
    return [NSFileManager.defaultManager fileExistsAtPath:[game.bundlePath stringByAppendingPathComponent:@"dm"]]
        || game.infoDictionary[@"DMLanguage"] != nil;
}

static void CartouchePlayTimeStart(void) {
    const char *home = getenv("HOME");
    if (!home || !CartouchePlayTimeIsGame()) return;
    file = [@(home) stringByAppendingPathComponent:CartouchePlayTimeFile];
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:file];
    total = [saved isKindOfClass:NSDictionary.class] ? [saved mutableCopy] : [NSMutableDictionary dictionary];
    if (![total[@"seconds"] isKindOfClass:NSNumber.class]) total[@"seconds"] = @0.0;
    if (![total[@"sessions"] isKindOfClass:NSNumber.class]) total[@"sessions"] = @0;
    total[@"version"] = @1;
    writer = dispatch_queue_create("io.github.clabeuhtegrite.cartouche.play-time", DISPATCH_QUEUE_SERIAL);

    // In Cartouche's own process, UIKit says when the game comes and goes;
    // in LiveProcess, the extension says when the app that shows it does.
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    NSArray<NSString *> *inFront = @[
        @"UIApplicationDidBecomeActiveNotification",
        NSExtensionHostDidBecomeActiveNotification,
    ];
    NSArray<NSString *> *outOfFront = @[
        @"UIApplicationWillResignActiveNotification",
        @"UIApplicationDidEnterBackgroundNotification",
        @"UIApplicationWillTerminateNotification",
        NSExtensionHostWillResignActiveNotification,
        NSExtensionHostDidEnterBackgroundNotification,
    ];
    for (NSString *name in inFront) {
        [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            CartouchePlayTimeCameToFront();
        }];
    }
    for (NSString *name in outOfFront) {
        [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            CartouchePlayTimeLeftFront();
        }];
    }

    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, CartouchePlayTimeInterval * NSEC_PER_SEC),
                              CartouchePlayTimeInterval * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        CartouchePlayTimeTick();
    });
    dispatch_resume(timer);
    // The game may be in front already.
    CartouchePlayTimeCameToFront();
}

__attribute__((constructor))
static void CartouchePlayTimeInit(void) {
    launchObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:@"UIApplicationDidFinishLaunchingNotification"
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        [NSNotificationCenter.defaultCenter removeObserver:launchObserver];
        launchObserver = nil;
        CartouchePlayTimeStart();
    }];
}
