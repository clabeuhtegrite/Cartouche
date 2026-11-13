//
//  LiveContainerStandIn.m
//  InPlaceGame (research)
//
//  LiveContainer's calls that launcher/Guest/CartoucheUprightGame.m makes,
//  as LiveContainer answers them in a game started in Cartouche's place: a
//  game is running (lcGuestAppId), in Cartouche's own process, not in
//  LiveProcess, nor the built-in SideStore, with no orientation lock. Started
//  with -CartoucheControl YES, no game is running, as in Cartouche's own
//  screens: the file does nothing, and the game turns as iOS reads its
//  Info.plist.
//

#import "utils.h"

@implementation NSUserDefaults (LiveContainer)
+ (instancetype)lcUserDefaults { return NSUserDefaults.standardUserDefaults; }
+ (instancetype)lcSharedDefaults { return NSUserDefaults.standardUserDefaults; }
+ (NSString *)lcAppGroupPath { return nil; }
+ (NSString *)lcAppUrlScheme { return @"cartouche"; }
+ (NSBundle *)lcMainBundle { return NSBundle.mainBundle; }
+ (NSDictionary *)guestAppInfo { return @{}; }
+ (NSDictionary *)guestContainerInfo { return @{}; }
+ (bool)isLiveProcess { return false; }
+ (bool)isSharedApp { return false; }
+ (NSString *)lcGuestAppId {
    return [NSUserDefaults.standardUserDefaults boolForKey:@"CartoucheControl"] ? nil : NSBundle.mainBundle.bundleIdentifier;
}
+ (bool)isSideStore { return false; }
+ (bool)sideStoreExist { return false; }
+ (NSString *)lcLaunchURL { return nil; }
@end
