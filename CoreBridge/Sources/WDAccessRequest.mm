#import "WDAccessRequest.h"

@implementation WDAccessRequest

- (instancetype)initWithFilePath:(NSString *)filePath
                         process:(WDProcessInfo *)process
                     responsible:(nullable WDProcessInfo *)responsible {
  self = [super init];
  if (self != nil) {
    _filePath = [filePath copy];
    _process = process;
    _responsible = responsible;
  }
  return self;
}

@end
