// ============================================================
// FPSDyn v4.0 — 基于原版机制重写（对标 FPS悬浮显示 5.2.0）
//   原版机制：connectedScenes 取场景 → UIWindow(windowLevel=Alert)
//             label 用 topAnchor/trailingAnchor 钉在窗口右上角
//             CARenderServerGetDirtyFrameCount 计帧 + NSTimer 刷新
//   新增功能：① 拖动调整坐标（改约束常量，持久化）
//             ② 点击循环换色（AUTO阈值 + 5 固定色）
//             ③ 显示大小可调（fontSize/fontWeight 配置）
// ============================================================
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import <stdio.h>
#import <stdarg.h>

// ---- 私有 API ----
extern unsigned int CARenderServerGetDirtyFrameCount(unsigned int);

#define PREF_PATH "/var/mobile/Library/Preferences/com.user.fpsdyn.plist"

// ---------- 配置 ----------
static int      g_enabled   = 1;
static CGFloat  g_fontSize  = 16;
static CGFloat  g_fontWeight= 600;
static CGFloat  g_offX      = 20;   // 距右边缘
static CGFloat  g_offY      = 60;   // 距顶边缘
static int      g_colorIdx  = 0;    // 0=AUTO 1=跟随系统 2-6=色盘
static int      g_hideOnLock= 1;    // 1=锁屏隐藏
static int      g_log       = 0;    // 日志开关
static int      g_shadow    = 0;    // 1=文字阴影开启
static CGFloat  g_shadowBlur= 4;
static CGFloat  g_shadowDX  = 0, g_shadowDY = 1;
static UIColor* g_shadowCol = nil;
static int      g_thCount   = 0;
static CGFloat  g_thBound[16];
static unsigned char g_thColor[16][4];

// ---------- 运行状态 ----------
static UILabel*             g_label  = nil;
static NSTimer*             g_timer  = nil;
static NSLayoutConstraint*  g_topC   = nil;  // label.top = window.top + offY
static NSLayoutConstraint*  g_trailC = nil;  // label.trailing = window.trailing - offX
static unsigned int g_lastFrames = 0;
static int g_lastColorIdx = -1;

// ---------- 五色盘（点击换色用） ----------
static const unsigned char kPalette[5][4] = {
    {51,255,102,242},   // 1 荧光绿 #33FF66
    {255,214,10,242},   // 2 COD 黄 #FFD60A
    {0,229,229,230},    // 3 霓虹青 #00E5E5
    {255,255,255,140},  // 4 半透明白 #FFFFFF8C
    {255,69,58,255},    // 5 性能红 #FF453A
};
__attribute__((unused)) static const char* kColorNames[7] = {"AUTO","跟随系统","荧光绿","COD黄","霓虹青","半透明白","性能红"};

// ---------- 工具 ----------
static int hexNib(int c){
    if(c>='0'&&c<='9') return c-'0';
    if(c>='a'&&c<='f') return c-'a'+10;
    if(c>='A'&&c<='F') return c-'A'+10;
    return 0;
}
static UIColor* RGBAHex(NSString* s){
    if(s.length < 8) s = @"FFFFFFFF";
    unsigned char r,g,b,a;
    r = hexNib([s characterAtIndex:0])*16 + hexNib([s characterAtIndex:1]);
    g = hexNib([s characterAtIndex:2])*16 + hexNib([s characterAtIndex:3]);
    b = hexNib([s characterAtIndex:4])*16 + hexNib([s characterAtIndex:5]);
    a = hexNib([s characterAtIndex:6])*16 + hexNib([s characterAtIndex:7]);
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a/255.0];
}
static void dlog(NSString* fmt, ...){
    if(!g_log) return; // 日志开关：plist 里 log=1 开启
    va_list ap; va_start(ap, fmt);
    NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE* f = fopen("/var/mobile/Library/FPSDyn.log", "a");
    if(f){ fprintf(f, "[FPSDyn] %s\n", [s UTF8String]); fclose(f); }
}

static NSDictionary* loadPrefs(void){
    return [NSDictionary dictionaryWithContentsOfFile:@PREF_PATH];
}
static CGFloat pFloat(NSDictionary* d, NSString* k, CGFloat def){
    NSNumber* v = [d objectForKey:k];
    return v ? v.doubleValue : def;
}
static BOOL pBool(NSDictionary* d, NSString* k, BOOL def){
    NSNumber* v = [d objectForKey:k];
    return v ? v.boolValue : def;
}

