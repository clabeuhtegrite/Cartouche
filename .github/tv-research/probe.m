// Research only (the TV mode's thread): what iOS's own classes say about
// external display scenes, scene accessories and scene hosting, read from
// the Objective-C runtime of the iOS Simulator. Never part of Cartouche.
// Links Foundation only and loads UIKitCore itself, writing every line at
// once to stderr, so that a hang shows where it is.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <string.h>

#define P(...) do { fprintf(stderr, __VA_ARGS__); } while (0)

static void dumpMethods(Class c, BOOL meta, const char *filter) {
    unsigned n = 0;
    Method *m = class_copyMethodList(meta ? object_getClass(c) : c, &n);
    for (unsigned i = 0; i < n; i++) {
        const char *name = sel_getName(method_getName(m[i]));
        if (filter && !strcasestr(name, filter)) continue;
        P("    %c %s  %s\n", meta ? '+' : '-', name, method_getTypeEncoding(m[i]) ?: "");
    }
    free(m);
}

static void dumpClass(const char *name, const char *filter) {
    Class c = objc_getClass(name);
    if (!c) { P("== %s: missing\n", name); return; }
    Class s = class_getSuperclass(c);
    P("== %s : %s  [%s]\n", name, s ? class_getName(s) : "-", class_getImageName(c) ?: "?");
    unsigned n = 0;
    objc_property_t *p = class_copyPropertyList(c, &n);
    for (unsigned i = 0; i < n; i++) {
        if (filter && !strcasestr(property_getName(p[i]), filter)) continue;
        P("    @property %s  %s\n", property_getName(p[i]), property_getAttributes(p[i]));
    }
    free(p);
    Ivar *v = class_copyIvarList(c, &n);
    for (unsigned i = 0; i < n; i++) {
        if (filter && !strcasestr(ivar_getName(v[i]), filter)) continue;
        P("    ivar %s  %s\n", ivar_getName(v[i]), ivar_getTypeEncoding(v[i]) ?: "");
    }
    free(v);
    dumpMethods(c, YES, filter);
    dumpMethods(c, NO, filter);
    unsigned pn = 0;
    Protocol * __unsafe_unretained *protocols = class_copyProtocolList(c, &pn);
    for (unsigned i = 0; i < pn; i++) P("    <%s>\n", protocol_getName(protocols[i]));
    free(protocols);
}

static void dumpProtocol(const char *name) {
    Protocol *p = objc_getProtocol(name);
    if (!p) { P("== @protocol %s: missing\n", name); return; }
    P("== @protocol %s\n", name);
    for (int req = 1; req >= 0; req--) {
        for (int inst = 1; inst >= 0; inst--) {
            unsigned n = 0;
            struct objc_method_description *d = protocol_copyMethodDescriptionList(p, req, inst, &n);
            for (unsigned i = 0; i < n; i++) P("    %s%c %s  %s\n", req ? "" : "@optional ", inst ? '-' : '+', sel_getName(d[i].name), d[i].types ?: "");
            free(d);
        }
    }
}

static BOOL isSubclass(Class c, Class of) {
    for (Class k = c; k; k = class_getSuperclass(k)) if (k == of) return YES;
    return NO;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        P("main\n");
        const char *frameworks[] = {
            "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore",
            "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
        };
        for (size_t i = 0; i < sizeof frameworks / sizeof *frameworks; i++) {
            P("dlopen %s...\n", frameworks[i]);
            void *h = dlopen(frameworks[i], RTLD_NOW);
            P("  %s\n", h ? "ok" : dlerror());
        }

        unsigned count = 0;
        Class *classes = objc_copyClassList(&count);
        P("\n#### classes by name (%u classes)\n", count);
        const char *words[] = {"Accessory", "ExternalDisplay", "SceneSpecification", "SceneHosting", "SessionRole", "NonInteractive",
                               "SecondaryDisplay", "HostComponent", "ClientComponent"};
        for (unsigned i = 0; i < count; i++) {
            const char *name = class_getName(classes[i]);
            for (size_t w = 0; w < sizeof words / sizeof *words; w++) {
                if (strstr(name, words[w])) {
                    P("  %s : %s  [%s]\n", name, class_getSuperclass(classes[i]) ? class_getName(class_getSuperclass(classes[i])) : "-",
                      class_getImageName(classes[i]) ?: "?");
                    break;
                }
            }
        }

        P("\n#### scene specifications and their roles\n");
        Class spec = objc_getClass("FBSSceneSpecification");
        SEL roleSel = sel_registerName("uiSceneSessionRole");
        for (unsigned i = 0; i < count; i++) {
            Class c = classes[i];
            if (!spec || !isSubclass(c, spec)) continue;
            P("  %s : %s  [%s]", class_getName(c), class_getName(class_getSuperclass(c)), class_getImageName(c) ?: "?");
            @try {
                id s = ((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName("specification"));
                if (s && [s respondsToSelector:roleSel]) {
                    id role = ((id (*)(id, SEL))objc_msgSend)(s, roleSel);
                    P("  role=%s", role ? [[role description] UTF8String] : "(nil)");
                }
            } @catch (NSException *e) {
                P("  exception %s", e.reason.UTF8String);
            }
            P("\n");
        }

        P("\n#### selectors that name a role, an accessory or an external display\n");
        const char *selwords[] = {"SessionRole", "ccessory", "xternalDisplay", "NonInteractive"};
        for (unsigned i = 0; i < count; i++) {
            Class c = classes[i];
            for (int meta = 0; meta < 2; meta++) {
                unsigned n = 0;
                Method *m = class_copyMethodList(meta ? object_getClass(c) : c, &n);
                for (unsigned j = 0; j < n; j++) {
                    const char *sel = sel_getName(method_getName(m[j]));
                    for (size_t w = 0; w < sizeof selwords / sizeof *selwords; w++) {
                        if (strstr(sel, selwords[w])) {
                            P("  %c[%s %s]  %s\n", meta ? '+' : '-', class_getName(c), sel, method_getTypeEncoding(m[j]) ?: "");
                            break;
                        }
                    }
                }
                free(m);
            }
        }
        free(classes);

        P("\n#### classes in full\n");
        const char *full[] = {
            "UISceneAccessory", "UISceneAccessoryRegistration", "_UISceneHostingController",
            "_UISceneHostingControllerAdvancedConfiguration", "_UISceneHostingViewController",
            "UIApplicationSceneSpecification", "FBSSceneSpecification", "UISceneConfiguration",
        };
        for (size_t i = 0; i < sizeof full / sizeof *full; i++) dumpClass(full[i], NULL);
        P("\n#### protocols\n");
        dumpProtocol("_UISceneHostingControllerDelegate");
        dumpProtocol("_UISceneHostingControllerAdvancedDelegate");
        P("\n#### filtered\n");
        dumpClass("UIViewController", "ccessor");
        dumpClass("UIScene", "ccessor");
        dumpClass("UIWindowScene", "ccessor");
        dumpClass("UISceneSession", "role");
        dumpClass("UIApplicationSceneSettings", "isplay");
        dumpClass("FBSSceneSettings", "isplay");
        P("\n#### done\n");
    }
    return 0;
}
