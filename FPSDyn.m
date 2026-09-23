// ============================================================
// FPSDyn — FPS 悬浮窗（rootless, iOS 13+，注入 SpringBoard）
//   · 无任何 hook：CARenderServerGetDirtyFrameCount 脏帧计数
//   · 帧率阈值动态变色（thresholds 字典，任意 RGBA）
//   · 背景任意 RGBA / 阴影颜色·模糊·偏移 / 圆角 / 位置+偏移可调
//   · 配置实时生效：改 plist 即可，免注销
// 配置文件: /var/mobile/Library/Preferences/com.user.fpsdyn.plist
// ============================================================
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <stdio.h>
#import <stdarg.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---- 私有 API ----
extern unsigned int CARenderServerGetDirtyFrameCount(unsigned int);
extern CGColorRef CGColorCreateGenericRGB(CGFloat r, CGFloat g, CGFloat b, CGFloat a);
extern void CGColorRelease(CGColorRef c);

@class FPSDynWindow;

#define PREF_PATH "/var/mobile/Library/Preferences/com.user.fpsdyn.plist"
#define MAX_TH 16

// ---------- 配置 ----------
typedef struct {
    int enabled;
    CGFloat fontSize;
    char position[16];
    CGFloat offsetX, offsetY;
    CGFloat bg[4];
    CGFloat shadowBlur, shadowDx, shadowDy;
    unsigned char shadowRGBA[4];
    CGFloat cornerRadius, padH, padV;
    CGFloat updateInterval;
    int hideOnLock;                    // 1=锁屏隐藏（默认1）
    CGFloat fontWeight;                // 100~900（默认600）
    int dynamicType;                   // 1=字号跟随系统文字大小设置（默认1）
    int thCount;
    CGFloat thBound[MAX_TH];
    unsigned char thColor[MAX_TH][4];
} FPSConfig;

static FPSConfig g_cfg;
static FPSDynWindow* g_window = nil;
static UILabel* g_label = nil;
static NSTimer* g_timer = nil;
static unsigned int g_lastFrames = 0;
static int g_lastColorIdx = -1;
static int g_manualColor = 0;          // 0=AUTO(阈值变色) 1-5=固定色盘
static CGPoint g_pos = {-1, -1};       // 拖动后的中心点坐标（-1 = 用 position/offset）
static id g_probeInst = nil;           // 锁状态探测：实例
static SEL g_probeSel = NULL;          // 锁状态探测：发现的方法
static CGFloat g_dragX = -1, g_dragY = -1; // label 中心（window 内部坐标，永不旋转）

// ---------- 五色盘（用户指定） ----------
static const unsigned char kPalette[5][4] = {
    {51,255,102,242},   // 1 荧光绿 #33FF66
    {255,214,10,242},   // 2 COD 黄 #FFD60A
    {0,229,229,230},    // 3 霓虹青 #00E5E5
    {255,255,255,140},  // 4 半透明白 #FFFFFF8C
    {255,69,58,255},    // 5 性能红 #FF453A
};

// ---------- hex "RRGGBBAA" ----------
static int hexNib(int c){
    if(c>='0'&&c<='9') return c-'0';
    if(c>='a'&&c<='f') return c-'a'+10;
    if(c>='A'&&c<='F') return c-'A'+10;
    return 0;
}
static void parseHexRGBA(NSString* hexStr, unsigned char out[4]){
    const char* hex = hexStr ? [hexStr UTF8String] : 0;
    if(!hex) hex = "FFFFFFFF";
    for(int i=0;i<4;i++){
        if(!hex[i*2]||!hex[i*2+1]){ out[i]=255; continue; }
        out[i]=(unsigned char)(hexNib(hex[i*2])*16+hexNib(hex[i*2+1]));
    }
}

// ---------- plist ----------
static NSDictionary* loadPrefs(void){
    return [NSDictionary dictionaryWithContentsOfFile:@PREF_PATH];
}
static CGFloat pFloat(NSDictionary* d, NSString* k, CGFloat def){
    NSNumber* v = [d objectForKey:k];
    return v ? [v doubleValue] : def;
}
static int pBool(NSDictionary* d, NSString* k, int def){
    NSNumber* v = [d objectForKey:k];
    return v ? [v boolValue] : def;
}
static NSString* pStr(NSDictionary* d, NSString* k, NSString* def){
    NSString* v = [d objectForKey:k];
    return v ? v : def;
}

