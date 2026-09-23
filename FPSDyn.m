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
static int      g_colorIdx  = 0;    // 0=AUTO 1-5=色盘
static int      g_thCount   = 0;
static CGFloat  g_thBound[16];
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
static const char* kColorNames[6] = {"AUTO","荧光绿","COD黄","霓虹青","半透明白","性能红"};

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

// 首次启动写默认配置（已有完整配置则跳过）
static void ensureDefaultConfig(void){
    NSDictionary* d = loadPrefs();
    if(d && [d objectForKey:@"dragX"] && [d objectForKey:@"fontSize"]) return;
    NSMutableDictionary* m = [d mutableCopy] ?: [NSMutableDictionary dictionary];
    void(^put)(NSString*,id) = ^(NSString* k, id v){ if(![m objectForKey:k]) [m setObject:v forKey:k]; };
    put(@"enabled", @1);
    put(@"fontSize", @16);
    put(@"fontWeight", @600);
    put(@"offsetX", @20);
    put(@"offsetY", @60);
    put(@"thresholds", @{@"50": @"30D158FF", @"40": @"FF9F0AFF", @"0": @"FF453AFF"});
    [m writeToFile:@PREF_PATH atomically:YES];
    dlog(@"default config written");
}

static void loadConfig(void){
    NSDictionary* d = loadPrefs();
    g_enabled    = pBool(d, @"enabled", 1);
    g_fontSize   = pFloat(d, @"fontSize", 16);
    g_fontWeight = pFloat(d, @"fontWeight", 600);
    g_colorIdx   = (int)pFloat(d, @"colorIndex", 0);
    if(g_colorIdx < 0) g_colorIdx = 0;
    if(g_colorIdx > 5) g_colorIdx = 5;
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
    g_lastColorIdx = -1;
}

// 覆盖窗：只有 label 区域接收触摸，其余穿透
@interface FPSDynWindow : UIWindow @end
@implementation FPSDynWindow
- (UIView*)hitTest:(CGPoint)p withEvent:(UIEvent*)e {
    if(!g_label) return nil;
    CGPoint lp = [g_label convertPoint:p fromView:self];
    return [g_label pointInside:lp withEvent:e] ? g_label : nil;
}
@end

// window 必须有 rootViewController 才会参与系统转屏（原版能转的关键差异）
@interface FPSDynRootVC : UIViewController
@end
@implementation FPSDynRootVC
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
// 转屏动画期间把窗口精确钉到新尺寸，消除四角黑边
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if(g_window) g_window.frame = (CGRect){CGPointZero, size};
        });
    } completion:nil];
}
@end

// ---------- Manager ----------
@interface FPSDynManager : NSObject
+ (id)sharedInstance;
- (void)tick:(NSTimer*)t;
- (void)onPan:(UIPanGestureRecognizer*)g;
- (void)onTap:(UITapGestureRecognizer*)g;
@end

static void saveState(void){
    NSMutableDictionary* d = [loadPrefs() mutableCopy] ?: [NSMutableDictionary dictionary];
    [d setObject:[NSNumber numberWithInt:g_colorIdx] forKey:@"colorIndex"];
    [d setObject:[NSNumber numberWithDouble:g_offX] forKey:@"dragX"];
    [d setObject:[NSNumber numberWithDouble:g_offY] forKey:@"dragY"];
    [d writeToFile:@PREF_PATH atomically:YES];
}

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
        g_window = [[FPSDynWindow alloc] initWithWindowScene:scene];
        dlog(@"window with scene");
    }else{
        g_window = [[FPSDynWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        dlog(@"WARN: no scene, plain window");
    }
    g_window.windowLevel = UIWindowLevelAlert;
    g_window.backgroundColor = [UIColor clearColor];
    g_window.hidden = NO;
    g_window.userInteractionEnabled = YES;
    g_window.frame = (CGRect){CGPointZero, [[UIScreen mainScreen] bounds].size};
    // 参与 UIKit 转屏的钥匙
    g_window.rootViewController = [[FPSDynRootVC alloc] init];

    g_label = [[UILabel alloc] initWithFrame:CGRectZero];
    g_label.text = @"-- FPS";
    g_label.font = [UIFont systemFontOfSize:g_fontSize weight:g_fontWeight];
    g_label.textColor = [UIColor whiteColor];
    g_label.userInteractionEnabled = YES;
    g_label.translatesAutoresizingMaskIntoConstraints = NO;
    [g_window addSubview:g_label];

    // 对标原版：topAnchor/trailingAnchor 钉右上角，常量 = 拖动边距
    g_topC   = [g_label.topAnchor constraintEqualToAnchor:g_window.topAnchor
                                                constant:g_offY];
    g_trailC = [g_label.trailingAnchor constraintEqualToAnchor:g_window.trailingAnchor
                                                     constant:-g_offX];
    g_topC.active = YES;
    g_trailC.active = YES;

    UIPanGestureRecognizer* pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(onPan:)];
    [g_label addGestureRecognizer:pan];
    UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onTap:)];
    [g_label addGestureRecognizer:tap];
    dlog(@"window built, constraints attached");
}

