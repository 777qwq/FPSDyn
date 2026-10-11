#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

static NSString* const kPrefDomain = @"com.user.fpsdyn";

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

// 颜色选择页：手动处理单选。
// 判断依据用 specifier 的 "value" 属性（identifier 键在 plist 加载时不保证映射到 spec.identifier）
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
- (int)currentColorIndex {
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("colorIndex"), (__bridge CFStringRef)kPrefDomain);
    int r = 0;
    if(v){ r = [(__bridge_transfer NSNumber*)v intValue]; }
    return r;
}
// 颜色行 = 带 value 属性且能转成 int 的 specifier（阈值输入行没有 value）
- (BOOL)isColorRow:(PSSpecifier*)spec {
    if(!spec) return NO;
    id v = [spec propertyForKey:@"value"];
    return v && [v respondsToSelector:@selector(intValue)];
}
- (UITableViewCell*)tableView:(UITableView*)tv cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    UITableViewCell* cell = [super tableView:tv cellForRowAtIndexPath:indexPath];
    PSSpecifier* spec = [self specifierAtIndexPath:indexPath];
    if([self isColorRow:spec]){
        id v = [spec propertyForKey:@"value"];
        cell.accessoryType = ([v intValue] == self.currentColorIndex)
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    }
    return cell;
}
- (void)tableView:(UITableView*)tv didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    PSSpecifier* spec = [self specifierAtIndexPath:indexPath];
    if([self isColorRow:spec]){
        id v = [spec propertyForKey:@"value"];
        int ni = [v intValue];
        CFNumberRef num = CFNumberCreate(NULL, kCFNumberIntType, &ni);
        CFPreferencesSetAppValue(CFSTR("colorIndex"), num, (__bridge CFStringRef)kPrefDomain);
        CFRelease(num);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefDomain);
        [tv reloadData];
        [tv deselectRowAtIndexPath:indexPath animated:YES];
        return;   // 已自行处理，不再走 super（防止 super 的 push 逻辑干扰）
    }
    @try { [super tableView:tv didSelectRowAtIndexPath:indexPath]; } @catch(NSException* e){}
}
@end
