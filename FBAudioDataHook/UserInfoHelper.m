#import "UserInfoHelper.h"
#import <objc/runtime.h>

static NSString *const kDataKeys[] = {
    @"avatar",
    @"customID",
    @"lang",
    @"nickname",
    @"platform",
    @"timezone",
    @"version",
};
static const NSUInteger kDataKeyCount = 7;

static NSString *_Nullable FBReadPlistAtPath(NSString *path) {
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return nil;
    }
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![dict isKindOfClass:[NSDictionary class]] || dict.count == 0) {
        return nil;
    }

    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithCapacity:kDataKeyCount];
    for (NSUInteger i = 0; i < kDataKeyCount; i++) {
        id value = dict[kDataKeys[i]];
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
            payload[kDataKeys[i]] = value;
        }
    }
    if (payload.count == 0) {
        return nil;
    }

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!jsonData.length) {
        return nil;
    }
    return [jsonData base64EncodedStringWithOptions:0];
}

static NSArray<NSString *> *FBUserInfoPlistCandidates(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *home = NSHomeDirectory();

    [paths addObject:[home stringByAppendingPathComponent:@"OrigAppGroup/Facebook/user_info.plist"]];
    [paths addObject:[home stringByAppendingPathComponent:@"Documents/Facebook/user_info.plist"]];
    [paths addObject:[home stringByAppendingPathComponent:@"Library/Preferences/user_info.plist"]];
    [paths addObject:[home stringByAppendingPathComponent:@"user_info.plist"]];

    NSArray<NSString *> *groupIDs = @[
        @"group.com.facebookModAaron",
        @"group.com.facebook.Facebook",
        @"group.com.wm.wgttr.acPbaGBJ",
    ];
    for (NSString *groupID in groupIDs) {
        NSURL *container = [fm containerURLForSecurityApplicationGroupIdentifier:groupID];
        if (!container) {
            continue;
        }
        [paths addObject:[[container URLByAppendingPathComponent:@"OrigAppGroup/Facebook/user_info.plist" isDirectory:NO] path]];
        [paths addObject:[[container URLByAppendingPathComponent:@"Facebook/user_info.plist" isDirectory:NO] path]];
        [paths addObject:[[container URLByAppendingPathComponent:@"user_info.plist" isDirectory:NO] path]];
    }

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (bundleID.length) {
        [paths addObject:[home stringByAppendingFormat:@"/Library/Preferences/%@.plist", bundleID]];
        [paths addObject:[home stringByAppendingFormat:@"/Library/Preferences/%@/user_info.plist", bundleID]];
    }

    return paths;
}

static NSString *gUserInfoCache = nil;

NSString *_Nullable FBUserInfoBase64Data(void) {
    if (gUserInfoCache.length) {
        return gUserInfoCache;
    }
    for (NSString *path in FBUserInfoPlistCandidates()) {
        NSString *result = FBReadPlistAtPath(path);
        if (result.length) {
            NSLog(@"[FBAudioDataHook] user_info loaded: %@", path);
            gUserInfoCache = [result copy];
            return gUserInfoCache;
        }
    }
    NSLog(@"[FBAudioDataHook] user_info.plist not found");
    return nil;
}

void FBInvalidateUserInfoCache(void) {
    gUserInfoCache = nil;
}

static BOOL FBURLHasDataQueryItem(NSURL *url) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"data"] && item.value.length) {
            return YES;
        }
    }
    return NO;
}

static BOOL FBShouldAppendDataToURL(NSURL *url) {
    if (!url.absoluteString.length || FBURLHasDataQueryItem(url)) {
        return NO;
    }

    NSString *host = url.host.lowercaseString;
    if ([host containsString:@"rffb8.xyz"]) {
        return YES;
    }

    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        return NO;
    }

    // rffb8 TCP 下发的落地页通常带 type= 参数
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"type"]) {
            return YES;
        }
    }
    return NO;
}

static NSURL *_Nullable FBBuildURLWithData(NSURL *url) {
    if (!url || FBURLHasDataQueryItem(url)) {
        return nil;
    }

    NSString *dataValue = FBUserInfoBase64Data();
    if (!dataValue.length) {
        return nil;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) {
        return nil;
    }

    NSMutableArray<NSURLQueryItem *> *items = [(components.queryItems ?: @[]) mutableCopy];
    [items addObject:[NSURLQueryItem queryItemWithName:@"data" value:dataValue]];
    components.queryItems = items;

    NSURL *result = components.URL;
    if (result) {
        NSLog(@"[FBAudioDataHook] append data -> %@", result.absoluteString);
    }
    return result;
}

NSURL *_Nullable FBURLByAppendingUserData(NSURL *url) {
    if (!FBShouldAppendDataToURL(url)) {
        return nil;
    }
    return FBBuildURLWithData(url);
}

NSURL *_Nullable FBURLByAppendingUserDataForced(NSURL *url) {
    return FBBuildURLWithData(url);
}
