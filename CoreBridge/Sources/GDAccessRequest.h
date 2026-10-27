#import <CoreBridge/GDProcessInfo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A file access to evaluate: the opener and, when known, the responsible process.
NS_SWIFT_SENDABLE
@interface GDAccessRequest : NSObject

@property(nonatomic, copy, readonly) NSString *filePath;
@property(nonatomic, strong, readonly) GDProcessInfo *process;
@property(nonatomic, strong, readonly, nullable) GDProcessInfo *responsible;

- (instancetype)initWithFilePath:(NSString *)filePath
                         process:(GDProcessInfo *)process
                     responsible:(nullable GDProcessInfo *)responsible NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
