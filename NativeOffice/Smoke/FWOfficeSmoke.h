#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 仅 FW_OFFICE_SMOKE_DIR 与匹配的请求令牌同时存在时启用；普通启动返回 nil。
/// 集成到 ASCHelper.applicationDataPath 开头，隔离恢复文件、缓存和测试产物。
FOUNDATION_EXPORT NSString * _Nullable FWOfficeSmokeApplicationDataPath(void);

/// main 中在创建 ASCEventsController 之前调用；持有并包装现有外部 delegate。
FOUNDATION_EXPORT void FWOfficeSmokeInstallDelegate(void);

/// 从 ASCExternalDelegate.onCommonViewDidLoad 调用，必须在主线程启动。
FOUNDATION_EXPORT void FWOfficeSmokeStart(id commonController);

/// 从 AppDelegate.saveLocalFileWithParams 首行调用；YES 表示测试保存请求已处理。
FOUNDATION_EXPORT BOOL FWOfficeSmokeHandleSaveParams(NSDictionary *params);

NS_ASSUME_NONNULL_END
