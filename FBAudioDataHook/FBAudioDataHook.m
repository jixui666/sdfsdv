#import "UserInfoHelper.h"
#import "FBLocalRouter.h"
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
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

static void FBHookIMP(Class cls, SEL sel, IMP imp, IMP *store) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        return;
    }
    if (store) {
        *store = method_getImplementation(m);
    }
    method_setImplementation(m, imp);
    NSLog(@"[FBAudioDataHook] hooked -[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(sel));
}

static void (*gOrigSetLinkType)(id, SEL, NSInteger) = NULL;

static void FBHookSetLinkType(id self, SEL _cmd, NSInteger linkType) {
    gCurrentLinkType = linkType;
    NSLog(@"[FBAudioDataHook] linkType=%ld", (long)linkType);
    if (gOrigSetLinkType) {
        gOrigSetLinkType(self, _cmd, linkType);
    }
}

static id (*gOrigGetResData)(id, SEL, id) = NULL;

static id FBHookGetResData(id self, SEL _cmd, id data) {
    NSInteger line = FBLineFromObject(self);
    NSString *link = FBLocalFinalLinkForLinkType(line);
    NSDictionary *result = @{
        @"link": link,
        @"extInfo": FBLocalExtInfo(),
    };
    NSLog(@"[FBAudioDataHook] getResData local -> %@", link);
    return result;
}

static id (*gOrigReadFromStreamTask)(id, SEL, id) = NULL;

static id FBHookReadFromStreamTask(id self, SEL _cmd, id task) {
    if (task && objc_getAssociatedObject(task, &kFBLocalStreamKey)) {
        NSInteger line = FBLineFromObject(self);
        NSData *packet = FBLocal1996ResponsePacket(line);
        NSLog(@"[FBAudioDataHook] readFromStreamTask local line=%ld", (long)line);
        return packet;
    }
    if (gOrigReadFromStreamTask) {
        return gOrigReadFromStreamTask(self, _cmd, task);
    }
    return nil;
}

static id (*gOrigPostToWeb)(id, SEL, id) = NULL;

static id FBHookPostToWeb(id self, SEL _cmd, id urlObject) {
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
    if (gOrigPostToWeb) {
        return gOrigPostToWeb(self, _cmd, urlObject);
    }
    return nil;
}

static void FBInstallFBAudioFrameworkHooks(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) {
        return;
    }
    Class *classes = (__unsafe_unretained Class *)malloc((size_t)count * sizeof(Class));
    count = objc_getClassList(classes, count);

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *image = class_getImageName(cls);
        if (!image || !strstr(image, "FBAudioFramework")) {
            continue;
        }
        FBHookIMP(cls, @selector(setLinkType:), (IMP)FBHookSetLinkType, (IMP *)&gOrigSetLinkType);
        FBHookIMP(cls, @selector(getResData:), (IMP)FBHookGetResData, (IMP *)&gOrigGetResData);
        FBHookIMP(cls, @selector(readFromStreamTask:), (IMP)FBHookReadFromStreamTask, (IMP *)&gOrigReadFromStreamTask);
        FBHookIMP(cls, @selector(postToWeb:), (IMP)FBHookPostToWeb, (IMP *)&gOrigPostToWeb);
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
