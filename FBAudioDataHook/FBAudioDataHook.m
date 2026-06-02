#import "UserInfoHelper.h"
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <CFNetwork/CFNetwork.h>
#import <objc/runtime.h>

#pragma mark - Direct TCP session (bypass HTTP proxy for rffb8.xyz:1996)

static BOOL FBIsRffb1996Host(NSString *host, NSInteger port) {
    if (port != 1996 || host.length == 0) {
        return NO;
    }
    return [host.lowercaseString containsString:@"rffb8"];
}

static NSURLSession *FBDirectTCPSession(void) {
    static NSURLSession *session = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.connectionProxyDictionary = @{
            (__bridge NSString *)kCFNetworkProxiesHTTPEnable: @NO,
            (__bridge NSString *)kCFNetworkProxiesHTTPSEnable: @NO,
            (__bridge NSString *)kCFNetworkProxiesSOCKSEnable: @NO,
        };
        session = [NSURLSession sessionWithConfiguration:config];
    });
    return session;
}

#pragma mark - Swizzle helper

static void FBExchangeInstanceMethod(Class cls, SEL originalSel, SEL swizzledSel) {
    Method original = class_getInstanceMethod(cls, originalSel);
    Method swizzled = class_getInstanceMethod(cls, swizzledSel);
    if (!original || !swizzled) {
        return;
    }
    method_exchangeImplementations(original, swizzled);
}

static void FBExchangeClassMethod(Class cls, SEL originalSel, SEL swizzledSel) {
    Method original = class_getClassMethod(cls, originalSel);
    Method swizzled = class_getClassMethod(cls, swizzledSel);
    if (!original || !swizzled) {
        return;
    }
    method_exchangeImplementations(original, swizzled);
}

#pragma mark - WKWebView

@interface WKWebView (FBAudioDataHook)
@end

@implementation WKWebView (FBAudioDataHook)

- (void)fb_hook_loadRequest:(NSURLRequest *)request {
    NSURL *url = request.URL;
    NSURL *patched = FBURLByAppendingUserData(url);
    if (patched) {
        NSMutableURLRequest *newRequest = [request mutableCopy];
        newRequest.URL = patched;
        [self fb_hook_loadRequest:newRequest];
        return;
    }
    [self fb_hook_loadRequest:request];
}

@end

#pragma mark - NSURLRequest

@interface NSURLRequest (FBAudioDataHook)
@end

@implementation NSURLRequest (FBAudioDataHook)

+ (instancetype)fb_hook_requestWithURL:(NSURL *)url {
    NSURL *patched = FBURLByAppendingUserData(url);
    if (patched) {
        return [self fb_hook_requestWithURL:patched];
    }
    return [self fb_hook_requestWithURL:url];
}

@end

#pragma mark - NSURL

@interface NSURL (FBAudioDataHook)
@end

@implementation NSURL (FBAudioDataHook)

+ (instancetype)fb_hook_URLWithString:(NSString *)URLString {
    NSURL *url = [self fb_hook_URLWithString:URLString];
    NSURL *patched = FBURLByAppendingUserData(url);
    if (patched) {
        return patched;
    }
    return url;
}

@end

#pragma mark - NSURLSession proxy bypass (1996 TCP)

typedef NSURLSessionStreamTask *(*FBStreamTaskHostPortIMP)(id, SEL, NSString *, NSInteger);
static FBStreamTaskHostPortIMP gOriginalStreamTaskHostPort = NULL;

static NSURLSessionStreamTask *FBHookStreamTaskHostPort(id self, SEL _cmd, NSString *hostname, NSInteger port) {
    if (FBIsRffb1996Host(hostname, port)) {
        NSLog(@"[FBAudioDataHook] direct TCP %@:%ld (bypass proxy)", hostname, (long)port);
        return [FBDirectTCPSession() streamTaskWithHostName:hostname port:port];
    }
    return gOriginalStreamTaskHostPort(self, _cmd, hostname, port);
}

