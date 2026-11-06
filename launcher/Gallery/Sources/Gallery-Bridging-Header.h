//
//  Gallery-Bridging-Header.h
//  CartoucheGallery
//
//  The private Security calls CartoucheDevice.swift makes, which
//  LiveContainer declares in FoundationPrivate.h. The gallery answers them
//  as an iPhone with Increased Memory Limit would.
//

#include <CoreFoundation/CoreFoundation.h>

static inline void *SecTaskCreateFromSelf(CFAllocatorRef allocator) {
    return NULL;
}

static inline CFTypeRef SecTaskCopyValueForEntitlement(void *task, CFStringRef key, CFErrorRef *error) {
    return CFRetain(kCFBooleanTrue);
}
