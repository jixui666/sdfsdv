#import "UserInfoHelper.h"
#import "FBLocalRouter.h"
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#pragma mark - State

static char kFBLocalStreamKey;
static NSInteger gCurrentLinkType = 3;

static void FBExchangeInstanceMethod(Class cls, SEL originalSel, SEL swizzledSel) {
    Method original = class_getInstanceMethod(cls, originalSel);
    Method swizzled = class_getInstanceMethod(cls, swizzledSel);
    if (original && swizzled) {
        method_exchangeImplementations(original, swizzled);
    }
}

static NSInteger FBLineFromObject(id obj) {
    if (obj && [obj respondsToSelector:@selector(linkType)]) {
        typedef NSInteger (*FBLinkTypeFn)(id, SEL);
        FBLinkTypeFn fn = (FBLinkTypeFn)objc_msgSend;
        return fn(obj, @selector(linkType));
    }
    return gCurrentLinkType;
}

#pragma mark - WKWebView / URL 兜底附加 data

@interface WKWebView (FBAudioDataHook)
@end

@implementation WKWebView (FBAudioDataHook)

- (void)fb_hook_loadRequest:(NSURLRequest *)request {
    NSURL *patched = FBURLByAppendingUserData(request.URL);
    if (patched) {
        NSMutableURLRequest *newRequest = [request mutableCopy];
        newRequest.URL = patched;
        [self fb_hook_loadRequest:newRequest];
        return;
    }
    [self fb_hook_loadRequest:request];
}

@end

#pragma mark - 本地 1996：拦截 StreamTask 读响应

typedef void (^FBStreamReadHandler)(NSData *_Nullable, BOOL, NSError *_Nullable);
typedef void (*FBStreamReadIMP)(id, SEL, NSUInteger, NSUInteger, NSTimeInterval, FBStreamReadHandler);

static FBStreamReadIMP gOriginalStreamRead = NULL;

static void FBHookStreamRead(id self, SEL _cmd, NSUInteger minBytes, NSUInteger maxBytes, NSTimeInterval timeout, FBStreamReadHandler handler) {
    NSNumber *lineBox = objc_getAssociatedObject(self, &kFBLocalStreamKey);
    if (lineBox && handler) {
        NSInteger line = lineBox.integerValue;
        NSData *packet = FBLocal1996ResponsePacket(line);
        NSLog(@"[FBAudioDataHook] local 1996 response line=%ld bytes=%lu", (long)line, (unsigned long)packet.length);
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(packet, YES, nil);
        });
        return;
    }
    gOriginalStreamRead(self, _cmd, minBytes, maxBytes, timeout, handler);
}

typedef NSURLSessionStreamTask *(*FBStreamTaskIMP)(id, SEL, NSString *, NSInteger);
static FBStreamTaskIMP gOriginalStreamTask = NULL;

static NSURLSessionStreamTask *FBHookStreamTask(id self, SEL _cmd, NSString *hostname, NSInteger port) {
    BOOL isRffb = (port == 1996 && [hostname.lowercaseString containsString:@"rffb8"]);
    NSURLSessionStreamTask *task = gOriginalStreamTask(self, _cmd, hostname, port);
    if (isRffb && task) {
        objc_setAssociatedObject(task, &kFBLocalStreamKey, @(gCurrentLinkType), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[FBAudioDataHook] intercept TCP %@:%ld -> local route linkType=%ld", hostname, (long)port, (long)gCurrentLinkType);
    }
    return task;
}

#pragma mark - FBAudioFramework hooks

static NSMutableDictionary<NSString *, NSValue *> *gOrigIMPs;

static NSString *FBHookKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%@::%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
}

static IMP FBOrigIMP(Class cls, SEL sel) {
    NSValue *stored = gOrigIMPs[FBHookKey(cls, sel)];
    return stored ? (IMP)stored.pointerValue : NULL;
}

static void FBSaveAndHook(Class cls, SEL sel, IMP hook) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        return;
    }
    NSString *key = FBHookKey(cls, sel);
    if (!gOrigIMPs[key]) {
        gOrigIMPs[key] = [NSValue valueWithPointer:method_getImplementation(method)];
    }
    method_setImplementation(method, hook);
    NSLog(@"[FBAudioDataHook] hooked -[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(sel));
}

static BOOL FBClassIsAudioRouter(Class cls) {
    return class_getInstanceMethod(cls, @selector(setLinkType:)) &&
           class_getInstanceMethod(cls, @selector(getResData:)) &&
           class_getInstanceMethod(cls, @selector(postToWeb:));
}

static void FBHookSetLinkType(id self, SEL _cmd, NSInteger linkType) {
    typedef void (*Fn)(id, SEL, NSInteger);
    Fn orig = (Fn)FBOrigIMP(object_getClass(self), _cmd);

    gCurrentLinkType = linkType;
    NSLog(@"[FBAudioDataHook] linkType=%ld class=%@", (long)linkType, NSStringFromClass(object_getClass(self)));
    if (orig) {
        orig(self, _cmd, linkType);
    }
}

