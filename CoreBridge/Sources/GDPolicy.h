#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for policy parsing failures.
FOUNDATION_EXPORT NSErrorDomain const GDPolicyErrorDomain;
/// `NSError.userInfo` key holding `[String]`: one `guardian::describe` line per validation error.
FOUNDATION_EXPORT NSErrorUserInfoKey const GDPolicyValidationErrorsKey;

/// A parsed and validated policy; immutable.
NS_SWIFT_SENDABLE
@interface GDPolicy : NSObject

@property(nonatomic, readonly) int64_t version;
@property(nonatomic, readonly) NSUInteger ruleCount;

/// Parses and validates a policy document; fails with `GDPolicyErrorDomain`.
+ (nullable instancetype)policyWithJSON:(NSData *)json
                                  error:(NSError **)error NS_SWIFT_NAME(init(json:));

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