// ---------- 调试日志 ----------
static void dlog(NSString* fmt, ...){
    va_list ap; va_start(ap, fmt);
    NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE* f = fopen("/var/mobile/Library/FPSDyn.log", "a");
    if(f){ fprintf(f, "[FPSDyn] %s\n", [s UTF8String]); fclose(f); }
}

// 首次启动：把全套默认配置写入文件，方便用户在 Filza 里直接改
static void ensureDefaultConfig(void){
    @try {
        NSDictionary* d = loadPrefs();
        if(d && [d objectForKey:@"dynamicType"] && [d objectForKey:@"hideOnLock"]) return; // 已有完整配置
        NSMutableDictionary* m = [d mutableCopy] ?: [NSMutableDictionary dictionary];
        void(^put)(NSString*,id) = ^(NSString* k, id v){ if(![m objectForKey:k]) [m setObject:v forKey:k]; };
        put(@"enabled", @1);
        put(@"fontSize", @16);
        put(@"fontWeight", @600);
        put(@"dynamicType", @1);
        put(@"hideOnLock", @1);
        put(@"updateInterval", @1.0);
        put(@"position", @"top-right");
        put(@"offsetX", @20);
        put(@"offsetY", @60);
        put(@"paddingH", @10);
        put(@"paddingV", @5);
        put(@"shadowColor", @"000000CC");
        put(@"shadowBlur", @3);
        put(@"shadowOffsetX", @0);
        put(@"shadowOffsetY", @1);
        put(@"thresholds", @{@"50": @"30D158FF", @"40": @"FF9F0AFF", @"0": @"FF453AFF"});
        [m writeToFile:@PREF_PATH atomically:YES];
        dlog(@"default config written to " PREF_PATH);

        // 生成中文说明文件（plist 不支持注释，用旁边这份 txt 当注释看）
        NSString* guide =
            @"FPSDyn 配置说明\n"
            "========================================\n"
            "本文件是 com.user.fpsdyn.plist 的注释版。改完 plist 保存后约 1 秒生效，无需注销。\n"
            "注意：点击换色 / 拖动位置时，插件会把 colorIndex / posX / posY 写回 plist，属正常现象。\n\n"
            "enabled            总开关，1=显示 0=隐藏\n"
            "fontSize           字号，默认 16\n"
            "fontWeight         字重 100~900：300 细 / 400 常规 / 600 半粗 / 700 粗 / 900 特粗\n"
            "dynamicType        1=字号跟随系统文字大小设置缩放（设置→显示与亮度→文字大小），0=固定用 fontSize\n"
            "hideOnLock         1=锁屏时隐藏 HUD，0=锁屏也显示\n"
            "updateInterval     刷新间隔（秒），默认 1.0，最小 0.1\n\n"
            "position           初始方位（拖动过 HUD 后会被 posX/posY 取代）：\n"
            "                   top-left / top-right / top-center /\n"
            "                   bottom-left / bottom-right / bottom-center / center\n"
            "offsetX / offsetY  相对方位的偏移（像素）\n"
            "posX / posY        拖动后的绝对坐标（-1 表示未拖动过，删掉这两项可恢复方位模式）\n\n"
            "colorIndex         颜色档位（点击 HUD 循环切换，此键会被点击操作自动更新）：\n"
            "                   0=自动阈值变色  1=跟随系统(深色白字/浅色黑字)  2=荧光绿\n"
            "                   3=COD黄  4=霓虹青  5=半透明白  6=性能红\n\n"
            "thresholds         自动变色规则（AUTO 档专用，子字典：键=FPS下界，值=RRGGBBAA）：\n"
            "                   规则：取所有 ≤当前FPS 的键里最大的那档颜色。\n"
            "                   默认四例（可直接改数字/颜色/增删行，最多 16 档）：\n"
            "                     \"55\"=\"30D158FF\"   ≥55 荧光绿\n"
            "                     \"48\"=\"FFD60AFF\"   48~54 COD黄\n"
            "                     \"30\"=\"00E5E5E6\"   30~47 霓虹青\n"
            "                     \"0\"=\"FF453AFF\"    <30 性能红\n"
            "                   想要 120Hz 细分：加 \"90\"=\"BF5AF2FF\"（≥90 紫）\n"
            "                   删掉整个 thresholds 键 = 恢复默认 ≥50绿/≥40黄/其余红\n\n"
            "shadowColor        文字阴影色 RRGGBBAA（00000000=关闭阴影）\n"
            "shadowBlur         阴影模糊半径\n"
            "shadowOffsetX/Y    阴影偏移\n\n"
            "paddingH / paddingV  文字与边缘留白（背景已去除，主要影响点击热区大小）\n"
            "backgroundColor / cornerRadius   3.2.1 起已废弃，背景永久透明\n\n"
            "日志文件：/var/mobile/Library/FPSDyn.log\n";
        [guide writeToFile:@"/var/mobile/Library/FPSDyn配置说明.txt"
                atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException* e) {
        dlog(@"EXC in ensureDefaultConfig: %@", e);
    }
}

static void loadConfig(void){
    NSDictionary* d = loadPrefs();
    g_cfg.enabled      = pBool(d, @"enabled", 1);
    g_cfg.fontSize     = pFloat(d, @"fontSize", 16);
    NSString* pos      = pStr(d, @"position", @"top-right");
    const char* pc = [pos UTF8String];
    int i=0; for(; i<15 && pc[i]; i++) g_cfg.position[i]=pc[i];
    g_cfg.position[i]=0;
    g_cfg.offsetX      = pFloat(d, @"offsetX", 20);
    g_cfg.offsetY      = pFloat(d, @"offsetY", 60);
    unsigned char bg4[4]; parseHexRGBA(pStr(d, @"backgroundColor", @"00000066"), bg4);
    g_cfg.bg[0]=bg4[0]/255.0; g_cfg.bg[1]=bg4[1]/255.0;
    g_cfg.bg[2]=bg4[2]/255.0; g_cfg.bg[3]=bg4[3]/255.0;
    parseHexRGBA(pStr(d, @"shadowColor", @"000000CC"), g_cfg.shadowRGBA);
    g_cfg.shadowBlur   = pFloat(d, @"shadowBlur", 3);
    g_cfg.shadowDx     = pFloat(d, @"shadowOffsetX", 0);
    g_cfg.shadowDy     = pFloat(d, @"shadowOffsetY", 1);
    g_cfg.cornerRadius = pFloat(d, @"cornerRadius", 8);
    g_cfg.padH         = pFloat(d, @"paddingH", 10);
    g_cfg.padV         = pFloat(d, @"paddingV", 5);
    g_cfg.updateInterval = pFloat(d, @"updateInterval", 1.0);
    if(g_cfg.updateInterval < 0.1) g_cfg.updateInterval = 0.1;
    g_cfg.hideOnLock = (int)pFloat(d, @"hideOnLock", 1);
    g_cfg.fontWeight = pFloat(d, @"fontWeight", 600);
    if(g_cfg.fontWeight < 100) g_cfg.fontWeight = 100;
    if(g_cfg.fontWeight > 900) g_cfg.fontWeight = 900;
    g_cfg.dynamicType = (int)pFloat(d, @"dynamicType", 1);

    g_manualColor = (int)pFloat(d, @"colorIndex", 0);
    if(g_manualColor < 0) g_manualColor = 0;
    if(g_manualColor > 6) g_manualColor = 6;
    g_dragX = pFloat(d, @"dragX", -1);
    g_dragY = pFloat(d, @"dragY", -1);
    g_pos.x = -1; g_pos.y = -1; // 旧版 posX/posY 已废弃

    // thresholds: { "50": "30D158FF", "40": "FF9F0AFF", "0": "FF453AFF" }
    g_cfg.thCount = 0;
    NSDictionary* th = [d objectForKey:@"thresholds"];
    if(th){
        NSArray* keys = [th allKeys];
        for(NSUInteger n=0; n<[keys count] && g_cfg.thCount<MAX_TH; n++){
            NSString* k = [keys objectAtIndex:n];
            CGFloat bound = [k doubleValue];
            NSString* col = [th objectForKey:k];
            if(!col) continue;
            g_cfg.thBound[g_cfg.thCount] = bound;
            parseHexRGBA(col, g_cfg.thColor[g_cfg.thCount]);
            g_cfg.thCount++;
        }
    }
    if(g_cfg.thCount == 0){ // 默认：>=50 绿 / >=40 黄 / <40 红
        g_cfg.thCount = 3;
        g_cfg.thBound[0]=50; parseHexRGBA(@"30D158FF", g_cfg.thColor[0]);
        g_cfg.thBound[1]=40; parseHexRGBA(@"FF9F0AFF", g_cfg.thColor[1]);
        g_cfg.thBound[2]=0;  parseHexRGBA(@"FF453AFF", g_cfg.thColor[2]);
    }
    // bound 降序
    for(int a=0; a<g_cfg.thCount-1; a++)
        for(int b=a+1; b<g_cfg.thCount; b++)
            if(g_cfg.thBound[b] > g_cfg.thBound[a]){
                CGFloat tb = g_cfg.thBound[a]; g_cfg.thBound[a]=g_cfg.thBound[b]; g_cfg.thBound[b]=tb;
                unsigned char tc[4];
                tc[0]=g_cfg.thColor[a][0];tc[1]=g_cfg.thColor[a][1];tc[2]=g_cfg.thColor[a][2];tc[3]=g_cfg.thColor[a][3];
                g_cfg.thColor[a][0]=g_cfg.thColor[b][0];g_cfg.thColor[a][1]=g_cfg.thColor[b][1];
                g_cfg.thColor[a][2]=g_cfg.thColor[b][2];g_cfg.thColor[a][3]=g_cfg.thColor[b][3];
                g_cfg.thColor[b][0]=tc[0];g_cfg.thColor[b][1]=tc[1];g_cfg.thColor[b][2]=tc[2];g_cfg.thColor[b][3]=tc[3];
            }
    g_lastColorIdx = -1; // 触发重设颜色
}

// ---------- 颜色 ----------
static UIColor* RGBAColor(unsigned char r, unsigned char g, unsigned char b, CGFloat a){
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a];
}

