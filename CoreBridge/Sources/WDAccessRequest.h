#import <CoreBridge/WDProcessInfo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A file access to evaluate: the opener and, when known, the responsible process.
NS_SWIFT_SENDABLE
@interface WDAccessRequest : NSObject

@property(nonatomic, copy, readonly) NSString *filePath;
@property(nonatomic, strong, readonly) WDProcessInfo *process;
@property(nonatomic, strong, readonly, nullable) WDProcessInfo *responsible;

- (instancetype)initWithFilePath:(NSString *)filePath
                         process:(WDProcessInfo *)process
                     responsible:(nullable WDProcessInfo *)responsible NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
