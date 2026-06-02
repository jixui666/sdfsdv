#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 从 App 存储目录读取 user_info.plist，生成 base64 编码的 JSON 字符串
NSString *_Nullable FBUserInfoBase64Data(void);

/// 若 url 需要附加 data 参数则返回新 URL，否则返回 nil
NSURL *_Nullable FBURLByAppendingUserData(NSURL *url);

/// FBAudioFramework postToWeb 等内部调用，强制附加 data
NSURL *_Nullable FBURLByAppendingUserDataForced(NSURL *url);

NS_ASSUME_NONNULL_END
