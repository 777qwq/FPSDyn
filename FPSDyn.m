// ============================================================
// FPSDyn v5.0 — 基于原版机制重写（对标 FPS悬浮显示 5.2.0）
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
static CGFloat  g_appliedFontSize = 0, g_appliedFontWeight = 0;
static unsigned char g_thColor[16][4];

// ---------- 运行状态 ----------
static UIWindow*            g_window = nil;
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


// ---------- 配置读取（CFPreferences 域 com.user.fpsdyn，与设置页同域） ----------
#define PREF_DOMAIN CFSTR("com.user.fpsdyn")
static id prefGet(NSString* k){
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)k, PREF_DOMAIN);
    return (__bridge_transfer id)v;
}
static double prefD(NSString* k, double def){
    id v = prefGet(k);
    return (v && [v respondsToSelector:@selector(doubleValue)]) ? [v doubleValue] : def;
}
static int prefI(NSString* k, int def){
    id v = prefGet(k);
    return (v && [v respondsToSelector:@selector(intValue)]) ? [v intValue] : def;
}
static BOOL prefB(NSString* k, BOOL def){
    id v = prefGet(k);
    if(!v || ![v respondsToSelector:@selector(boolValue)]) return def;
    return [v boolValue];
}
static NSString* prefS(NSString* k){
    id v = prefGet(k);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static void loadConfig(void){
    g_enabled    = prefB(@"enabled", 1);
    g_fontSize   = prefD(@"fontSize", 16);
    g_fontWeight = prefD(@"fontWeight", 600);
    g_hideOnLock = prefI(@"hideOnLock", 1);
    g_log        = prefI(@"log", 0);
    g_shadow     = prefI(@"shadow", 0);
    g_shadowBlur = prefD(@"shadowBlur", 4);
    g_shadowDX   = prefD(@"shadowOffsetX", 0);
    g_shadowDY   = prefD(@"shadowOffsetY", 1);
    NSString* sc = prefS(@"shadowColor");
    g_shadowCol  = RGBAHex(sc ? sc : @"000000CC");
    g_colorIdx   = prefI(@"colorIndex", 0);
    if(g_colorIdx < 0) g_colorIdx = 0;
    if(g_colorIdx > 6) g_colorIdx = 6;
    g_offX = prefD(@"dragX", 20);
    g_offY = prefD(@"dragY", 60);
    // AUTO 三档阈值：thGreen→绿 thYellow→黄 0→红（设置页可调）
    g_thCount = 3;
    double tg = prefD(@"thGreen", 50), ty = prefD(@"thYellow", 40);
    if(tg < 1) tg = 1; if(tg > 240) tg = 240;
    if(ty < 0) ty = 0; if(ty > tg-1) ty = tg-1;
    g_thBound[0]=tg; g_thColor[0][0]=0x30;g_thColor[0][1]=0xD1;g_thColor[0][2]=0x58;g_thColor[0][3]=255;
    g_thBound[1]=ty; g_thColor[1][0]=0xFF;g_thColor[1][1]=0x9F;g_thColor[1][2]=0x0A;g_thColor[1][3]=255;
    g_thBound[2]=0;  g_thColor[2][0]=0xFF;g_thColor[2][1]=0x45;g_thColor[2][2]=0x3A;g_thColor[2][3]=255;
    g_lastColorIdx = -1;
}

// window 必须有 rootViewController 才会参与系统转屏（原版能转的关键差异）
@interface FPSDynRootVC : UIViewController
@end
@implementation FPSDynRootVC
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
// 转屏瞬间隐藏 HUD、动画结束立即恢复——避开旋转中间态的四角露底
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
        if(g_window) g_window.hidden = YES;
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
        if(g_window){
            g_window.frame = (CGRect){CGPointZero, size};
            g_window.hidden = NO;
        }
    }];
}
@end

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

