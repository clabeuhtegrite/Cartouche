//
//  Harness-Bridging-Header.h
//  CartoucheHarness
//
//  What the launcher's Swift and LiveContainer's Swift files see of
//  Objective-C in the app: UIKit, as LiveContainer's own headers bring it
//  in; LiveContainer's unpacker (unarchive.h, from app/LiveContainer, which
//  harness.sh copies into Build/LiveContainer); the private initializer of
//  a game's preferences (FoundationPrivate.h); and the private Security
//  calls CartoucheDevice.swift makes, answered as an iPhone with Increased
//  Memory Limit would, as the launcher's gallery answers them.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "unarchive.h"

@interface NSUserDefaults (HarnessPrivate)
- (instancetype)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container;
@end

static inline void *SecTaskCreateFromSelf(CFAllocatorRef allocator) {
    return NULL;
}

static inline CFTypeRef SecTaskCopyValueForEntitlement(void *task, CFStringRef key, CFErrorRef *error) {
    return CFRetain(kCFBooleanTrue);
}