// ---------- 覆盖窗（全屏透明，只有 label 区域接收手势） ----------
@interface FPSDynWindow : UIWindow @end
@implementation FPSDynWindow
- (UIView*)hitTest:(CGPoint)p withEvent:(UIEvent*)e {
    if(!g_label) return nil;
    CGPoint lp = [g_label convertPoint:p fromView:self];
    if([g_label pointInside:lp withEvent:e]) return g_label;
    return nil; // 其余区域穿透
}
@end

// ---------- Manager ----------
@interface FPSDynManager : NSObject
+ (id)sharedInstance;
- (void)tick:(NSTimer*)t;
- (void)applyStyle;
- (void)buildIfNeeded;
- (void)onPan:(UIPanGestureRecognizer*)g;
- (void)onTap:(UITapGestureRecognizer*)g;
@end

static void saveState(void){
    @try {
        NSMutableDictionary* d = [loadPrefs() mutableCopy] ?: [NSMutableDictionary dictionary];
        [d setObject:[NSNumber numberWithInt:g_manualColor] forKey:@"colorIndex"];
        if(g_trailC && g_topC){
            [d setObject:[NSNumber numberWithDouble:g_dragX] forKey:@"dragX"];
            [d setObject:[NSNumber numberWithDouble:g_dragY] forKey:@"dragY"];
        }
        [d writeToFile:@PREF_PATH atomically:YES];
    } @catch (NSException* e) {
        dlog(@"EXC in saveState: %@", e);
    }
}

