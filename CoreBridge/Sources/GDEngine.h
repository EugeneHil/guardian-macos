#import <CoreBridge/GDAccessRequest.h>
#import <CoreBridge/GDDecision.h>
#import <CoreBridge/GDPolicy.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Immutable policy evaluator; safe to share across threads.
NS_SWIFT_SENDABLE
@interface GDEngine : NSObject

- (instancetype)initWithPolicy:(GDPolicy *)policy NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Never throws: any internal failure yields an allow decision.
- (GDDecision *)evaluate:(GDAccessRequest *)request;

/// Allocation-free prefilter over raw path bytes (no `NSString`): never NO for a path `evaluate` could deny.
- (BOOL)isPotentiallyProtectedPath:(const char *)path length:(NSUInteger)length;

/// The guardian-core version this bridge was built against.
+ (NSString *)coreVersion;

@end

NS_ASSUME_NONNULL_END
