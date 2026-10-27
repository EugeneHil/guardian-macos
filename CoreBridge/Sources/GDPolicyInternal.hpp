// Private to the bridge: exposes the C++ policy to GDEngine. Not part of the umbrella header.
#pragma once

#import "GDPolicy.h"

#include <guardian/policy.hpp>

@interface GDPolicy ()
@property(nonatomic, readonly) const guardian::Policy &corePolicy;
@end