@implementation FPSDynManager

+ (id)sharedInstance {
    static id inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[FPSDynManager alloc] init]; });
    return inst;
}

- (void)buildIfNeeded {
    if(g_window) return;

    // 公开 API 取第一个前台 UIWindowScene（iOS 13+ 通用）
    UIWindowScene* scene = nil;
    NSSet<UIScene*>* scenes = [[UIApplication sharedApplication] connectedScenes];
    for(UIScene* s in scenes){
        if([s isKindOfClass:[UIWindowScene class]]){ scene = (UIWindowScene*)s; break; }
    }
    if(scene){
        g_window = [[FPSDynWindow alloc] initWithWindowScene:scene];
        dlog(@"window created with connectedScenes UIWindowScene");
    }else{
        g_window = [[FPSDynWindow alloc] initWithFrame:CGRectMake(0,0,120,40)];
        dlog(@"WARN: no UIWindowScene, fallback plain window");
    }
    [g_window setWindowLevel:2000.0];
    g_window.backgroundColor = [UIColor clearColor];
    g_window.hidden = NO;
    g_window.userInteractionEnabled = YES;
    // 全屏窗口；转屏靠手动 transform（UIKit 不会帮我们转），内容坐标系恒为竖屏
    g_window.frame = [[UIScreen mainScreen] bounds];
    g_window.transform = CGAffineTransformIdentity;

    g_label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 100, 30)];
    g_label.userInteractionEnabled = YES;
    [g_label sizeToFit];
    [g_window addSubview:g_label];

    UIPanGestureRecognizer* pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(onPan:)];
    [g_label addGestureRecognizer:pan];
    UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onTap:)];
    [g_label addGestureRecognizer:tap];
    [self applyStyle];
    dlog(@"window built (manual transform mode)");
}

