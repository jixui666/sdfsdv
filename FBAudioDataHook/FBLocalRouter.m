#import "FBLocalRouter.h"
#import "UserInfoHelper.h"
#import <zlib.h>

static NSString *const kFBExtInfoDefault = @"NSURL#URLWithString:#loadRequest:#0#baseURL|baseURL#WebKit";

static NSDictionary<NSString *, NSString *> *FBLineMap(void) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"3": @"https://h5.facoboek.com?type=1",
            @"4": @"https://h5.facoboek.com?type=2",
        };
        NSString *path = [[NSBundle mainBundle] pathForResource:@"fb_route" ofType:@"json"];
        if (!path.length) {
            return;
        }
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data.length) {
            return;
        }
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) {
            return;
        }
        id lineMap = json[@"line_map"];
        if ([lineMap isKindOfClass:[NSDictionary class]] && [lineMap count] > 0) {
            map = lineMap;
            NSLog(@"[FBAudioDataHook] fb_route.json loaded");
        }
    });
    return map;
}

static NSString *FBExtInfoString(void) {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"fb_route" ofType:@"json"];
    if (path.length) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([json isKindOfClass:[NSDictionary class]]) {
            id ext = json[@"extInfo"];
            if ([ext isKindOfClass:[NSString class]] && [(NSString *)ext length] > 0) {
                return ext;
            }
        }
    }
    return kFBExtInfoDefault;
}

static NSString *FBNormalizeLineKey(NSInteger linkType) {
    if (linkType == 4 || linkType == 1) {
        return @"4";
    }
    return @"3";
}

NSString *FBLocalLinkForLinkType(NSInteger linkType) {
    NSString *key = FBNormalizeLineKey(linkType);
    NSString *link = FBLineMap()[key];
    return link ?: @"https://h5.facoboek.com?type=1";
}

NSString *FBLocalExtInfo(void) {
    return FBExtInfoString();
}

static NSData *FBGZipData(NSData *input) {
    if (!input.length) {
        return nil;
    }

    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (deflateInit2(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        return nil;
    }

    stream.next_in = (Bytef *)input.bytes;
    stream.avail_in = (uInt)input.length;

    NSMutableData *output = [NSMutableData dataWithLength:input.length + 64];
    int status = Z_OK;

    while (status == Z_OK) {
        if (stream.total_out >= output.length) {
            [output increaseLengthBy:input.length + 64];
        }
        stream.next_out = (Bytef *)output.mutableBytes + stream.total_out;
        stream.avail_out = (uInt)(output.length - stream.total_out);
        status = deflate(&stream, Z_FINISH);
    }

    deflateEnd(&stream);
    if (status != Z_STREAM_END) {
        return nil;
    }
    output.length = stream.total_out;
    return output;
}

static NSData *FBBuildPayloadJSON(NSInteger linkType) {
    NSString *link = FBLocalFinalLinkForLinkType(linkType);
    NSDictionary *payload = @{
        @"link": link,
        @"extInfo": FBExtInfoString(),
    };
    return [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
}

NSData *FBLocal1996ResponsePacket(NSInteger linkType) {
    NSData *json = FBBuildPayloadJSON(linkType);
    NSData *gzip = FBGZipData(json);
    if (!gzip.length) {
        return nil;
    }

    uint32_t beLen = CFSwapInt32HostToBig((uint32_t)gzip.length);
    NSMutableData *packet = [NSMutableData dataWithBytes:&beLen length:4];
    [packet appendData:gzip];
    return packet;
}

NSString *FBLocalFinalLinkForLinkType(NSInteger linkType) {
    NSString *base = FBLocalLinkForLinkType(linkType);
    NSURL *url = [NSURL URLWithString:base];
    NSURL *withData = FBURLByAppendingUserDataForced(url);
    return withData.absoluteString ?: base;
}
