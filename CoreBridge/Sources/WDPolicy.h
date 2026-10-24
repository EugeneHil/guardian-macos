#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for policy parsing failures.
FOUNDATION_EXPORT NSErrorDomain const WDPolicyErrorDomain;
/// `NSError.userInfo` key holding `[String]`: one `warden::describe` line per validation error.
FOUNDATION_EXPORT NSErrorUserInfoKey const WDPolicyValidationErrorsKey;

/// A parsed and validated policy; immutable.
NS_SWIFT_SENDABLE
@interface WDPolicy : NSObject

@property(nonatomic, readonly) int64_t version;
@property(nonatomic, readonly) NSUInteger ruleCount;

/// Parses and validates a policy document; fails with `WDPolicyErrorDomain`.
+ (nullable instancetype)policyWithJSON:(NSData *)json
                                  error:(NSError **)error NS_SWIFT_NAME(init(json:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
