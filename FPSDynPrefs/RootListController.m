#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface FPSDynRootListController : PSListController
@end
@implementation FPSDynRootListController
- (NSArray*)specifiers {
    if(!_specifiers){
        _specifiers = [self loadSpecifiersFromPlistName:@"Root"
                                                target:self
                                                bundle:[NSBundle bundleForClass:[self class]]];
    }
    return _specifiers;
}
@end
