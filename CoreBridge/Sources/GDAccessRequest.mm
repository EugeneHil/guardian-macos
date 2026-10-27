#import "GDAccessRequest.h"

@implementation GDAccessRequest

- (instancetype)initWithFilePath:(NSString *)filePath
                         process:(GDProcessInfo *)process
                     responsible:(nullable GDProcessInfo *)responsible {
  self = [super init];
  if (self != nil) {
    _filePath = [filePath copy];
    _process = process;
    _responsible = responsible;
  }
  return self;
}

@end
