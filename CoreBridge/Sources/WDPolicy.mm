#import "WDPolicy.h"

#include <exception>
#include <string_view>
#include <warden/policy_parser.hpp>

#import "WDPolicyInternal.hpp"

NSErrorDomain const WDPolicyErrorDomain = @"WDPolicyErrorDomain";
NSErrorUserInfoKey const WDPolicyValidationErrorsKey = @"WDPolicyValidationErrors";

@implementation WDPolicy {
  warden::Policy _policy;
}

- (instancetype)initWithCorePolicy:(warden::Policy &&)policy {
  self = [super init];
  if (self != nil) {
    _policy = std::move(policy);
  }
  return self;
}

+ (nullable instancetype)policyWithJSON:(NSData *)json error:(NSError **)error {
  try {
    const std::string_view text(static_cast<const char *>(json.bytes), json.length);
    warden::ParseResult result = warden::parsePolicy(text);
    if (result.ok()) {
      return [[WDPolicy alloc] initWithCorePolicy:std::move(*result.policy)];
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:result.errors.size()];
    for (const warden::ValidationError &item : result.errors) {
      NSString *line = [NSString stringWithUTF8String:warden::describe(item).c_str()];
      [lines addObject:line != nil ? line : @"invalid error text"];
    }
    if (error != nullptr) {
      *error = [NSError errorWithDomain:WDPolicyErrorDomain
                                   code:1
                               userInfo:@{
                                 NSLocalizedDescriptionKey : @"The policy is invalid.",
                                 WDPolicyValidationErrorsKey : lines,
                               }];
    }
  } catch (...) {
    if (error != nullptr) {
      *error = [NSError errorWithDomain:WDPolicyErrorDomain
                                   code:2
                               userInfo:@{NSLocalizedDescriptionKey : @"The policy could not be parsed."}];
    }
  }
  return nil;
}

- (int64_t)version {
  return _policy.version;
}

- (NSUInteger)ruleCount {
  return _policy.rules.size();
}

- (const warden::Policy &)corePolicy {
  return _policy;
}

@end
