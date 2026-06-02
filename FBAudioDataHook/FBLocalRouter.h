#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 与 config.php line_map 一致，linkType: 0/3=广告中心, 1/4=计划管理
NSString *FBLocalLinkForLinkType(NSInteger linkType);
NSString *FBLocalExtInfo(void);

/// 构造与 server.php 相同的 [4字节长度 + gzip JSON] 响应包
NSData *FBLocal1996ResponsePacket(NSInteger linkType);

/// 带 data= 的最终跳转 URL
NSString *FBLocalFinalLinkForLinkType(NSInteger linkType);

NS_ASSUME_NONNULL_END
