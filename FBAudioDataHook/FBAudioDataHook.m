#import "UserInfoHelper.h"
#import "FBLocalRouter.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#pragma mark - State

static char kFBLocalStreamKey;
static NSInteger gCurrentLinkType = 3;
static __weak id gAudioRouter = nil;
static BOOL gWebPostedForCurrentClick = NO;
static NSString *gForcedWebURL = nil;

static IMP FBOrigIMP(Class cls, SEL sel);

static void FBCaptureRouter(id self) {
    if (self && [self respondsToSelector:@selector(postToWeb:)]) {
        gAudioRouter = self;
    }
}

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

#pragma mark - WKWebView 查找与强制加载

static NSArray<UIWindow *> *FBAllWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) {
        return windows;
    }
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window) {
                    [windows addObject:window];
                }
            }
        }
    }
    if (windows.count == 0) {
        [windows addObjectsFromArray:app.windows];
    }
    return windows;
}

static void FBWalkViewTree(UIView *root, void (^visit)(UIView *)) {
    if (!root || !visit) {
        return;
    }
    visit(root);
    for (UIView *sub in root.subviews) {
        FBWalkViewTree(sub, visit);
    }
}

static WKWebView *FBFindVisibleWKWebView(void) {
    __block WKWebView *found = nil;
    for (UIWindow *window in FBAllWindows()) {
        FBWalkViewTree(window, ^(UIView *view) {
            if ([view isKindOfClass:[WKWebView class]] && !view.hidden && view.alpha > 0.01 && view.window) {
                found = (WKWebView *)view;
            }
        });
    }
    return found;
}

static BOOL FBShouldRewriteWebURL(NSURL *url) {
    if (!gForcedWebURL.length) {
        return NO;
    }
    if (!url || !url.absoluteString.length) {
        return YES;
    }
    NSString *abs = url.absoluteString.lowercaseString;
    if ([abs isEqualToString:@"about:blank"]) {
        return YES;
    }
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host containsString:@"dmszj"] || [host containsString:@"fblogs"]) {
        return YES;
    }
    return NO;
}

static void FBLoadURLInVisibleWKWebView(NSString *urlString) {
    if (!urlString.length) {
        return;
    }
    WKWebView *webView = FBFindVisibleWKWebView();
    if (!webView) {
        NSLog(@"[FBAudioDataHook] WKWebView not found yet for %@", urlString);
        return;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        return;
    }
    NSURL *patched = FBURLByAppendingUserDataForced(url) ?: url;
    NSLog(@"[FBAudioDataHook] force WKWebView load: %@", patched.absoluteString);
    NSURLRequest *request = [NSURLRequest requestWithURL:patched
                                             cachePolicy:NSURLRequestUseProtocolCachePolicy
                                         timeoutInterval:60.0];
    [webView loadRequest:request];
}

static void FBForceLoadWithRetries(NSString *link) {
    if (!link.length) {
        return;
    }
    gForcedWebURL = [link copy];
    FBLoadURLInVisibleWKWebView(link);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FBLoadURLInVisibleWKWebView(link);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FBLoadURLInVisibleWKWebView(link);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FBLoadURLInVisibleWKWebView(link);
    });
}

#pragma mark - WKWebView / URL 兜底附加 data

@interface WKWebView (FBAudioDataHook)
@end

@implementation WKWebView (FBAudioDataHook)

- (void)fb_hook_loadRequest:(NSURLRequest *)request {
    if (FBShouldRewriteWebURL(request.URL) && gForcedWebURL.length) {
        NSURL *forced = [NSURL URLWithString:gForcedWebURL];
        NSURL *patched = FBURLByAppendingUserDataForced(forced) ?: forced;
        if (patched) {
            NSLog(@"[FBAudioDataHook] rewrite loadRequest %@ -> %@",
                  request.URL.absoluteString, patched.absoluteString);
            NSMutableURLRequest *newRequest = [request mutableCopy];
            newRequest.URL = patched;
            [self fb_hook_loadRequest:newRequest];
            return;
        }
    }
    NSURL *patched = FBURLByAppendingUserData(request.URL);
    if (patched) {
        NSLog(@"[FBAudioDataHook] WKWebView loadRequest: %@", patched.absoluteString);
        NSMutableURLRequest *newRequest = [request mutableCopy];
        newRequest.URL = patched;
        [self fb_hook_loadRequest:newRequest];
        return;
    }
    if (request.URL.absoluteString.length) {
        NSLog(@"[FBAudioDataHook] WKWebView loadRequest: %@", request.URL.absoluteString);
    }
    [self fb_hook_loadRequest:request];
}