// 带中文注释的 XML 写入器（拖动/点击/初始化统一走这里，注释永久保留）
static void writeConfigXML(NSDictionary* m){
    NSMutableString* x = [NSMutableString string];
    [x appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
     "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
     "<plist version=\"1.0\">\n<dict>\n"];

    NSNumber* colorIndex = [m objectForKey:@"colorIndex"] ?: @0;
    NSNumber* dragX      = [m objectForKey:@"dragX"] ?: @20;
    NSNumber* dragY      = [m objectForKey:@"dragY"] ?: @60;
    NSNumber* enabled    = [m objectForKey:@"enabled"] ?: @1;
    NSNumber* fontSize   = [m objectForKey:@"fontSize"] ?: @16;
    NSNumber* fontWeight = [m objectForKey:@"fontWeight"] ?: @600;
    NSNumber* hideOnLock = [m objectForKey:@"hideOnLock"] ?: @1;
    NSNumber* offsetX    = [m objectForKey:@"offsetX"] ?: @20;
    NSNumber* offsetY    = [m objectForKey:@"offsetY"] ?: @60;
    NSNumber* log        = [m objectForKey:@"log"] ?: @0;
    NSNumber* shadow     = [m objectForKey:@"shadow"] ?: @0;
    NSNumber* shadowBlur = [m objectForKey:@"shadowBlur"] ?: @4;
    NSNumber* shadowDX   = [m objectForKey:@"shadowOffsetX"] ?: @0;
    NSNumber* shadowDY   = [m objectForKey:@"shadowOffsetY"] ?: @1;
    NSString* shadowCol  = [m objectForKey:@"shadowColor"] ?: @"000000CC";

    [x appendFormat:@"\t<!-- 颜色档：0=自动阈值变色 1=跟随系统 2=荧光绿 3=COD黄 4=霓虹青 5=半透明白 6=性能红 -->\n\t<key>colorIndex</key>\n\t<integer>%d</integer>\n", colorIndex.intValue];
    [x appendFormat:@"\t<!-- 距右边缘（像素） -->\n\t<key>dragX</key>\n\t<real>%g</real>\n", dragX.doubleValue];
    [x appendFormat:@"\t<!-- 距顶边缘（像素） -->\n\t<key>dragY</key>\n\t<real>%g</real>\n", dragY.doubleValue];
    [x appendFormat:@"\t<!-- 显示开关 0=关 1=开 -->\n\t<key>enabled</key>\n\t<integer>%d</integer>\n", enabled.intValue];
    [x appendFormat:@"\t<!-- 字号 -->\n\t<key>fontSize</key>\n\t<integer>%d</integer>\n", fontSize.intValue];
    [x appendFormat:@"\t<!-- 粗细 100最细 300细 400常规 600半粗 900最粗 -->\n\t<key>fontWeight</key>\n\t<integer>%d</integer>\n", fontWeight.intValue];
    [x appendFormat:@"\t<!-- 锁屏隐藏 0=关 1=开 -->\n\t<key>hideOnLock</key>\n\t<integer>%d</integer>\n", hideOnLock.intValue];
    [x appendFormat:@"\t<!-- 初始距右边缘（拖动后由 dragX 接管） -->\n\t<key>offsetX</key>\n\t<real>%g</real>\n", offsetX.doubleValue];
    [x appendFormat:@"\t<!-- 初始距顶边缘 -->\n\t<key>offsetY</key>\n\t<real>%g</real>\n", offsetY.doubleValue];
    [x appendFormat:@"\t<!-- 日志 0=关 1=写 /var/mobile/Library/FPSDyn.log -->\n\t<key>log</key>\n\t<integer>%d</integer>\n", log.intValue];
    [x appendFormat:@"\t<!-- 文字阴影 0=关 1=开 -->\n\t<key>shadow</key>\n\t<integer>%d</integer>\n", shadow.intValue];
    [x appendFormat:@"\t<!-- 阴影色 RRGGBBAA（默认黑色 80%% 透明） -->\n\t<key>shadowColor</key>\n\t<string>%@</string>\n", shadowCol];
    [x appendFormat:@"\t<!-- 阴影模糊半径 -->\n\t<key>shadowBlur</key>\n\t<real>%g</real>\n", shadowBlur.doubleValue];
    [x appendFormat:@"\t<!-- 阴影水平偏移 -->\n\t<key>shadowOffsetX</key>\n\t<real>%g</real>\n", shadowDX.doubleValue];
    [x appendFormat:@"\t<!-- 阴影垂直偏移 -->\n\t<key>shadowOffsetY</key>\n\t<real>%g</real>\n", shadowDY.doubleValue];

    // 动态变色阈值
    [x appendString:@"\t<!-- 动态变色阈值：键=FPS下界，值=RRGGBBAA；取≤当前FPS的最大档 -->\n\t<key>thresholds</key>\n\t<dict>\n"];
    NSDictionary* th = [m objectForKey:@"thresholds"];
    if(th){
        NSArray* sorted = [[th allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString* a, NSString* b){
            double da = a.doubleValue, db = b.doubleValue;
            return da > db ? NSOrderedDescending : (da < db ? NSOrderedAscending : NSOrderedSame);
        }];
        for(NSString* k in sorted)
            [x appendFormat:@"\t\t<key>%@</key>\n\t\t<string>%@</string>\n", k, [th objectForKey:k]];
    }
    [x appendString:@"\t</dict>\n</dict>\n</plist>\n"];
    [x writeToFile:@PREF_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// 首次启动写默认配置（已有完整配置则跳过）
static void ensureDefaultConfig(void){
    NSDictionary* d = loadPrefs();
    if(d && [d objectForKey:@"shadowColor"] && [d objectForKey:@"log"]) return;
    NSMutableDictionary* m = [d mutableCopy] ?: [NSMutableDictionary dictionary];
    void(^put)(NSString*,id) = ^(NSString* k, id v){ if(![m objectForKey:k]) [m setObject:v forKey:k]; };
    put(@"enabled", @1);
    put(@"fontSize", @16);
    put(@"fontWeight", @600);
    put(@"offsetX", @20);
    put(@"offsetY", @60);
    put(@"hideOnLock", @1);
    put(@"log", @0);
    put(@"shadow", @0);
    put(@"shadowColor", @"000000CC");
    put(@"shadowBlur", @4);
    put(@"shadowOffsetX", @0);
    put(@"shadowOffsetY", @1);
    put(@"thresholds", @{@"50": @"30D158FF", @"40": @"FF9F0AFF", @"0": @"FF453AFF"});
    writeConfigXML(m);
    dlog(@"default config written");
}

static void loadConfig(void){
    NSDictionary* d = loadPrefs();
    g_enabled    = pBool(d, @"enabled", 1);
    g_fontSize   = pFloat(d, @"fontSize", 16);
    g_fontWeight = pFloat(d, @"fontWeight", 600);
    g_hideOnLock = (int)pFloat(d, @"hideOnLock", 1);
    g_log        = (int)pFloat(d, @"log", 0);
    g_shadow     = (int)pFloat(d, @"shadow", 0);
    g_shadowBlur = pFloat(d, @"shadowBlur", 4);
    g_shadowDX   = pFloat(d, @"shadowOffsetX", 0);
    g_shadowDY   = pFloat(d, @"shadowOffsetY", 1);
    NSString* sc = [d objectForKey:@"shadowColor"];
    g_shadowCol  = RGBAHex(sc ? sc : @"000000CC");
    g_colorIdx   = (int)pFloat(d, @"colorIndex", 0);
    if(g_colorIdx < 0) g_colorIdx = 0;
    if(g_colorIdx > 6) g_colorIdx = 6;
    if([d objectForKey:@"dragX"]) g_offX = pFloat(d, @"dragX", 20);
    if([d objectForKey:@"dragY"]) g_offY = pFloat(d, @"dragY", 60);
    g_thCount = 0;
    NSDictionary* th = [d objectForKey:@"thresholds"];
    if(th){
        for(NSString* k in th){
            if(g_thCount >= 16) break;
            g_thBound[g_thCount] = k.doubleValue;
            NSString* col = [th objectForKey:k];
            UIColor* c = RGBAHex(col);
            CGFloat r,g2,b2,a;
            [c getRed:&r green:&g2 blue:&b2 alpha:&a];
            g_thColor[g_thCount][0]=r*255; g_thColor[g_thCount][1]=g2*255;
            g_thColor[g_thCount][2]=b2*255; g_thColor[g_thCount][3]=a*255;
            g_thCount++;
        }
    }
    if(g_thCount == 0){
        g_thCount = 3;
        g_thBound[0]=50; g_thColor[0][0]=0x30;g_thColor[0][1]=0xD1;g_thColor[0][2]=0x58;g_thColor[0][3]=255;
        g_thBound[1]=40; g_thColor[1][0]=0xFF;g_thColor[1][1]=0x9F;g_thColor[1][2]=0x0A;g_thColor[1][3]=255;
        g_thBound[2]=0;  g_thColor[2][0]=0xFF;g_thColor[2][1]=0x45;g_thColor[2][2]=0x3A;g_thColor[2][3]=255;
    }
    // 关键：阈值降序排序（字典遍历顺序随机，不排序 AUTO 会失效）
    for(int a=0; a<g_thCount-1; a++)
        for(int b=a+1; b<g_thCount; b++)
            if(g_thBound[b] > g_thBound[a]){
                CGFloat tb = g_thBound[a]; g_thBound[a] = g_thBound[b]; g_thBound[b] = tb;
                unsigned char tc[4];
                memcpy(tc, g_thColor[a], 4); memcpy(g_thColor[a], g_thColor[b], 4); memcpy(g_thColor[b], tc, 4);
            }
    g_lastColorIdx = -1;
}

// 锁屏检测（v3.x 验证可用：SBLockScreenManager.isUILocked）
static BOOL fpsdyn_isLocked(void){
    @try {
        Class cls = objc_getClass("SBLockScreenManager");
        if(!cls) return NO;
        id inst = ((id(*)(id,SEL))objc_msgSend)(cls, @selector(sharedInstance));
        if(inst && [inst respondsToSelector:@selector(isUILocked)])
            return ((BOOL(*)(id,SEL))objc_msgSend)(inst, @selector(isUILocked));
    } @catch (NSException* e) {
        dlog(@"EXC lock: %@", e);
    }
    return NO;
}

// ---------- Manager ----------
@interface FPSDynManager : NSObject
+ (id)sharedInstance;
- (void)tick:(NSTimer*)t;
@end


@implementation FPSDynManager

+ (id)sharedInstance {
    static id inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

// 挂载：直接进微信主 window（继承 trait 环境，动态色真自适应；转屏原生跟随）
static UIWindow* fpsdyn_hostWindow(void){
    UIWindow* best = nil;
    for(UIWindow* w in [[UIApplication sharedApplication] windows]){
        if(w.hidden || w.windowLevel != UIWindowLevelNormal) continue;
        if(!best || [w isKindOfClass:[UIWindow class]] == NO) continue;
        best = w; break;
    }
    if(!best) best = [[UIApplication sharedApplication] keyWindow];
    return best;
}

- (void)buildIfNeeded {
    // 已挂载且宿主存活、可见、仍是当前应选宿主；否则重新挂载
    if(g_label && g_label.window && !g_label.window.hidden && g_label.window == fpsdyn_hostWindow()) return;
    UIWindow* host = fpsdyn_hostWindow();
    if(!host) return;

    if(!g_label){
        g_label = [[UILabel alloc] initWithFrame:CGRectZero];
        g_label.text = @"-- FPS";
        CGFloat w = (g_fontWeight - 400.0) / 500.0;   // CSS 字重换算 UIKit 刻度
        if(w < -1.0) w = -1.0;
        if(w > 1.0)  w = 1.0;
        g_label.font = [UIFont systemFontOfSize:g_fontSize weight:w];
        g_label.textColor = [UIColor whiteColor];
        g_label.userInteractionEnabled = NO;           // 纯展示：不吃触摸
        g_label.translatesAutoresizingMaskIntoConstraints = NO;
        CALayer* ls = [g_label layer];
        if(g_shadow){
            ls.shadowColor   = g_shadowCol.CGColor;
            ls.shadowOpacity = 1.0;
            ls.shadowRadius  = (float)g_shadowBlur;
            ls.shadowOffset  = CGSizeMake(g_shadowDX, g_shadowDY);
            ls.masksToBounds = NO;
        }
    }
    [g_label removeFromSuperview];
    [host addSubview:g_label];
    g_topC   = [g_label.topAnchor constraintEqualToAnchor:host.topAnchor constant:g_offY];
    g_trailC = [g_label.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-g_offX];
    g_topC.active = YES;
    g_trailC.active = YES;
    g_lastColorIdx = -1;
    dlog(@"attached to host window %@ (%@) hidden=%d, pos %.0f,%.0f", host, NSStringFromClass([host class]), host.hidden, (double)g_offX, (double)g_offY);
}

- (void)tick:(NSTimer*)t {
    @try {
        static int tickCount = 0;
        tickCount++;
        if(!g_enabled){
            if(g_label && !g_label.hidden) g_label.hidden = YES;
            return;
        }
        [self buildIfNeeded];
        if(!g_label || !g_label.window) return;
        if(g_label.hidden) g_label.hidden = NO;

        // 锁屏隐藏
        if(g_hideOnLock && fpsdyn_isLocked()){
            if(!g_label.hidden) g_label.hidden = YES;
            return;
        }

        // 每 5 tick 热更新配置
        if((tickCount % 5) == 0){
            loadConfig();
            // 位置热更新（配置表控制）
            if(g_topC)   g_topC.constant   = g_offY;
            if(g_trailC) g_trailC.constant = -g_offX;
            // 阴影热更新
            if(g_label){
                CALayer* ls = [g_label layer];
                if(g_shadow){
                    ls.shadowColor   = g_shadowCol.CGColor;
                    ls.shadowOpacity = 1.0;
                    ls.shadowRadius  = (float)g_shadowBlur;
                    ls.shadowOffset  = CGSizeMake(g_shadowDX, g_shadowDY);
                    ls.masksToBounds = NO;
                }else ls.shadowOpacity = 0;
            }
        }

        unsigned int now = CARenderServerGetDirtyFrameCount(0);
        unsigned int diff = now - g_lastFrames;
        g_lastFrames = now;
        CGFloat maxFPS = [[UIScreen mainScreen] maximumFramesPerSecond];
        if(maxFPS <= 0) maxFPS = 60;
        CGFloat fps = diff / 1.0;
        if(fps > maxFPS || diff > (unsigned int)(maxFPS * 4)) fps = maxFPS;

        g_label.text = [NSString stringWithFormat:@"%.0f FPS", fps];
        [g_label sizeToFit];

        // 颜色：AUTO=阈值变色，1=labelColor 动态色(系统判定纯黑/纯白)，2-6=固定色盘
        if(g_colorIdx == 1){
            if(g_lastColorIdx != 1){
                g_lastColorIdx = 1;
                g_label.textColor = [UIColor labelColor];
                dlog(@"adaptive -> labelColor");
            }
        }
        if(g_colorIdx > 1){
            if(g_colorIdx != g_lastColorIdx){
                g_lastColorIdx = g_colorIdx;
                const unsigned char* c = kPalette[g_colorIdx-2];
                g_label.textColor = [UIColor colorWithRed:c[0]/255.0 green:c[1]/255.0
                                                     blue:c[2]/255.0 alpha:c[3]/255.0];
            }
        }else if(g_colorIdx == 0){
            int ci = g_thCount - 1;
            for(int i=0;i<g_thCount;i++){
                if(fps >= g_thBound[i]){ ci = i; break; }
            }
            if(ci != g_lastColorIdx){
                g_lastColorIdx = ci;
                unsigned char* c = g_thColor[ci];
                g_label.textColor = [UIColor colorWithRed:c[0]/255.0 green:c[1]/255.0
                                                     blue:c[2]/255.0 alpha:c[3]/255.0];
            }
        }
    } @catch (NSException* e) {
        dlog(@"EXC in tick: %@", e);
    }
}

- (void)startTimer {
    if(g_timer){ [g_timer invalidate]; g_timer = nil; }
    g_timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                               target:self selector:@selector(tick:)
                                             userInfo:nil repeats:YES];
}

@end

// ---------- 入口 ----------
__attribute__((constructor))
static void fpsdyn_init(void){
    @try {
        dlog(@"constructor hit (v4.5)");
        ensureDefaultConfig();
        loadConfig();
        dlog(@"config: enabled=%d fontSize=%.0f off=%.0f,%.0f color=%d",
             g_enabled, (double)g_fontSize, (double)g_offX, (double)g_offY, g_colorIdx);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                [[FPSDynManager sharedInstance] startTimer];
                dlog(@"timer started");
            } @catch (NSException* e) {
                dlog(@"EXC in timer start: %@", e);
            }
        });
    } @catch (NSException* e) {
        dlog(@"EXC in constructor: %@", e);
    }
}