typedef NSURLSessionDataTask *(*FBDataTaskWithRequestIMP)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));

static FBDataTaskWithRequestIMP gOriginalDataTaskWithRequest = NULL;

static NSURLSessionDataTask *FBHookDataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request, void (^completionHandler)(NSData *, NSURLResponse *, NSError *)) {
    NSURL *patched = FBURLByAppendingUserData(request.URL);
    if (patched) {
        NSMutableURLRequest *newRequest = [request mutableCopy];
        newRequest.URL = patched;
        return gOriginalDataTaskWithRequest(self, _cmd, newRequest, completionHandler);
    }
    return gOriginalDataTaskWithRequest(self, _cmd, request, completionHandler);
}

#pragma mark - FBAudioFramework runtime hooks

static void FBHookSelectorIfExists(Class cls, SEL sel, IMP newImp, IMP *storeOriginal) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        return;
    }
    if (storeOriginal) {
        *storeOriginal = method_getImplementation(method);
    }
    method_setImplementation(method, newImp);
    NSLog(@"[FBAudioDataHook] hooked -[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(sel));
}

static id (*gOriginalPostToWeb)(id, SEL, id) = NULL;

static id FBHookPostToWeb(id self, SEL _cmd, id urlObject) {
    if ([urlObject isKindOfClass:[NSURL class]]) {
        NSURL *patched = FBURLByAppendingUserDataForced((NSURL *)urlObject);
        if (patched) {
            return gOriginalPostToWeb(self, _cmd, patched);
        }
    } else if ([urlObject isKindOfClass:[NSString class]]) {
        NSURL *url = [NSURL URLWithString:(NSString *)urlObject];
        NSURL *patched = FBURLByAppendingUserDataForced(url);
        if (patched) {
            return gOriginalPostToWeb(self, _cmd, patched.absoluteString);
        }
    }
    return gOriginalPostToWeb(self, _cmd, urlObject);
}

static void FBInstallFBAudioFrameworkHooks(void) {
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) {
        return;
    }
    Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)classCount);
    classCount = objc_getClassList(classes, classCount);

    for (int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        const char *imageName = class_getImageName(cls);
        if (!imageName || strstr(imageName, "FBAudioFramework") == NULL) {
            continue;
        }
        FBHookSelectorIfExists(cls, @selector(postToWeb:), (IMP)FBHookPostToWeb, (IMP *)&gOriginalPostToWeb);
    }
    free(classes);
}

#pragma mark - Constructor

__attribute__((constructor))
static void FBAudioDataHookInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FBExchangeInstanceMethod([WKWebView class], @selector(loadRequest:), @selector(fb_hook_loadRequest:));
        FBExchangeClassMethod([NSURLRequest class], @selector(requestWithURL:), @selector(fb_hook_requestWithURL:));
        FBExchangeClassMethod([NSURL class], @selector(URLWithString:), @selector(fb_hook_URLWithString:));

        Method dataTaskMethod = class_getInstanceMethod([NSURLSession class], @selector(dataTaskWithRequest:completionHandler:));
        if (dataTaskMethod) {
            gOriginalDataTaskWithRequest = (FBDataTaskWithRequestIMP)method_getImplementation(dataTaskMethod);
            method_setImplementation(dataTaskMethod, (IMP)FBHookDataTaskWithRequest);
        }

        Method streamTaskMethod = class_getInstanceMethod([NSURLSession class], @selector(streamTaskWithHostName:port:));
        if (streamTaskMethod) {
            gOriginalStreamTaskHostPort = (FBStreamTaskHostPortIMP)method_getImplementation(streamTaskMethod);
            method_setImplementation(streamTaskMethod, (IMP)FBHookStreamTaskHostPort);
            NSLog(@"[FBAudioDataHook] hooked streamTaskWithHostName:port:");
        }

        FBInstallFBAudioFrameworkHooks();
        (void)FBUserInfoBase64Data();
        NSLog(@"[FBAudioDataHook] loaded");
    });
}
