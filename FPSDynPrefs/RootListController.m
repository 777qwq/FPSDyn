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

// 颜色选择页：模式单选 + 阈值输入同页
@interface FPSDynColorListController : PSListController
@end
@implementation FPSDynColorListController
- (NSArray*)specifiers {
    if(!_specifiers){
        _specifiers = [self loadSpecifiersFromPlistName:@"Color"
                                                target:self
                                                bundle:[NSBundle bundleForClass:[self class]]];
    }
    return _specifiers;
}
@end