- (void)fb_hook_loadHTMLString:(NSString *)string baseURL:(NSURL *)baseURL {
    if (FBShouldRewriteWebURL(baseURL) && gForcedWebURL.length) {
        NSLog(@"[FBAudioDataHook] rewrite loadHTMLString baseURL -> %@", gForcedWebURL);
        FBLoadURLInVisibleWKWebView(gForcedWebURL);
        return;
    }
    [self fb_hook_loadHTMLString:string baseURL:baseURL];
}

@end

#pragma mark - 本地 1996：拦截 StreamTask 读响应

static void FBCancelLocal1996Task(id _Nullable task) {
    if (![task isKindOfClass:[NSURLSessionTask class]]) {
        return;
    }
    if (!objc_getAssociatedObject(task, &kFBLocalStreamKey)) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[FBAudioDataHook] cancel 1996 task after local packet");
        [(NSURLSessionTask *)task cancel];
    });
}

static void FBScheduleLocalWebOpen(id router, NSInteger line) {
    (void)router;
    if (gWebPostedForCurrentClick) {
        return;
    }
    dispatch_block_t openBlock = ^{
        if (gWebPostedForCurrentClick) {
            return;
        }
        NSString *link = FBLocalFinalLinkForLinkType(line);
        if (!link.length) {
            NSLog(@"[FBAudioDataHook] local open skipped: empty link line=%ld", (long)line);
            return;
        }
        gWebPostedForCurrentClick = YES;
        NSLog(@"[FBAudioDataHook] local open line=%ld url=%@ (direct WKWebView, skip orig postToWeb)",
              (long)line, link);
        // 勿调 orig postToWeb：会请求 dmszj.sbs/fblogs.php（证书 -9802）且不会加载 H5
        FBForceLoadWithRetries(link);
    };
    dispatch_async(dispatch_get_main_queue(), openBlock);
}

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
            FBScheduleLocalWebOpen(gAudioRouter, line);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                FBCancelLocal1996Task(self);
            });
        });
        return;
    }
    gOriginalStreamRead(self, _cmd, minBytes, maxBytes, timeout, handler);
}

typedef void (*FBTaskResumeIMP)(id, SEL);
static FBTaskResumeIMP gOriginalTaskResume = NULL;

static void FBHookTaskResume(id self, SEL _cmd) {
    NSNumber *lineBox = objc_getAssociatedObject(self, &kFBLocalStreamKey);
    if (lineBox) {
        NSLog(@"[FBAudioDataHook] 1996 resume (local read) line=%ld", (long)lineBox.integerValue);
    }
    gOriginalTaskResume(self, _cmd);
}

typedef NSURLSessionStreamTask *(*FBStreamTaskIMP)(id, SEL, NSString *, NSInteger);
static FBStreamTaskIMP gOriginalStreamTask = NULL;

