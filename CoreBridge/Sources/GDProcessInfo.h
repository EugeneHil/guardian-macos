#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Identity of a process as seen by the engine. An empty string means "absent".
NS_SWIFT_SENDABLE
@interface GDProcessInfo : NSObject

@property(nonatomic, copy, readonly) NSString *path;
@property(nonatomic, copy, readonly) NSString *signingId;
@property(nonatomic, copy, readonly) NSString *teamId;

- (instancetype)initWithPath:(NSString *)path
                   signingId:(NSString *)signingId
                      teamId:(NSString *)teamId NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