- (void)buildIfNeeded {
    if(g_window) return;

    // 场景：优先 UIWindowScene 类型，回退 connectedScenes 首个
    UIWindowScene* scene = nil;
    for(UIScene* s in [[UIApplication sharedApplication] connectedScenes]){
        if([s isKindOfClass:[UIWindowScene class]]){ scene = (UIWindowScene*)s; break; }
    }
    if(scene){
        g_window = [[UIWindow alloc] initWithWindowScene:scene];
        dlog(@"window with scene");
    }else{
        g_window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        dlog(@"WARN: no scene, plain window");
    }
    g_window.windowLevel = UIWindowLevelAlert;
    g_window.backgroundColor = [UIColor clearColor];
    g_window.hidden = NO;
    g_window.userInteractionEnabled = NO;     // 纯展示：触摸全穿透，不挡主界面
    g_window.frame = (CGRect){CGPointZero, [[UIScreen mainScreen] bounds].size};
    // 参与 UIKit 转屏的钥匙
    g_window.rootViewController = [[FPSDynRootVC alloc] init];

    g_label = [[UILabel alloc] initWithFrame:CGRectZero];
    g_label.text = @"-- FPS";
    // 配置用 CSS 字重(100~900)，换算到 UIKit 刻度(-1.0~1.0)
    CGFloat w = (g_fontWeight - 400.0) / 500.0;
    if(w < -1.0) w = -1.0;
    if(w > 1.0)  w = 1.0;
    g_label.font = [UIFont systemFontOfSize:g_fontSize weight:w];
    g_label.textColor = [UIColor whiteColor];
    g_label.userInteractionEnabled = NO;    // 纯展示：不吃触摸
    g_label.translatesAutoresizingMaskIntoConstraints = NO;
    [g_window addSubview:g_label];

    // 文字阴影（配置开关，默认关）
    CALayer* ls = [g_label layer];
    if(g_shadow){
        ls.shadowColor   = g_shadowCol.CGColor;
        ls.shadowOpacity = 1.0;
        ls.shadowRadius  = (float)g_shadowBlur;
        ls.shadowOffset  = CGSizeMake(g_shadowDX, g_shadowDY);
        ls.masksToBounds = NO;
    }

    // 对标原版：topAnchor/trailingAnchor 钉右上角，常量 = 拖动边距
    g_topC   = [g_label.topAnchor constraintEqualToAnchor:g_window.topAnchor
                                                constant:g_offY];
    g_trailC = [g_label.trailingAnchor constraintEqualToAnchor:g_window.trailingAnchor
                                                     constant:-g_offX];
    g_topC.active = YES;
    g_trailC.active = YES;

    dlog(@"window built, constraints attached");
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
        if(g_window.hidden) g_window.hidden = NO;
        if(g_label.hidden) g_label.hidden = NO;

        // 锁屏隐藏
        if(g_hideOnLock && fpsdyn_isLocked()){
            if(!g_label.hidden) g_label.hidden = YES;
            return;
        }

        // 转屏诊断（log=1 时可见）
        {
            static CGSize lastB = {0, 0};
            CGSize cb = g_window.bounds.size;
            CGRect sbNow = [[UIScreen mainScreen] bounds];
            CGAffineTransform t = g_window.transform;
            if(!CGSizeEqualToSize(cb, lastB) || !CGAffineTransformIsIdentity(t)){
                dlog(@"rot: screen=%.0fx%.0f winB=%.0fx%.0f t=(%.2f,%.2f,%.2f,%.2f)",
                     (double)sbNow.size.width, (double)sbNow.size.height,
                     (double)cb.width, (double)cb.height,
                     (double)t.a, (double)t.b, (double)t.c, (double)t.d);
                lastB = cb;
            }
        }

        // 每 2 tick 热更新配置（约 2 秒生效）
        if((tickCount % 2) == 0){
            loadConfig();
            // 字体热生效（仅变化时重建）
            if(g_label && (g_fontSize != g_appliedFontSize || g_fontWeight != g_appliedFontWeight)){
                CGFloat fw = (g_fontWeight - 400.0) / 500.0;
                if(fw < -1.0) fw = -1.0;
                if(fw > 1.0)  fw = 1.0;
                g_label.font = [UIFont systemFontOfSize:g_fontSize weight:fw];
                g_appliedFontSize = g_fontSize;
                g_appliedFontWeight = g_fontWeight;
            }
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
        dlog(@"constructor hit (v5.1.0)");
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