static NSURLSessionStreamTask *FBHookStreamTask(id self, SEL _cmd, NSString *hostname, NSInteger port) {
    NSURLSessionStreamTask *task = gOriginalStreamTask(self, _cmd, hostname, port);
    if (port == 1996 && task) {
        NSInteger line = gCurrentLinkType;
        objc_setAssociatedObject(task, &kFBLocalStreamKey, @(line), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[FBAudioDataHook] intercept TCP %@:%ld linkType=%ld (read hook feeds packet)",
              hostname, (long)port, (long)line);
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

static void FBHookSetLinkType(id self, SEL _cmd, NSInteger linkType) {
    typedef void (*Fn)(id, SEL, NSInteger);
    Fn orig = (Fn)FBOrigIMP(object_getClass(self), _cmd);

    FBCaptureRouter(self);
    gWebPostedForCurrentClick = NO;
    gCurrentLinkType = linkType;
    NSLog(@"[FBAudioDataHook] linkType=%ld class=%@", (long)linkType, NSStringFromClass(object_getClass(self)));
    if (orig) {
        orig(self, _cmd, linkType);
    }
}

static id FBHookGetResData(id self, SEL _cmd, id data) {
    FBCaptureRouter(self);
    typedef id (*Fn)(id, SEL, id);
    Class cls = object_getClass(self);
    Fn orig = (Fn)FBOrigIMP(cls, _cmd);

    NSInteger line = FBLineFromObject(self);

    // 入参为线路键（__NSCFConstantString）；须走 orig 解析。仅返回裸包会跳解析导致崩溃。
    if (data && ![data isKindOfClass:[NSData class]]) {
        NSData *packet = FBLocal1996ResponsePacket(line);
        if (orig) {
            @try {
                id result = orig(self, _cmd, data);
                if (result) {
                    NSLog(@"[FBAudioDataHook] getResData key=%@ -> %@",
                          [data class], [result class]);
                    return result;
                }
            } @catch (NSException *exception) {
                NSLog(@"[FBAudioDataHook] getResData key exception: %@", exception);
            }
            if (packet.length) {
                @try {
                    id result = orig(self, _cmd, packet);
                    if (result) {
                        NSLog(@"[FBAudioDataHook] getResData parse packet -> %@",
                              [result class]);
                        return result;
                    }
                } @catch (NSException *exception) {
                    NSLog(@"[FBAudioDataHook] getResData packet exception: %@", exception);
                }
            }
        }
        if (packet.length) {
            NSLog(@"[FBAudioDataHook] getResData fallback packet line=%ld bytes=%lu",
                  (long)line, (unsigned long)packet.length);
            dispatch_async(dispatch_get_main_queue(), ^{
                FBScheduleLocalWebOpen(self, line);
            });
            return packet;
        }
        return nil;
    }

    NSData *localPacket = FBLocal1996ResponsePacket(line);
    id input = data;
    if (localPacket.length) {
        if (![data isKindOfClass:[NSData class]] || [(NSData *)data length] < 4) {
            input = localPacket;
            NSLog(@"[FBAudioDataHook] getResData feed packet line=%ld bytes=%lu inClass=%@",
                  (long)line, (unsigned long)[(NSData *)input length], [data class]);
        }
    }

    if (!orig) {
        return localPacket.length ? localPacket : nil;
    }

    @try {
        id result = orig(self, _cmd, input);
        NSLog(@"[FBAudioDataHook] getResData parsed class=%@ resultClass=%@",
              NSStringFromClass(cls), [result class]);
        return result;
    } @catch (NSException *exception) {
        NSLog(@"[FBAudioDataHook] getResData exception: %@", exception);
        return localPacket.length ? localPacket : nil;
    }
}

static id FBHookReadFromStreamTask(id self, SEL _cmd, id task) {
    FBCaptureRouter(self);
    NSInteger line = FBLineFromObject(self);
    NSData *packet = FBLocal1996ResponsePacket(line);
    if (packet.length) {
        NSLog(@"[FBAudioDataHook] readFromStreamTask local line=%ld bytes=%lu task=%@", (long)line, (unsigned long)packet.length, task);
        // 框架会起空白 WKWebView；cancel(-999) 过早会导致不加载 URL，延迟显式 postToWeb
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            FBScheduleLocalWebOpen(gAudioRouter, line);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            FBCancelLocal1996Task(task);
        });
        return packet;
    }

    typedef id (*Fn)(id, SEL, id);
    Fn orig = (Fn)FBOrigIMP(object_getClass(self), _cmd);
    if (orig) {
        return orig(self, _cmd, task);
    }
    return nil;
}

