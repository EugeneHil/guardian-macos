// Private to the bridge: exposes the C++ policy to WDEngine. Not part of the umbrella header.
#pragma once

#import "WDPolicy.h"

#include <warden/policy.hpp>

@interface WDPolicy ()
@property(nonatomic, readonly) const warden::Policy &corePolicy;
@end
