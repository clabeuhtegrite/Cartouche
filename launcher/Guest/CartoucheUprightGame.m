//
//  CartoucheUprightGame.m
//  Cartouche
//
//  Turns a game started in Cartouche's place upright too on an iPhone, as
//  the player holds it, when the game lays itself out upright: its picture
//  above, its controls under it. Behind the console, Cartouche turns the
//  game's screen itself (CartoucheGameOrientation.swift, CartoucheGameHost.
//  swift). In Cartouche's place, the game is the app, and iOS turns it as
//  the game's own Info.plist allows on an iPhone: sideways only for
//  nxnative's games, whose own app stays sideways on an iPhone. Here, in the
//  game's process, UIKit hears that the game allows upright too.
//
//  A game lays itself out upright when its Info.plist allows it upright on
//  an iPad, the iPad's list read first, as CartoucheGameOrientations.
//  laysOutUpright(bundle:) reads it: nxnative's games do since its commit
//  e2fadf2 of 4 November 2026, which lays their picture above their
//  controls there (DmLayout); one built before stays sideways. Not while the
//  game's picture is on a TV, in the scene iOS gives the game for it:
//  nxnative then leaves the iPhone its controls alone, laid out to be held
//  sideways. Never upside down, as Cartouche itself, never on an iPad, where
//  the game turns every way its own Info.plist allows, and never for a game
//  whose orientation the player locked in LiveContainer's settings, which
//  LiveContainer's own hooks keep (TweakLoader/UIKit+GuestHooks.m). Only in
//  nxnative's games, never in Cartouche's own screens or in the built-in
//  SideStore.
//
//  UIKit turns an app's screen to the ways its view controller allows, met
//  with those the app allows, which its Info.plist lists:
//  -[UIViewController __supportedInterfaceOrientations] meets them, and
//  raises when they have none in common, and -[UIApplication
//  supportedInterfaceOrientationsForWindow:] gives the app's. Both give
//  upright too here, the first for a view controller that allows it itself,
//  as nxnative's do (every way). LiveContainer's own orientation lock
//  replaces the first the same way.
//
//  app/scripts/prepare.sh copies this folder into LiveContainer's Tweaks
//  folder, which builds into LiveContainerShared: the framework every
//  LiveContainer process loads first, before UIKit and before the game.
//  Like CartouchePlayTimeCounter.m, this file finds UIKit's classes and
//  names at run time. It starts once the game has finished launching, as
//  UIKit says so, before iOS gives the game its first scene. Behind the
//  console, where the game runs in LiveProcess, it does nothing.
//

@import Foundation;
#include <dlfcn.h>
#include <objc/runtime.h>
#include "../../utils.h"

// UIKit's, as its headers number them.
static const NSUInteger CartoucheUprightMask = 1 << 1;   // UIInterfaceOrientationMaskPortrait
static const NSInteger CartoucheUprightPhone = 0;        // UIUserInterfaceIdiomPhone

// The calls this file makes on UIKit's objects, found at run time.
@protocol CartoucheUprightUIKit
+ (id)sharedApplication;                                 // UIApplication
- (NSSet *)connectedScenes;
+ (id)currentDevice;                                     // UIDevice
- (NSInteger)userInterfaceIdiom;
- (id)session;                                           // UIScene
- (NSString *)role;                                      // UISceneSession
- (NSArray *)windows;                                    // UIWindowScene
- (id)rootViewController;                                // UIWindow
- (NSUInteger)supportedInterfaceOrientations;            // UIViewController
- (void)setNeedsUpdateOfSupportedInterfaceOrientations;
@end

/// Whether the game in this process turns upright too: decided once, as it
/// has finished launching.
static BOOL turnsUpright;
/// The role of the scene iOS gives the game for a TV, by cable or AirPlay
/// (UIWindowSceneSessionRoleExternalDisplayNonInteractive).
static NSString *tvRole;
static NSUInteger (*viewControllerWays)(id, SEL);
static NSUInteger (*applicationWays)(id, SEL, id);
static id launchObserver;

/// One of UIKit's names, as UIKit itself holds it.
static NSString *CartoucheUprightUIKitName(const char *symbol) {
    NSString *__unsafe_unretained *name = (NSString *__unsafe_unretained *)dlsym(RTLD_DEFAULT, symbol);
    return name ? *name : nil;
}

/// Whether a TV shows the game's picture: whether iOS has given the game a
/// scene for one.
static BOOL CartoucheUprightPictureOnTV(void) {
    id application = [NSClassFromString(@"UIApplication") sharedApplication];
    for (id scene in [application connectedScenes]) {
        if ([[[scene session] role] isEqualToString:tvRole]) return YES;
    }
    return NO;
}

static BOOL CartoucheUprightNow(void) {
    return turnsUpright && !CartoucheUprightPictureOnTV();
}

/// -[UIViewController __supportedInterfaceOrientations]: the ways the view
/// controller allows, met with the app's. Upright too, for one that allows
/// it itself.
static NSUInteger CartoucheUprightViewControllerWays(id self, SEL _cmd) {
    NSUInteger ways = viewControllerWays(self, _cmd);
    if (CartoucheUprightNow() && ([self supportedInterfaceOrientations] & CartoucheUprightMask)) {
        ways |= CartoucheUprightMask;
    }
    return ways;
}

