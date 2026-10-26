#import "GDProcessInfo.h"

@implementation GDProcessInfo

- (instancetype)initWithPath:(NSString *)path
                   signingId:(NSString *)signingId
                      teamId:(NSString *)teamId {
  self = [super init];
  if (self != nil) {
    _path = [path copy];
    _signingId = [signingId copy];
    _teamId = [teamId copy];
  }
  return self;
}

@end