- (void)onPan:(UIPanGestureRecognizer*)g {
    if(!g_window || !g_topC || !g_trailC) return;
    @try {
        NSInteger st = [g state];
        if(st == UIGestureRecognizerStateBegan || st == UIGestureRecognizerStateChanged){
            CGPoint tr = [g translationInView:g_window];
            CGRect b = g_window.bounds;
            CGFloat lw = g_label.bounds.size.width, lh = g_label.bounds.size.height;
            g_offX -= tr.x;   // 往右拖 → 距右边缘减小
            g_offY += tr.y;   // 往下拖 → 距顶边缘增大
            if(g_offX < 8) g_offX = 8;
            if(g_offX > b.size.width - lw - 8)  g_offX = b.size.width - lw - 8;
            if(g_offY < 8) g_offY = 8;
            if(g_offY > b.size.height - lh - 8) g_offY = b.size.height - lh - 8;
            g_trailC.constant = -g_offX;
            g_topC.constant   =  g_offY;
            [g setTranslation:CGPointZero inView:g_window];
        }else if(st == UIGestureRecognizerStateEnded){
            saveState();
            dlog(@"offset saved: %.0f,%.0f", (double)g_offX, (double)g_offY);
        }
    } @catch (NSException* e) {
        dlog(@"EXC in pan: %@", e);
    }
}

- (void)onTap:(UITapGestureRecognizer*)g {
    if([g state] != UIGestureRecognizerStateEnded) return;
    @try {
        g_colorIdx = (g_colorIdx + 1) % 6;
        g_lastColorIdx = -1;
        saveState();
        dlog(@"color -> %d (%s)", g_colorIdx, kColorNames[g_colorIdx]);
    } @catch (NSException* e) {
        dlog(@"EXC in tap: %@", e);
    }
}

- (void)tick:(NSTimer*)t {
    @try {
        static int tickCount = 0;
        tickCount++;
        if(!g_enabled){
            if(g_window && !g_window.hidden) g_window.hidden = YES;
            return;
        }
        [self buildIfNeeded];
        if(g_window.hidden) g_window.hidden = NO;

        // 兜底：窗口尺寸与屏幕不一致时立即对齐（消除转屏残留黑边）
        CGRect sbNow = [[UIScreen mainScreen] bounds];
        if(!CGSizeEqualToSize(g_window.frame.size, sbNow.size))
            g_window.frame = (CGRect){CGPointZero, sbNow.size};

        // 每 5 tick 热更新配置
        if((tickCount % 5) == 0) loadConfig();

        unsigned int now = CARenderServerGetDirtyFrameCount(0);
        unsigned int diff = now - g_lastFrames;
        g_lastFrames = now;
        CGFloat maxFPS = [[UIScreen mainScreen] maximumFramesPerSecond];
        if(maxFPS <= 0) maxFPS = 60;
        CGFloat fps = diff / 1.0;
        if(fps > maxFPS || diff > (unsigned int)(maxFPS * 4)) fps = maxFPS;

        g_label.text = [NSString stringWithFormat:@"%.0f FPS", fps];
        [g_label sizeToFit];

        // 颜色：AUTO=阈值变色，1-5=固定色盘
        if(g_colorIdx > 0){
            if(g_colorIdx != g_lastColorIdx){
                g_lastColorIdx = g_colorIdx;
                const unsigned char* c = kPalette[g_colorIdx-1];
                g_label.textColor = [UIColor colorWithRed:c[0]/255.0 green:c[1]/255.0
                                                     blue:c[2]/255.0 alpha:c[3]/255.0];
            }
        }else{
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
        dlog(@"constructor hit (v4.0)");
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
