#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The verdict for one request. `ruleId` is empty on allow.
NS_SWIFT_SENDABLE
@interface WDDecision : NSObject

@property(nonatomic, readonly) BOOL deny;
@property(nonatomic, copy, readonly) NSString *ruleId;

- (instancetype)initWithDeny:(BOOL)deny ruleId:(NSString *)ruleId NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
