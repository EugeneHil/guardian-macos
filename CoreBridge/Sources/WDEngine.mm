#import "WDEngine.h"

#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <warden/engine.hpp>
#include <warden/path.hpp>
#include <warden/version.hpp>

#import "WDPolicyInternal.hpp"

namespace {

std::string toStd(NSString *value) {
  const char *utf8 = value.UTF8String;
  return utf8 != nullptr ? std::string(utf8) : std::string();
}

// ADR-0001: the ES path form is unverified, so process paths are normalized before matching.
warden::ProcessInfo toCore(WDProcessInfo *info) {
  warden::ProcessInfo out;
  out.path = warden::normalizePath(toStd(info.path));
  out.signingId = toStd(info.signingId);
  out.teamId = toStd(info.teamId);
  return out;
}

NSString *toNS(const std::string &value) {
  NSString *text = [NSString stringWithUTF8String:value.c_str()];
  return text != nil ? text : @"";
}

}  // namespace

@implementation WDEngine {
  std::unique_ptr<const warden::Engine> _engine;
}

- (instancetype)initWithPolicy:(WDPolicy *)policy {
  self = [super init];
  if (self != nil) {
    // Fail-open: if construction throws (e.g. std::bad_alloc) the engine stays null and every
    // request is allowed; an exception must never cross into Swift.
    try {
      _engine = std::make_unique<const warden::Engine>(policy.corePolicy);
    } catch (...) {
      _engine.reset();
    }
  }
  return self;
}

- (WDDecision *)evaluate:(WDAccessRequest *)request {
  if (_engine == nullptr) {
    return [[WDDecision alloc] initWithDeny:NO ruleId:@""];
  }
  try {
    warden::AccessRequest core;
    core.filePath = toStd(request.filePath);
    core.process = toCore(request.process);
    if (request.responsible != nil) {
      core.responsible = toCore(request.responsible);
    }
    const warden::Decision decision = _engine->evaluate(core);
    const BOOL deny = decision.verdict == warden::Verdict::Deny;
    return [[WDDecision alloc] initWithDeny:deny
                                     ruleId:deny ? toNS(decision.ruleId) : @""];
  } catch (...) {
    return [[WDDecision alloc] initWithDeny:NO ruleId:@""];
  }
}

- (BOOL)isPotentiallyProtectedPath:(const char *)path length:(NSUInteger)length {
  if (_engine == nullptr) {
    return NO;
  }
  return _engine->isPotentiallyProtected(std::string_view(path, length));
}

+ (NSString *)coreVersion {
  const std::string_view version = warden::coreVersion();
  return [[NSString alloc] initWithBytes:version.data() length:version.size() encoding:NSUTF8StringEncoding];
}

@end