// 当前转屏角度（依据硬件方向；v3.2.7 实测 Left=+90/Right=-90 为正确可读方向）
static CGFloat currentAngle(void){
    UIDeviceOrientation dev = [[UIDevice currentDevice] orientation];
    if(dev == UIDeviceOrientationLandscapeLeft)  return  (CGFloat)M_PI_2;
    if(dev == UIDeviceOrientationLandscapeRight) return -(CGFloat)M_PI_2;
    return 0;
}

- (void)onPan:(UIPanGestureRecognizer*)g {
    if(!g_window || !g_label) return;
    @try {
        NSInteger st = [g state];
        if(st == UIGestureRecognizerStateBegan || st == UIGestureRecognizerStateChanged){
            CGPoint tr = [g translationInView:g_window];
            CGRect wb = g_window.bounds; // 内容坐标系恒定，与转屏无关
            CGFloat lw = g_label.bounds.size.width, lh = g_label.bounds.size.height;
            if(g_dragX < 0) g_dragX = g_label.center.x;
            if(g_dragY < 0) g_dragY = g_label.center.y;
            g_dragX += tr.x;
            g_dragY += tr.y;
            if(g_dragX < lw/2 + 4)   g_dragX = lw/2 + 4;
            if(g_dragY < lh/2 + 4)   g_dragY = lh/2 + 4;
            if(g_dragX > wb.size.width  - lw/2 - 4) g_dragX = wb.size.width  - lw/2 - 4;
            if(g_dragY > wb.size.height - lh/2 - 4) g_dragY = wb.size.height - lh/2 - 4;
            g_label.center = CGPointMake(g_dragX, g_dragY);
            [g setTranslation:CGPointZero inView:g_window];
        }else if(st == UIGestureRecognizerStateEnded){
            saveState();
            dlog(@"center saved: %.0f,%.0f", (double)g_dragX, (double)g_dragY);
        }
    } @catch (NSException* e) {
        dlog(@"EXC in pan: %@", e);
    }
}

- (void)onTap:(UITapGestureRecognizer*)g {
    if([g state] != UIGestureRecognizerStateEnded) return;
    @try {
        g_manualColor = (g_manualColor + 1) % 7;   // 0=AUTO 1=跟随系统(黑白) 2-6=色盘
        g_lastColorIdx = -1;                       // 强制重设颜色
        saveState();
        const char* names[7] = {"AUTO","跟随系统","荧光绿","COD黄","霓虹青","半透明白","性能红"};
        dlog(@"color -> %d (%s)", g_manualColor, names[g_manualColor]);
    } @catch (NSException* e) {
        dlog(@"EXC in tap: %@", e);
    }
}

- (void)applyStyle {
    if(!g_label || !g_window) return;
    UIFont* f = [UIFont systemFontOfSize:g_cfg.fontSize weight:g_cfg.fontWeight];
    if(g_cfg.dynamicType){
        // 跟随系统文字大小设置（设置→显示与亮度→文字大小）
        UIFontMetrics* m = [UIFontMetrics metricsForTextStyle:UIFontTextStyleBody];
        UIFont* scaled = [m scaledFontForFont:f];
        if(scaled) f = scaled;
    }
    g_label.font = f;
    g_label.textAlignment = NSTextAlignmentCenter;
    g_label.textColor = RGBAColor(255,255,255,1.0);

    CALayer* layer = [g_label layer];
    layer.shadowColor   = CGColorCreateGenericRGB(g_cfg.shadowRGBA[0]/255.0,
                                                  g_cfg.shadowRGBA[1]/255.0,
                                                  g_cfg.shadowRGBA[2]/255.0, 1.0);
    layer.shadowOpacity = (float)(g_cfg.shadowRGBA[3]/255.0);
    layer.shadowRadius  = (float)g_cfg.shadowBlur;
    layer.shadowOffset  = CGSizeMake(g_cfg.shadowDx, g_cfg.shadowDy);

    CALayer* wl = (CALayer*)[g_window layer];
    wl.cornerRadius = 0;
    // 去除背景：纯文字 HUD，窗体永远透明（忽略配置中的 backgroundColor）
    g_window.backgroundColor = [UIColor clearColor];
}