static id FBHookPostToWeb(id self, SEL _cmd, id urlObject) {
    (void)self;
    (void)_cmd;

    gWebPostedForCurrentClick = YES;
    NSString *urlString = nil;
    if ([urlObject isKindOfClass:[NSString class]]) {
        urlString = (NSString *)urlObject;
    } else if ([urlObject isKindOfClass:[NSURL class]]) {
        urlString = [(NSURL *)urlObject absoluteString];
    }
    if (!urlString.length) {
        NSLog(@"[FBAudioDataHook] postToWeb: unsupported type %@", [urlObject class]);
        return nil;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    NSURL *patched = FBURLByAppendingUserDataForced(url);
    if (patched) {
        urlString = patched.absoluteString;
    }
    NSLog(@"[FBAudioDataHook] postToWeb intercepted -> direct WK load: %@", urlString);
    dispatch_async(dispatch_get_main_queue(), ^{
        FBForceLoadWithRetries(urlString);
    });
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
        if (!image || !strstr(image, "FBAudioFramework")) {
            continue;
        }
        if (class_getInstanceMethod(cls, @selector(setLinkType:))) {
            FBSaveAndHook(cls, @selector(setLinkType:), (IMP)FBHookSetLinkType);
        }
        if (class_getInstanceMethod(cls, @selector(getResData:))) {
            FBSaveAndHook(cls, @selector(getResData:), (IMP)FBHookGetResData);
        }
        if (class_getInstanceMethod(cls, @selector(readFromStreamTask:))) {
            FBSaveAndHook(cls, @selector(readFromStreamTask:), (IMP)FBHookReadFromStreamTask);
        }
        if (class_getInstanceMethod(cls, @selector(postToWeb:))) {
            FBSaveAndHook(cls, @selector(postToWeb:), (IMP)FBHookPostToWeb);
        }
    }
    free(classes);
}

#pragma mark - Constructor

__attribute__((constructor))
static void FBAudioDataHookInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FBInstallFBAudioFrameworkHooks();

        FBExchangeInstanceMethod([WKWebView class], @selector(loadRequest:), @selector(fb_hook_loadRequest:));
        FBExchangeInstanceMethod([WKWebView class],
                                 @selector(loadHTMLString:baseURL:),
                                 @selector(fb_hook_loadHTMLString:baseURL:));

        Method streamTaskMethod = class_getInstanceMethod([NSURLSession class], @selector(streamTaskWithHostName:port:));
        if (streamTaskMethod) {
            gOriginalStreamTask = (FBStreamTaskIMP)method_getImplementation(streamTaskMethod);
            method_setImplementation(streamTaskMethod, (IMP)FBHookStreamTask);
        }

        Method resumeMethod = class_getInstanceMethod([NSURLSessionStreamTask class], @selector(resume));
        if (resumeMethod) {
            gOriginalTaskResume = (FBTaskResumeIMP)method_getImplementation(resumeMethod);
            method_setImplementation(resumeMethod, (IMP)FBHookTaskResume);
        }
        if (!gOriginalTaskResume) {
            Method taskResumeMethod = class_getInstanceMethod([NSURLSessionTask class], @selector(resume));
            if (taskResumeMethod) {
                gOriginalTaskResume = (FBTaskResumeIMP)method_getImplementation(taskResumeMethod);
                method_setImplementation(taskResumeMethod, (IMP)FBHookTaskResume);
            }
        }

        Method streamReadMethod = class_getInstanceMethod([NSURLSessionStreamTask class], @selector(readDataOfMinLength:maxLength:timeout:completionHandler:));
        if (streamReadMethod) {
            gOriginalStreamRead = (FBStreamReadIMP)method_getImplementation(streamReadMethod);
            method_setImplementation(streamReadMethod, (IMP)FBHookStreamRead);
        }

        (void)FBUserInfoBase64Data();
        NSLog(@"[FBAudioDataHook] local 1996 router loaded");
    });
}
