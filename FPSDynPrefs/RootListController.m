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

// 颜色选择页：手动处理单选（iOS16 PSSelectableCell 不再自动勾选）
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
- (UITableViewCell*)tableView:(UITableView*)tv cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    UITableViewCell* cell = [super tableView:tv cellForRowAtIndexPath:indexPath];
    PSSpecifier* spec = [self specifierAtIndexPath:indexPath];
    if(spec && [spec.identifier hasPrefix:@"color"]){
        NSString* v = [spec propertyForKey:@"value"];
        cell.accessoryType = (v.intValue == self.currentColorIndex)
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    }
    return cell;
}
- (void)tableView:(UITableView*)tv didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    @try { [super tableView:tv didSelectRowAtIndexPath:indexPath]; } @catch(NSException* e){}
    PSSpecifier* spec = [self specifierAtIndexPath:indexPath];
    if(!spec || ![spec.identifier hasPrefix:@"color"]) return;
    NSString* v = [spec propertyForKey:@"value"];
    int ni = v.intValue;
    CFNumberRef num = CFNumberCreate(NULL, kCFNumberIntType, &ni);
    CFPreferencesSetAppValue(CFSTR("colorIndex"), num, (__bridge CFStringRef)kPrefDomain);
    CFRelease(num);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefDomain);
    [tv reloadData];
}
@end
