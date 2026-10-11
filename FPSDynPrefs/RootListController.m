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

// 颜色选择页：手动单选。
// 实测 specifier 从 plist 加载后 identifier/value 属性均取不到（propertyForKey 返回 nil），
// 故用 indexPath.row 判定：颜色行固定位于第 0~6 行（Color.plist 前 7 项），行号即 colorIndex 值。
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
    CFNumberRef num = (CFNumberRef)CFPreferencesCopyAppValue(CFSTR("colorIndex"), (__bridge CFStringRef)kPrefDomain);
    int v = 0;
    if(num){ CFNumberGetValue(num, kCFNumberIntType, &v); CFRelease(num); }
    return v;
}
- (BOOL)isColorRow:(NSIndexPath*)indexPath { return indexPath.section == 0 && indexPath.row < 7; }
- (UITableViewCell*)tableView:(UITableView*)tv cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    UITableViewCell* cell = [super tableView:tv cellForRowAtIndexPath:indexPath];
    if([self isColorRow:indexPath]){
        cell.accessoryType = (indexPath.row == self.currentColorIndex)
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    }
    return cell;
}
- (void)tableView:(UITableView*)tv didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    if([self isColorRow:indexPath]){
        int ni = (int)indexPath.row;
        CFNumberRef num = CFNumberCreate(NULL, kCFNumberIntType, &ni);
        CFPreferencesSetAppValue(CFSTR("colorIndex"), num, (__bridge CFStringRef)kPrefDomain);
        CFRelease(num);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefDomain);
        [tv reloadData];
        [tv deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }
    @try { [super tableView:tv didSelectRowAtIndexPath:indexPath]; } @catch(NSException* e){}
}
@end