/// -[UIApplication supportedInterfaceOrientationsForWindow:]: the ways the
/// app allows, its Info.plist's. Upright too.
static NSUInteger CartoucheUprightApplicationWays(id self, SEL _cmd, id window) {
    NSUInteger ways = applicationWays(self, _cmd, window);
    if (CartoucheUprightNow()) ways |= CartoucheUprightMask;
    return ways;
}

/// UIKit asks the game's screens again which ways they turn: as a TV comes
/// or goes, the iPhone turns sideways, or may turn upright again.
static void CartoucheUprightAskAgain(void) {
    id application = [NSClassFromString(@"UIApplication") sharedApplication];
    for (id scene in [application connectedScenes]) {
        if (![scene respondsToSelector:@selector(windows)] || [[[scene session] role] isEqualToString:tvRole]) continue;
        for (id window in [scene windows]) {
            id root = [window rootViewController];
            if ([root respondsToSelector:@selector(setNeedsUpdateOfSupportedInterfaceOrientations)]) {
                [root setNeedsUpdateOfSupportedInterfaceOrientations];
            }
        }
    }
}

/// Whether the app at BUNDLE is one of nxnative's games that lays itself
/// out upright. nxnative puts its dm folder in each, and DMLanguage in their
/// Info.plist (CartouchePlayTimeCounter.m). Its Info.plist is the one in its
/// bundle, the iPad's list read first, then the one for every device; a
/// list that names no way allows every way, as iOS reads it.
static BOOL CartoucheUprightLaysOutUpright(NSString *bundle) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]];
    if (![info isKindOfClass:NSDictionary.class]) return NO;
    BOOL game = [NSFileManager.defaultManager fileExistsAtPath:[bundle stringByAppendingPathComponent:@"dm"]]
        || info[@"DMLanguage"] != nil;
    if (!game) return NO;
    NSArray *names = nil;
    for (NSString *key in @[@"UISupportedInterfaceOrientations~ipad", @"UISupportedInterfaceOrientations"]) {
        if ([info[key] isKindOfClass:NSArray.class]) {
            names = info[key];
            break;
        }
    }
    NSArray *ways = @[@"UIInterfaceOrientationPortrait", @"UIInterfaceOrientationPortraitUpsideDown",
                      @"UIInterfaceOrientationLandscapeLeft", @"UIInterfaceOrientationLandscapeRight"];
    BOOL namesOne = NO;
    for (id name in names) namesOne = namesOne || [ways containsObject:name];
    return !namesOne || [names containsObject:@"UIInterfaceOrientationPortrait"];
}

static void CartoucheUprightStart(void) {
    // A game in Cartouche's place, on an iPhone, that the player has not
    // locked one way.
    if (!NSUserDefaults.lcGuestAppId || NSUserDefaults.isLiveProcess || NSUserDefaults.isSideStore) return;
    if ([[NSClassFromString(@"UIDevice") currentDevice] userInterfaceIdiom] != CartoucheUprightPhone) return;
    if ([NSUserDefaults.guestAppInfo[@"LCOrientationLock"] integerValue] != 0) return;
    if (!CartoucheUprightLaysOutUpright(NSBundle.mainBundle.bundlePath)) return;
    tvRole = CartoucheUprightUIKitName("UIWindowSceneSessionRoleExternalDisplayNonInteractive");
    NSString *sceneCame = CartoucheUprightUIKitName("UISceneWillConnectNotification");
    NSString *sceneWent = CartoucheUprightUIKitName("UISceneDidDisconnectNotification");
    Method viewController = class_getInstanceMethod(NSClassFromString(@"UIViewController"),
                                                    NSSelectorFromString(@"__supportedInterfaceOrientations"));
    Method application = class_getInstanceMethod(NSClassFromString(@"UIApplication"),
                                                 NSSelectorFromString(@"supportedInterfaceOrientationsForWindow:"));
    if (!tvRole || !sceneCame || !sceneWent || !viewController || !application) {
        NSLog(@"[Cartouche] this iOS has not the calls that turn a game upright in Cartouche's place: it stays as its app allows");
        return;
    }
    turnsUpright = YES;
    viewControllerWays = (NSUInteger (*)(id, SEL))method_setImplementation(viewController, (IMP)CartoucheUprightViewControllerWays);
    applicationWays = (NSUInteger (*)(id, SEL, id))method_setImplementation(application, (IMP)CartoucheUprightApplicationWays);
    for (NSString *name in @[sceneCame, sceneWent]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            if (![[[note.object session] role] isEqualToString:tvRole]) return;
            // Once iOS has connected the TV's scene, or let it go.
            dispatch_async(dispatch_get_main_queue(), ^{
                CartoucheUprightAskAgain();
            });
        }];
    }
    CartoucheUprightAskAgain();
    NSLog(@"[Cartouche] in Cartouche's place, the game turns upright too, as it lays itself out upright, while its picture is on the iPhone");
}

__attribute__((constructor))
static void CartoucheUprightInit(void) {
    // Without a queue, UIKit calls this as it says the game has finished
    // launching, before it gives the game its first scene.
    launchObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:@"UIApplicationDidFinishLaunchingNotification"
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        [NSNotificationCenter.defaultCenter removeObserver:launchObserver];
        launchObserver = nil;
        CartoucheUprightStart();
    }];
}