- (void)tick:(NSTimer*)t {
  @try {
    // 配置热更新（每 tick 重读，量级为字节，开销可忽略）
    static int tickCount = 0;
    if((tickCount++ % 5) == 0){ loadConfig(); if(g_window) [self applyStyle]; } // 每 5 tick 重读配置并刷新样式（字号/字重热更新）
    if(!g_cfg.enabled){
        if(g_window && !g_window.hidden) g_window.hidden = YES;
        return;
    }
    [self buildIfNeeded];

    // 锁屏隐藏：运行时自动发现锁状态方法（不依赖具体选择器名）
    if(g_cfg.hideOnLock){
        static int g_lastLocked = -1;
        BOOL locked = NO;
        @try {
            if(!g_probeSel){
                // 找一个锁管理类，扫其方法列表找锁状态读方法
                const char* classNames[] = {"SBLockScreenManager", "SBLockStateController", NULL};
                for(int ci=0; !g_probeSel && classNames[ci]; ci++){
                    Class cls = objc_getClass(classNames[ci]);
                    if(!cls) continue;
                    id inst = ((id(*)(id,SEL))objc_msgSend)(cls, @selector(sharedInstance));
                    if(!inst) continue;
                    unsigned int count = 0;
                    Method* list = class_copyMethodList(object_getClass(inst), &count);
                    SEL fallback = NULL;
                    for(unsigned i=0; i<count; i++){
                        const char* n = sel_getName(method_getName(list[i]));
                        // setter 一律跳过：_setUILocked: / setUILocked: / 任何带参数(冒号)的方法
                        if(strchr(n, ':')) continue;
                        if(strstr(n, "set") || strstr(n, "Set")) continue;
                        BOOL preferred = strstr(n, "uiLocked") || strstr(n, "UILocked") ||
                                         strstr(n, "lockState") || strstr(n, "isLocked");
                        if(preferred){
                            g_probeSel = method_getName(list[i]);
                            g_probeInst = inst;
                            dlog(@"lock probe: class=%s sel=%s", classNames[ci], n);
                            break;
                        }
                        if(!fallback && strstr(n, "ock")) fallback = method_getName(list[i]);
                    }
                    if(!g_probeSel && fallback){
                        g_probeSel = fallback;
                        g_probeInst = inst;
                        dlog(@"lock probe(fallback): class=%s sel=%s", classNames[ci], sel_getName(fallback));
                    }
                    if(list) free(list);
                }
                if(!g_probeSel) dlog(@"WARN: lock probe found nothing (classes/selector missing)");
            }
            if(g_probeInst && g_probeSel){
                locked = ((BOOL(*)(id,SEL))objc_msgSend)(g_probeInst, g_probeSel);
            }
        } @catch (NSException* e) {
            dlog(@"EXC reading lock state: %@", e);
        }
        if((int)locked != g_lastLocked){
            dlog(@"lock state -> %d", (int)locked);
            g_lastLocked = (int)locked;
        }
        if(locked){
            if(!g_window.hidden) g_window.hidden = YES;
            return;
        }
    }
    if(g_window.hidden) g_window.hidden = NO;

    unsigned int now = CARenderServerGetDirtyFrameCount(0);
    unsigned int diff = now - g_lastFrames;
    g_lastFrames = now;

    // 转屏诊断：window bounds / 设备方向变化时记录
    {
        static CGSize lastB = {0, 0};
        static NSInteger lastDev = -1;
        CGSize cb = g_window.bounds.size;
        NSInteger dv = (NSInteger)[[UIDevice currentDevice] orientation];
        if(!CGSizeEqualToSize(cb, lastB) || dv != lastDev){
            dlog(@"rot diag: dev=%ld winBounds=%.0fx%.0f",
                 (long)dv, (double)cb.width, (double)cb.height);
            lastB = cb; lastDev = dv;
            // 手动转窗口：内容坐标系不变，仅视觉旋转
            CGFloat want = currentAngle();
            if(!CGAffineTransformEqualToTransform(g_window.transform, CGAffineTransformMakeRotation(want)))
                g_window.transform = CGAffineTransformMakeRotation(want);
        }
    }
    CGFloat maxFPS = [[UIScreen mainScreen] maximumFramesPerSecond];
    if(maxFPS <= 0) maxFPS = 60;
    CGFloat fps = diff / g_cfg.updateInterval;
    if(fps > maxFPS || diff > (unsigned int)(maxFPS * 4 * g_cfg.updateInterval)) fps = maxFPS; // 回绕/首帧保护

    g_label.text = [NSString stringWithFormat:@"%.0f FPS", fps];
    if(tickCount < 4) dlog(@"tick #%d: raw=%u diff=%u fps=%.0f", tickCount, now, diff, (double)fps);

    // 初始定位（未拖过时）：按 position/offset 算物理位置，再逆旋转映射到 window 内部坐标
    if(g_dragX < 0 || g_dragY < 0){
        CGFloat angle = currentAngle();
        CGRect b = [[UIScreen mainScreen] bounds];
        CGFloat Ws = (angle != 0) ? b.size.height : b.size.width;
        CGFloat Hs = (angle != 0) ? b.size.width  : b.size.height;
        const char* p = g_cfg.position;
        CGFloat px, py;
        if(p[0]=='t')      py = g_cfg.offsetY + 20;
        else if(p[0]=='b') py = Hs - g_cfg.offsetY - 20;
        else               py = Hs/2;
        if(p[0]=='t'||p[0]=='b'){
            if(p[4]=='l')      px = g_cfg.offsetX + 30;
            else if(p[4]=='r') px = Ws - g_cfg.offsetX - 30;
            else               px = Ws/2;
        }else px = Ws/2;
        CGPoint d  = CGPointMake(px - Ws/2, py - Hs/2);
        CGPoint du = CGPointApplyAffineTransform(d, CGAffineTransformMakeRotation(-angle));
        g_dragX = b.size.width/2  + du.x;
        g_dragY = b.size.height/2 + du.y;
        CGFloat lw = g_label.bounds.size.width, lh = g_label.bounds.size.height;
        if(g_dragX < lw/2+4) g_dragX = lw/2+4;
        if(g_dragY < lh/2+4) g_dragY = lh/2+4;
        if(g_dragX > b.size.width-lw/2-4)   g_dragX = b.size.width-lw/2-4;
        if(g_dragY > b.size.height-lh/2-4)  g_dragY = b.size.height-lh/2-4;
        dlog(@"initial center: %.0f,%.0f (angle %.1f)", (double)g_dragX, (double)g_dragY, (double)angle);
    }
    [g_label sizeToFit];
    g_label.center = CGPointMake(g_dragX, g_dragY);
    int ci = g_cfg.thCount - 1;
    for(int i=0;i<g_cfg.thCount;i++){
        if(fps >= g_cfg.thBound[i]){ ci = i; break; }
    }
    if(g_manualColor > 0){
        // 手动色盘：每 tick 重设（跟随系统模式需要感知深浅色切换）
        UIColor* c = nil;
        if(g_manualColor == 1){
            // 跟随系统：深色模式白字，浅色模式黑字
            UIUserInterfaceStyle style = [UIScreen mainScreen].traitCollection.userInterfaceStyle;
            c = (style == UIUserInterfaceStyleDark) ? [UIColor whiteColor] : [UIColor blackColor];
        }
        else {
            const unsigned char* p = kPalette[g_manualColor-2];
            c = RGBAColor(p[0], p[1], p[2], p[3]/255.0);
        }
        g_label.textColor = c;
    }else if(ci != g_lastColorIdx){
        g_lastColorIdx = ci;
        unsigned char* c = g_cfg.thColor[ci];
        g_label.textColor = RGBAColor(c[0], c[1], c[2], c[3]/255.0);
    }
  } @catch (NSException* e) {
    dlog(@"EXC in tick: %@", e);
  }
}

- (void)startTimer {
    if(g_timer){ [g_timer invalidate]; g_timer = nil; }
    g_timer = [NSTimer scheduledTimerWithTimeInterval:g_cfg.updateInterval
                                               target:self selector:@selector(tick:)
                                             userInfo:nil repeats:YES];
}

@end

// ---------- 入口 ----------
__attribute__((constructor))
static void fpsdyn_init(void){
    @try {
        dlog(@"constructor hit (dylib loaded)");
        ensureDefaultConfig();
        loadConfig();
        dlog(@"config loaded: enabled=%d pos=%s th=%d interval=%.1f",
             g_cfg.enabled, g_cfg.position, g_cfg.thCount, (double)g_cfg.updateInterval);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (long long)(1.0 * 1000000000ull)),
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
