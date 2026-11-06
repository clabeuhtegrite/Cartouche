//
//  CartoucheOnboardingReturn.m
//  Cartouche
//
//  Brings the player back to Cartouche once they finish the built-in
//  SideStore's onboarding, where they sign in with their Apple ID: Cartouche
//  then hands the certificate to LiveContainer on its own. Without it, the
//  way back would be the ⎋ button that SideStoreHooks.m adds to My Apps.
//
//  When the player taps Sign In in Cartouche's setup before SideStore has an
//  Apple ID, the setup leaves a request in the app group, and the onboarding
//  shows again even if they went through it once (CartoucheSetup.swift).
//
//  SideStoreSupport loads in the SideStore guest only. The observer waits
//  for the app to finish launching, when SideStore's own defaults are in
//  place, and only on a launch whose onboarding is not done yet.
//

#include "../../LiveContainer/utils.h"
#include "../../LiveContainer/LCSharedUtils.h"
@import UIKit;

static NSString *const CartoucheOnboardingKey = @"hasCompletedOnboarding";
static NSString *const CartoucheSignInRequestKey = @"CartoucheSignInRequested";

@interface CartoucheOnboardingReturn : NSObject
@end

@implementation CartoucheOnboardingReturn

static CartoucheOnboardingReturn *observer;
static id launchObserver;

+ (void)load {
    // Only where the player goes through the onboarding: SideStore in
    // Cartouche's own process, not SideStore renewing in the background.
    if (!NSUserDefaults.isSideStore || NSUserDefaults.isLiveProcess) return;

    // Before SideStore's launch screen reads the flag.
    NSUserDefaults *shared = NSUserDefaults.lcSharedDefaults;
    if ([shared boolForKey:CartoucheSignInRequestKey]) {
        [shared removeObjectForKey:CartoucheSignInRequestKey];
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:CartoucheOnboardingKey];
    }

    launchObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        [NSNotificationCenter.defaultCenter removeObserver:launchObserver];
        launchObserver = nil;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if ([defaults boolForKey:CartoucheOnboardingKey]) return;
        observer = [CartoucheOnboardingReturn new];
        [defaults addObserver:observer forKeyPath:CartoucheOnboardingKey options:NSKeyValueObservingOptionNew context:nil];
    }];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    id value = change[NSKeyValueChangeNewKey];
    if (![value isKindOfClass:NSNumber.class] || ![value boolValue]) return;
    [object removeObserver:self forKeyPath:CartoucheOnboardingKey];
    // SideStore saves the flag, then shows its main screen: leave it a
    // moment, then go back to Cartouche as the ⎋ button does.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [LCSharedUtils launchToGuestAppWithClassicMode:0];
    });
}

@end
