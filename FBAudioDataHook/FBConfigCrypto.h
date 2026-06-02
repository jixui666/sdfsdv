#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 解密 1.txt：FBRC4: 前缀为 RC4+Base64；否则按明文兼容
NSString *_Nullable FBDecodeConfigFileContent(NSString *raw);

NS_ASSUME_NONNULL_END
