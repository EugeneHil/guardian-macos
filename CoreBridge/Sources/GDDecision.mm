#import "GDDecision.h"

@implementation GDDecision

- (instancetype)initWithDeny:(BOOL)deny ruleId:(NSString *)ruleId {
  self = [super init];
  if (self != nil) {
    _deny = deny;
    _ruleId = [ruleId copy];
  }
  return self;
}

@end
