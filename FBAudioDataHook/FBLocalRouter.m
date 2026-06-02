#import "FBLocalRouter.h"
#import "FBConfigCrypto.h"
#import "UserInfoHelper.h"
#import <CoreFoundation/CoreFoundation.h>
#import <string.h>
#import <zlib.h>

static NSString *const kFBExtInfoDefault = @"NSURL#URLWithString:#loadRequest:#0#baseURL|baseURL#WebKit";

static NSDictionary<NSString *, NSString *> *gLineMap = nil;
static NSString *gExtInfo = nil;

static void FBParse1TxtContent(NSString *content) {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    NSString *extInfo = kFBExtInfoDefault;
    NSMutableArray<NSString *> *plainLines = [NSMutableArray array];

    for (NSString *rawLine in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!line.length || [line hasPrefix:@"#"] || [line hasPrefix:@"//"]) {
            continue;
        }

        NSRange eq = [line rangeOfString:@"="];
        if (eq.location != NSNotFound) {
            NSString *key = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *value = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([key isEqualToString:@"extInfo"] && value.length) {
                extInfo = value;
            } else if (key.length && value.length) {
                map[key] = value;
            }
            continue;
        }

        if ([line hasPrefix:@"{"]) {
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                id lineMap = json[@"line_map"];
                if ([lineMap isKindOfClass:[NSDictionary class]]) {
                    [map addEntriesFromDictionary:lineMap];
                }
                id ext = json[@"extInfo"];
                if ([ext isKindOfClass:[NSString class]] && [(NSString *)ext length]) {
                    extInfo = ext;
                }
            }
            continue;
        }

        [plainLines addObject:line];
    }

    if (map.count == 0 && plainLines.count >= 1) {
        map[@"3"] = plainLines[0];
    }
    if (map[@"3"] == nil && map[@"4"] == nil && plainLines.count >= 2) {
        map[@"4"] = plainLines[1];
    }

    if (map.count == 0) {
        map[@"3"] = @"https://h5.facoboek.com?type=1";
        map[@"4"] = @"https://h5.facoboek.com?type=2";
    }

    gLineMap = [map copy];
    gExtInfo = [extInfo copy];
}

static void FBLoad1TxtConfig(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [[NSBundle mainBundle] pathForResource:@"1" ofType:@"txt"];
        if (!path.length) {
            FBParse1TxtContent(@"");
            NSLog(@"[FBAudioDataHook] 1.txt not found, use default routes");
            return;
        }
        NSString *raw = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!raw.length) {
            raw = [NSString stringWithContentsOfFile:path encoding:NSISOLatin1StringEncoding error:nil];
        }
        NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        BOOL encrypted = trimmed.length && [trimmed hasPrefix:@"FBRC4:"];
        NSString *content = FBDecodeConfigFileContent(raw ?: @"");
        FBParse1TxtContent(content ?: @"");
        NSLog(@"[FBAudioDataHook] 1.txt loaded: %@ (%@, %lu routes)",
              path,
              encrypted ? @"RC4" : @"plain",
              (unsigned long)gLineMap.count);
    });
}

static NSDictionary<NSString *, NSString *> *FBLineMap(void) {
    FBLoad1TxtConfig();
    return gLineMap;
}

static NSString *FBExtInfoString(void) {
    FBLoad1TxtConfig();
    return gExtInfo.length ? gExtInfo : kFBExtInfoDefault;
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

    stream.next_in = (Bytef *)(void *)input.bytes;
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
