#import "GDPolicy.h"

#include <exception>
#include <string_view>
#include <guardian/policy_parser.hpp>

#import "GDPolicyInternal.hpp"

NSErrorDomain const GDPolicyErrorDomain = @"GDPolicyErrorDomain";
NSErrorUserInfoKey const GDPolicyValidationErrorsKey = @"GDPolicyValidationErrors";

@implementation GDPolicy {
  guardian::Policy _policy;
}

- (instancetype)initWithCorePolicy:(guardian::Policy &&)policy {
  self = [super init];
  if (self != nil) {
    _policy = std::move(policy);
  }
  return self;
}

+ (nullable instancetype)policyWithJSON:(NSData *)json error:(NSError **)error {
  try {
    const std::string_view text(static_cast<const char *>(json.bytes), json.length);
    guardian::ParseResult result = guardian::parsePolicy(text);
    if (result.ok()) {
      return [[GDPolicy alloc] initWithCorePolicy:std::move(*result.policy)];
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:result.errors.size()];
    for (const guardian::ValidationError &item : result.errors) {
      NSString *line = [NSString stringWithUTF8String:guardian::describe(item).c_str()];
      [lines addObject:line != nil ? line : @"invalid error text"];
    }
    if (error != nullptr) {
      *error = [NSError errorWithDomain:GDPolicyErrorDomain
                                   code:1
                               userInfo:@{
                                 NSLocalizedDescriptionKey : @"The policy is invalid.",
                                 GDPolicyValidationErrorsKey : lines,
                               }];
    }
  } catch (...) {
    if (error != nullptr) {
      *error = [NSError errorWithDomain:GDPolicyErrorDomain
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

- (const guardian::Policy &)corePolicy {
  return _policy;
}

@end
