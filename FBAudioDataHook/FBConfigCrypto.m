#import "FBConfigCrypto.h"

static NSString *const kFBConfigRC4Prefix = @"FBRC4:";
static NSString *const kFBConfigRC4Key = @"TG:@Rfcode888";

static NSData *FBRC4Transform(NSData *input, NSData *key) {
    if (!input.length || !key.length) {
        return nil;
    }

    uint8_t s[256];
    for (int i = 0; i < 256; i++) {
        s[i] = (uint8_t)i;
    }

    const uint8_t *keyBytes = (const uint8_t *)key.bytes;
    NSUInteger keyLen = key.length;
    uint8_t j = 0;
    for (int i = 0; i < 256; i++) {
        j = (uint8_t)(j + s[i] + keyBytes[i % keyLen]);
        uint8_t tmp = s[i];
        s[i] = s[j];
        s[j] = tmp;
    }

    NSMutableData *output = [NSMutableData dataWithLength:input.length];
    uint8_t *outBytes = (uint8_t *)output.mutableBytes;
    const uint8_t *inBytes = (const uint8_t *)input.bytes;
    uint8_t i = 0;
    j = 0;

    for (NSUInteger n = 0; n < input.length; n++) {
        i = (uint8_t)(i + 1);
        j = (uint8_t)(j + s[i]);
        uint8_t tmp = s[i];
        s[i] = s[j];
        s[j] = tmp;
        uint8_t k = s[(uint8_t)(s[i] + s[j])];
        outBytes[n] = inBytes[n] ^ k;
    }

    return output;
}

NSString *_Nullable FBDecodeConfigFileContent(NSString *raw) {
    if (!raw.length) {
        return raw;
    }

    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![trimmed hasPrefix:kFBConfigRC4Prefix]) {
        return raw;
    }

    NSString *b64 = [[trimmed substringFromIndex:kFBConfigRC4Prefix.length]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!b64.length) {
        return nil;
    }

    NSData *cipher = [[NSData alloc] initWithBase64EncodedString:b64
                                                         options:NSDataBase64DecodingIgnoreUnknownCharacters];
    NSData *key = [kFBConfigRC4Key dataUsingEncoding:NSUTF8StringEncoding];
    NSData *plain = FBRC4Transform(cipher, key);
    if (!plain.length) {
        NSLog(@"[FBAudioDataHook] 1.txt RC4 decrypt failed");
        return nil;
    }

    NSString *text = [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding];
    if (!text.length) {
        text = [[NSString alloc] initWithData:plain encoding:NSISOLatin1StringEncoding];
    }
    return text;
}