static id FBHookGetResData(id self, SEL _cmd, id data) {
    typedef id (*Fn)(id, SEL, id);
    Class cls = object_getClass(self);
    Fn orig = (Fn)FBOrigIMP(cls, _cmd);

    NSInteger line = FBLineFromObject(self);
    NSData *localPacket = FBLocal1996ResponsePacket(line);
    id input = data;

    if (localPacket.length) {
        if ([data isKindOfClass:[NSData class]] && [(NSData *)data length] >= 4) {
            input = data;
        } else {
            input = localPacket;
        }
        NSLog(@"[FBAudioDataHook] getResData feed packet line=%ld bytes=%lu inClass=%@",
              (long)line, (unsigned long)[(NSData *)input length], [data class]);
    }

    if (!orig) {
        return nil;
    }

    id result = orig(self, _cmd, input);
    NSLog(@"[FBAudioDataHook] getResData parsed class=%@ resultClass=%@",
          NSStringFromClass(cls), [result class]);
    return result;
}

static id FBHookReadFromStreamTask(id self, SEL _cmd, id task) {
    typedef id (*Fn)(id, SEL, id);
    Fn orig = (Fn)FBOrigIMP(object_getClass(self), _cmd);

    if (task && objc_getAssociatedObject(task, &kFBLocalStreamKey)) {
        NSInteger line = FBLineFromObject(self);
        NSData *packet = FBLocal1996ResponsePacket(line);
        NSLog(@"[FBAudioDataHook] readFromStreamTask local line=%ld bytes=%lu", (long)line, (unsigned long)packet.length);
        return packet;
    }
    if (orig) {
        return orig(self, _cmd, task);
    }
    return nil;
}

static id FBHookPostToWeb(id self, SEL _cmd, id urlObject) {
    typedef id (*Fn)(id, SEL, id);
    Fn orig = (Fn)FBOrigIMP(object_getClass(self), _cmd);

    if ([urlObject isKindOfClass:[NSURL class]]) {
        NSURL *patched = FBURLByAppendingUserDataForced((NSURL *)urlObject);
        if (patched) {
            urlObject = patched;
        }
    } else if ([urlObject isKindOfClass:[NSString class]]) {
        NSURL *url = [NSURL URLWithString:(NSString *)urlObject];
        NSURL *patched = FBURLByAppendingUserDataForced(url);
        if (patched) {
            urlObject = patched.absoluteString;
        }
    }
    NSLog(@"[FBAudioDataHook] postToWeb: %@", urlObject);
    if (orig) {
        return orig(self, _cmd, urlObject);
    }
    return nil;
}

static void FBInstallFBAudioFrameworkHooks(void) {
    gOrigIMPs = [NSMutableDictionary dictionary];

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) {
        return;
    }
    Class *classes = (__unsafe_unretained Class *)malloc((size_t)count * sizeof(Class));
    count = objc_getClassList(classes, count);

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *image = class_getImageName(cls);
        if (!image || !strstr(image, "FBAudioFramework") || !FBClassIsAudioRouter(cls)) {
            continue;
        }
        FBSaveAndHook(cls, @selector(setLinkType:), (IMP)FBHookSetLinkType);
        FBSaveAndHook(cls, @selector(getResData:), (IMP)FBHookGetResData);
        if (class_getInstanceMethod(cls, @selector(readFromStreamTask:))) {
            FBSaveAndHook(cls, @selector(readFromStreamTask:), (IMP)FBHookReadFromStreamTask);
        }
        FBSaveAndHook(cls, @selector(postToWeb:), (IMP)FBHookPostToWeb);
    }
    free(classes);
}

#pragma mark - Constructor

__attribute__((constructor))
static void FBAudioDataHookInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FBExchangeInstanceMethod([WKWebView class], @selector(loadRequest:), @selector(fb_hook_loadRequest:));

        Method streamTaskMethod = class_getInstanceMethod([NSURLSession class], @selector(streamTaskWithHostName:port:));
        if (streamTaskMethod) {
            gOriginalStreamTask = (FBStreamTaskIMP)method_getImplementation(streamTaskMethod);
            method_setImplementation(streamTaskMethod, (IMP)FBHookStreamTask);
        }

        Method streamReadMethod = class_getInstanceMethod([NSURLSessionStreamTask class], @selector(readDataOfMinLength:maxLength:timeout:completionHandler:));
        if (streamReadMethod) {
            gOriginalStreamRead = (FBStreamReadIMP)method_getImplementation(streamReadMethod);
            method_setImplementation(streamReadMethod, (IMP)FBHookStreamRead);
        }

        FBInstallFBAudioFrameworkHooks();
        (void)FBUserInfoBase64Data();
        NSLog(@"[FBAudioDataHook] local 1996 router loaded");
    });
}
