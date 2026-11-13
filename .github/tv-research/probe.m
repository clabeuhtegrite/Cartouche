// Research only (the TV mode's thread): what iOS's own classes say about
// external display scenes, scene accessories and scene hosting, read from
// the Objective-C runtime in the iOS Simulator. Never part of Cartouche.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <string.h>

static void dumpMethods(Class c, BOOL meta, const char *filter) {
    unsigned n = 0;
    Method *m = class_copyMethodList(meta ? object_getClass(c) : c, &n);
    for (unsigned i = 0; i < n; i++) {
        const char *name = sel_getName(method_getName(m[i]));
        if (filter && !strcasestr(name, filter)) continue;
        printf("    %c %s  %s\n", meta ? '+' : '-', name, method_getTypeEncoding(m[i]) ?: "");
    }
    free(m);
}

static void dumpClass(const char *name, const char *filter) {
    Class c = objc_getClass(name);
    if (!c) { printf("== %s: missing\n", name); return; }
    Class s = class_getSuperclass(c);
    printf("== %s : %s  [%s]\n", name, s ? class_getName(s) : "-", class_getImageName(c) ?: "?");
    unsigned n = 0;
    objc_property_t *p = class_copyPropertyList(c, &n);
    for (unsigned i = 0; i < n; i++) {
        if (filter && !strcasestr(property_getName(p[i]), filter)) continue;
        printf("    @property %s  %s\n", property_getName(p[i]), property_getAttributes(p[i]));
    }
    free(p);
    Ivar *v = class_copyIvarList(c, &n);
    for (unsigned i = 0; i < n; i++) {
        if (filter && !strcasestr(ivar_getName(v[i]), filter)) continue;
        printf("    ivar %s  %s\n", ivar_getName(v[i]), ivar_getTypeEncoding(v[i]) ?: "");
    }
    free(v);
    dumpMethods(c, YES, filter);
    dumpMethods(c, NO, filter);
    unsigned pn = 0;
    Protocol * __unsafe_unretained *protocols = class_copyProtocolList(c, &pn);
    for (unsigned i = 0; i < pn; i++) printf("    <%s>\n", protocol_getName(protocols[i]));
    free(protocols);
}

static BOOL isSubclass(Class c, Class of) {
    for (Class k = c; k; k = class_getSuperclass(k)) if (k == of) return YES;
    return NO;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        const char *frameworks[] = {
            "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
            "/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard",
            "/System/Library/PrivateFrameworks/BoardServices.framework/BoardServices",
            "/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices",
            "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
            "/System/Library/Frameworks/CarPlay.framework/CarPlay",
        };
        for (size_t i = 0; i < sizeof frameworks / sizeof *frameworks; i++) {
            void *h = dlopen(frameworks[i], RTLD_NOW);
            printf("dlopen %s: %s\n", frameworks[i], h ? "ok" : dlerror());
        }
        printf("iOS %s\n", UIDevice.currentDevice.systemVersion.UTF8String);

        unsigned count = 0;
        Class *classes = objc_copyClassList(&count);
        printf("\n#### classes by name (%u classes)\n", count);
        const char *words[] = {"Accessory", "ExternalDisplay", "SceneSpecification", "SceneHosting", "SessionRole", "NonInteractive", "SecondaryDisplay", "DisplayConfiguration"};
        for (unsigned i = 0; i < count; i++) {
            const char *name = class_getName(classes[i]);
            for (size_t w = 0; w < sizeof words / sizeof *words; w++) {
                if (strstr(name, words[w])) {
                    printf("  %s : %s  [%s]\n", name, class_getSuperclass(classes[i]) ? class_getName(class_getSuperclass(classes[i])) : "-",
                           class_getImageName(classes[i]) ?: "?");
                    break;
                }
            }
        }

        printf("\n#### scene specifications and their roles\n");
        Class spec = objc_getClass("FBSSceneSpecification");
        for (unsigned i = 0; i < count; i++) {
            Class c = classes[i];
            if (!spec || !isSubclass(c, spec)) continue;
            NSString *role = nil;
            @try {
                id s = [c respondsToSelector:@selector(specification)] ? [c performSelector:@selector(specification)] : [[c alloc] init];
                if ([s respondsToSelector:NSSelectorFromString(@"uiSceneSessionRole")]) {
                    role = [s performSelector:NSSelectorFromString(@"uiSceneSessionRole")];
                }
                printf("  %s : %s  role=%s  [%s]\n", class_getName(c), class_getName(class_getSuperclass(c)),
                       role ? role.description.UTF8String : "(none)", class_getImageName(c) ?: "?");
            } @catch (NSException *e) {
                printf("  %s: exception %s\n", class_getName(c), e.reason.UTF8String);
            }
        }

        printf("\n#### selectors that name a role, an accessory or an external display\n");
        const char *selwords[] = {"SessionRole", "ceneAccessor", "xternalDisplay", "NonInteractive"};
        for (unsigned i = 0; i < count; i++) {
            Class c = classes[i];
            for (int meta = 0; meta < 2; meta++) {
                unsigned n = 0;
                Method *m = class_copyMethodList(meta ? object_getClass(c) : c, &n);
                for (unsigned j = 0; j < n; j++) {
                    const char *sel = sel_getName(method_getName(m[j]));
                    for (size_t w = 0; w < sizeof selwords / sizeof *selwords; w++) {
                        if (strstr(sel, selwords[w])) {
                            printf("  %c[%s %s]  %s\n", meta ? '+' : '-', class_getName(c), sel, method_getTypeEncoding(m[j]) ?: "");
                            break;
                        }
                    }
                }
                free(m);
            }
        }
        free(classes);

        printf("\n#### classes in full\n");
        const char *full[] = {
            "UISceneAccessory", "UISceneAccessoryRegistration", "_UISceneHostingController",
            "_UISceneHostingControllerAdvancedConfiguration", "_UISceneHostingView", "_UISceneHostingViewController",
            "UIApplicationSceneSpecification", "FBSSceneSpecification", "UISceneConfiguration",
        };
        for (size_t i = 0; i < sizeof full / sizeof *full; i++) dumpClass(full[i], NULL);
        printf("\n#### filtered\n");
        dumpClass("UIViewController", "ccessor");
        dumpClass("UIScene", "ccessor");
        dumpClass("UIWindowScene", "ccessor");
        dumpClass("UISceneSession", "role");
        dumpClass("UIApplication", "xternal");
        dumpClass("UIApplicationSceneSettings", "isplay");
        dumpClass("UIMutableApplicationSceneSettings", "isplay");
        dumpClass("FBSSceneSettings", "isplay");
        dumpClass("FBSceneManager", NULL);
        dumpClass("FBScene", "ccessor");
    }
    return 0;
}
