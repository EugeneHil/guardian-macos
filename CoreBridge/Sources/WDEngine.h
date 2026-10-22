#import <CoreBridge/WDAccessRequest.h>
#import <CoreBridge/WDDecision.h>
#import <CoreBridge/WDPolicy.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Immutable policy evaluator; safe to share across threads.
NS_SWIFT_SENDABLE
@interface WDEngine : NSObject

- (instancetype)initWithPolicy:(WDPolicy *)policy NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Never throws: any internal failure yields an allow decision.
- (WDDecision *)evaluate:(WDAccessRequest *)request;

/// Allocation-free prefilter over raw path bytes (no `NSString`): never NO for a path `evaluate` could deny.
- (BOOL)isPotentiallyProtectedPath:(const char *)path length:(NSUInteger)length;

/// The warden-core version this bridge was built against.
+ (NSString *)coreVersion;

@end

NS_ASSUME_NONNULL_END
