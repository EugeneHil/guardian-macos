#import "GDEngine.h"

#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <guardian/engine.hpp>
#include <guardian/path.hpp>
#include <guardian/version.hpp>

#import "GDPolicyInternal.hpp"

namespace {

std::string toStd(NSString *value) {
  const char *utf8 = value.UTF8String;
  return utf8 != nullptr ? std::string(utf8) : std::string();
}

// ADR-0001: the ES path form is unverified, so process paths are normalized before matching.
guardian::ProcessInfo toCore(GDProcessInfo *info) {
  guardian::ProcessInfo out;
  out.path = guardian::normalizePath(toStd(info.path));
  out.signingId = toStd(info.signingId);
  out.teamId = toStd(info.teamId);
  return out;
}

NSString *toNS(const std::string &value) {
  NSString *text = [NSString stringWithUTF8String:value.c_str()];
  return text != nil ? text : @"";
}

}  // namespace

@implementation GDEngine {
  std::unique_ptr<const guardian::Engine> _engine;
}

- (instancetype)initWithPolicy:(GDPolicy *)policy {
  self = [super init];
  if (self != nil) {
    // Fail-open: if construction throws (e.g. std::bad_alloc) the engine stays null and every
    // request is allowed; an exception must never cross into Swift.
    try {
      _engine = std::make_unique<const guardian::Engine>(policy.corePolicy);
    } catch (...) {
      _engine.reset();
    }
  }
  return self;
}

- (GDDecision *)evaluate:(GDAccessRequest *)request {
  if (_engine == nullptr) {
    return [[GDDecision alloc] initWithDeny:NO ruleId:@""];
  }
  try {
    guardian::AccessRequest core;
    core.filePath = toStd(request.filePath);
    core.process = toCore(request.process);
    if (request.responsible != nil) {
      core.responsible = toCore(request.responsible);
    }
    const guardian::Decision decision = _engine->evaluate(core);
    const BOOL deny = decision.verdict == guardian::Verdict::Deny;
    return [[GDDecision alloc] initWithDeny:deny
                                     ruleId:deny ? toNS(decision.ruleId) : @""];
  } catch (...) {
    return [[GDDecision alloc] initWithDeny:NO ruleId:@""];
  }
}

- (BOOL)isPotentiallyProtectedPath:(const char *)path length:(NSUInteger)length {
  if (_engine == nullptr) {
    return NO;
  }
  return _engine->isPotentiallyProtected(std::string_view(path, length));
}

+ (NSString *)coreVersion {
  const std::string_view version = guardian::coreVersion();
  return [[NSString alloc] initWithBytes:version.data() length:version.size() encoding:NSUTF8StringEncoding];
}

@end
