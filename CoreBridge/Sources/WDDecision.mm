#import "WDDecision.h"

@implementation WDDecision

- (instancetype)initWithDeny:(BOOL)deny ruleId:(NSString *)ruleId {
  self = [super init];
  if (self != nil) {
    _deny = deny;
    _ruleId = [ruleId copy];
  }
  return self;
}

@end
