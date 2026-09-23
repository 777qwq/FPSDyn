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

// ---------- 调试日志 ----------
static void dlog(NSString* fmt, ...){
    va_list ap; va_start(ap, fmt);
    NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE* f = fopen("/var/mobile/Library/FPSDyn.log", "a");
    if(f){ fprintf(f, "[FPSDyn] %s\n", [s UTF8String]); fclose(f); }
}

// ---------- 覆盖窗（不拦截触摸） ----------
@interface FPSDynWindow : UIWindow @end
@implementation FPSDynWindow
- (UIView*)hitTest:(CGPoint)p withEvent:(UIEvent*)e { return nil; }
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent*)e { return NO; }
@end

// ---------- Manager ----------
@interface FPSDynManager : NSObject
+ (id)sharedInstance;
- (void)tick:(NSTimer*)t;
- (void)applyStyle;
- (void)layout;
- (void)buildIfNeeded;
@end

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
    g_window.userInteractionEnabled = NO;

    g_label = [[UILabel alloc] initWithFrame:CGRectMake(0,0,120,40)];
    g_label.userInteractionEnabled = NO;
    [g_window addSubview:g_label];
    [self applyStyle];
    dlog(@"window built, label added");
}

- (void)applyStyle {
    if(!g_label || !g_window) return;
    g_label.font   = [UIFont systemFontOfSize:g_cfg.fontSize weight:600.0];
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
    wl.cornerRadius = (float)g_cfg.cornerRadius;
    wl.masksToBounds = g_cfg.cornerRadius > 0;
    g_window.backgroundColor = RGBAColor((unsigned char)(g_cfg.bg[0]*255),
                                         (unsigned char)(g_cfg.bg[1]*255),
                                         (unsigned char)(g_cfg.bg[2]*255),
                                         g_cfg.bg[3]);
    [self layout];
}

- (void)layout {
    if(!g_window || !g_label) return;
    CGRect bounds = [[UIScreen mainScreen] bounds];
    CGSize ts = [g_label sizeThatFits:CGSizeMake(bounds.size.width, 300)];
    CGFloat w = ts.width + g_cfg.padH*2, h = ts.height + g_cfg.padV*2;
    CGFloat x = 0, y = 0;
    const char* p = g_cfg.position;
    if(p[0]=='t')      y = g_cfg.offsetY;
    else if(p[0]=='b') y = bounds.size.height - h - g_cfg.offsetY;
    else               y = bounds.size.height/2 - h/2;
    if(p[0]=='t'||p[0]=='b'){
        if(p[4]=='l')      x = g_cfg.offsetX;
        else if(p[4]=='r') x = bounds.size.width - w - g_cfg.offsetX;
        else               x = bounds.size.width/2 - w/2;
    }
    g_window.frame = CGRectMake(x, y, w, h);
    g_label.frame  = CGRectMake(g_cfg.padH, g_cfg.padV, ts.width, ts.height);
}

- (void)tick:(NSTimer*)t {
  @try {
    // 配置热更新（每 tick 重读，量级为字节，开销可忽略）
    static int tickCount = 0;
    if((tickCount++ % 5) == 0) loadConfig(); // 每 5 tick 重读一次配置
    if(!g_cfg.enabled){
        if(g_window && !g_window.hidden) g_window.hidden = YES;
        return;
    }
    [self buildIfNeeded];
    if(g_window.hidden) g_window.hidden = NO;

    unsigned int now = CARenderServerGetDirtyFrameCount(0);
    unsigned int diff = now - g_lastFrames;
    g_lastFrames = now;
    CGFloat maxFPS = [[UIScreen mainScreen] maximumFramesPerSecond];
    if(maxFPS <= 0) maxFPS = 60;
    CGFloat fps = diff / g_cfg.updateInterval;
    if(fps > maxFPS || diff > (unsigned int)(maxFPS * 4 * g_cfg.updateInterval)) fps = maxFPS; // 回绕/首帧保护

    g_label.text = [NSString stringWithFormat:@"%.0f FPS", fps];
    if(tickCount < 4) dlog(@"tick #%d: raw=%u diff=%u fps=%.0f", tickCount, now, diff, (double)fps);
    int ci = g_cfg.thCount - 1;
    for(int i=0;i<g_cfg.thCount;i++){
        if(fps >= g_cfg.thBound[i]){ ci = i; break; }
    }
    if(ci != g_lastColorIdx){
        g_lastColorIdx = ci;
        unsigned char* c = g_cfg.thColor[ci];
        g_label.textColor = RGBAColor(c[0], c[1], c[2], c[3]/255.0);
    }
    [self layout];
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
