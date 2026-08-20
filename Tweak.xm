//  QQNoRecall — QQ 消息防撤回 / 闪图防撤回
//  Target: QQ (com.tencent.mqq) 9.3.35（NT kernel, KMM 桥接）
//  Framework: Theos + Logos (Objective-C, ARC)
//
//  Hook 依据（QQ 9.3.35 版本头文件 class-dump）：
//  * 消息撤回主链路：-[KTIKernelMsgListener onMsgRecall:peerUid:seq:]
//    ⚠️ 该类由 Kotlin Multiplatform Mobile 桥接生成，Kotlin Int 编译为 OC 的
//    NSInteger(64bit)，故第一个参数必须写成 long long，否则类型编码不匹配、
//    Logos hook 无法挂上（这正是早期“防撤回失效”的根因）。拦截后 Kotlin 侧
//    撤回逻辑被跳过，消息保持原样、不生成“撤回”灰条。
//  * 旧协议 / 关联账号链路（纵深防御）：QQMessageRecallModule /
//    QQMessageRecallPackageHandler / QQMessageRecallNetEngine。
//  * 闪图销毁：NTAIOChat.NTAIOChatFlashPicContentView -notificationActionWithSender:
//    Swift 桥接类（类名含点），用 MSHookMessageEx 运行时替换。
//
//  QQ 内设置页：hook QQNewSettingsViewController（QQ「设置」主 VC），在导航栏
//  右上角注入「防撤回」按钮，点击弹出本 tweak 自带设置面板（三开关）。
//  偏好存于 CFPreferences 域 com.qaz9190.qqnorecall，与系统设置(PreferenceLoader)
//  共用同一套 key，改动经 Darwin 通知即时生效。
//
//  CI 环境结论（GitHub Actions + Randomblock1/theos-action@v1 实测）：
//  1. theos-action 只装 Theos + iPhoneOS16.5.sdk 并导出 $THEOS，不会执行 make；
//  2. Theos 开启 -Werror：deprecated API（如 UIApplication.keyWindow）直接报错，
//     本文件改用 UIWindowScene.windows 遍历，完全避开废弃 API；
//  3. Makefile 部署目标为 iOS 15.0（rootless/roothide 越狱要求），safeAreaInsets(11.0)/
//     UIWindowScene(13.0) 均可用，无需 @available 守卫。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <substrate.h>

#define PREF_DOMAIN CFSTR("com.qaz9190.qqnorecall")
#define PREFS_CHANGED_NOTIFICATION CFSTR("com.qaz9190.qqnorecall/prefsChanged")

// ---- 偏好开关（默认全部开启；kShowToast 默认开便于验证 hook 是否命中）----
static BOOL gEnableMessageRecall = YES; // 消息防撤回
static BOOL gEnableFlashPic = YES;      // 闪图防撤回
static BOOL gShowToast = YES;           // 拦截时顶部提示

// ---- 闪图销毁通知 hook 存根（由文件底部 constructor 用 MSHookMessageEx 安装）----
static void (*origFlashPicNotificationAction)(id, SEL, id) = NULL;
static void hookedFlashPicNotificationAction(id self, SEL _cmd, id sender) {
    if (gEnableFlashPic) return; // 拦截销毁通知，保留原图
    if (origFlashPicNotificationAction) origFlashPicNotificationAction(self, _cmd, sender);
}

// ---- 偏好读取：CFPreferences 直读，不依赖 Cephei，兼容 rootless / roothide ----
static void loadPrefs(void) {
    CFPropertyListRef v;
    v = CFPreferencesCopyAppValue(CFSTR("kEnableMessageRecall"), PREF_DOMAIN);
    if (v) { gEnableMessageRecall = [(__bridge id)v boolValue]; CFRelease(v); }
    v = CFPreferencesCopyAppValue(CFSTR("kEnableFlashPic"), PREF_DOMAIN);
    if (v) { gEnableFlashPic = [(__bridge id)v boolValue]; CFRelease(v); }
    v = CFPreferencesCopyAppValue(CFSTR("kShowToast"), PREF_DOMAIN);
    if (v) { gShowToast = [(__bridge id)v boolValue]; CFRelease(v); }
    CFPreferencesAppSynchronize(PREF_DOMAIN);
}

// 用 UIWindowScene.windows 取可见窗口（不用废弃的 UIApplication.keyWindow）
static UIWindow *qqnorecall_visibleWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (!w.isHidden) return w;
        }
    }
    return nil;
}

static void showBlockToast(NSString *text) {
    if (!gShowToast || text.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = qqnorecall_visibleWindow();
        if (!win) return;
        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = text;
        lbl.textColor = [UIColor whiteColor];
        lbl.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.82];
        lbl.font = [UIFont systemFontOfSize:13];
        lbl.textAlignment = NSTextAlignmentCenter;
        lbl.layer.cornerRadius = 8;
        lbl.layer.masksToBounds = YES;
        lbl.alpha = 0.0;
        CGSize sz = [lbl sizeThatFits:CGSizeMake(300, 30)];
        CGFloat w = MIN(sz.width + 28, 300);
        CGFloat top = win.safeAreaInsets.top > 0 ? win.safeAreaInsets.top : 20;
        lbl.frame = CGRectMake((win.bounds.size.width - w) / 2.0, top + 56, w, 32);
        [win addSubview:lbl];
        [UIView animateWithDuration:0.25 animations:^{ lbl.alpha = 1.0; }];
        [UIView animateWithDuration:0.35 delay:1.3 options:0 animations:^{ lbl.alpha = 0.0; }
                         completion:^(BOOL f){ [lbl removeFromSuperview]; }];
    });
}

// =====================================================================
//  QQ 内设置面板（自建 UIViewController + 标准 UITableView，三开关）
// =====================================================================
@interface QQNoRecallPrefsVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tv;
@end

static NSString *const kQQNoRecallKeys[] = {@"kEnableMessageRecall", @"kEnableFlashPic", @"kShowToast"};
static NSString *const kQQNoRecallTitles[] = {@"消息防撤回", @"闪图防撤回", @"拦截时顶部提示"};

@implementation QQNoRecallPrefsVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"QQ 防撤回设置";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.tv.delegate = self;
    self.tv.dataSource = self;
    self.tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tv];
    if (self.navigationController) {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                             style:UIBarButtonItemStyleDone
                                            target:self
                                            action:@selector(qqnorecall_done)];
    }
}
- (void)qqnorecall_done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (BOOL)qqnorecall_readBool:(NSString *)key {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, PREF_DOMAIN);
    BOOL b = v ? [(__bridge id)v boolValue] : YES;
    if (v) CFRelease(v);
    return b;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return 3; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return @"功能开关（改动即时生效，无需重启 QQ）";
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"qqnr"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"qqnr"];
    c.textLabel.text = kQQNoRecallTitles[ip.row];
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = [self qqnorecall_readBool:kQQNoRecallKeys[ip.row]];
    sw.tag = ip.row;
    [sw addTarget:self action:@selector(qqnorecall_toggle:) forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sw;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}
- (void)qqnorecall_toggle:(UISwitch *)sw {
    NSString *key = kQQNoRecallKeys[sw.tag];
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@(sw.on), PREF_DOMAIN);
    CFPreferencesAppSynchronize(PREF_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          PREFS_CHANGED_NOTIFICATION, NULL, NULL, YES);
}
@end

// 打开设置面板（动态加到 QQNewSettingsViewController 的 IMP）
static void qqnorecall_openSettingsImp(id self, SEL _cmd) {
    QQNoRecallPrefsVC *vc = [[QQNoRecallPrefsVC alloc] init];
    UINavigationController *nc = [[UINavigationController alloc] initWithRootViewController:vc];
    nc.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nc animated:YES completion:nil];
}

%ctor {
    loadPrefs();
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        (CFNotificationCallback)loadPrefs,
        PREFS_CHANGED_NOTIFICATION,
        NULL,
        CFNotificationSuspensionBehaviorCoalesce);

    // 给 QQ「设置」主 VC 动态注入打开面板的方法
    Class settingsCls = objc_getClass("QQNewSettingsViewController");
    if (settingsCls && !class_respondsToSelector(settingsCls, @selector(qqnorecall_openSettings))) {
        class_addMethod(settingsCls, @selector(qqnorecall_openSettings),
                        (IMP)qqnorecall_openSettingsImp, "v@:");
    }
}

// =====================================================================
//  消息防撤回（NT kernel 主链路，KMM 桥接：第一个参数为 long long）
// =====================================================================
%hook KTIKernelMsgListener
- (void)onMsgRecall:(long long)arg1 peerUid:(id)arg2 seq:(unsigned long long)arg3 {
    if (gEnableMessageRecall) {
        showBlockToast(@"已拦截一次消息撤回");
        return; // 不调用 %orig -> Kotlin 侧撤回逻辑被跳过，消息保持原样
    }
    %orig;
}
%end

// 旧协议 / 关联账号链路（纵深防御）
%hook QQMessageRecallModule
- (id)handleSideAccountRecallNotify:(id)arg1 bufferLen:(int)arg2 subcmd:(int)arg3
                            bindUin:(unsigned long long)arg4 tracelessFlag:(id)arg5 {
    if (gEnableMessageRecall) return nil;
    return %orig;
}
%end

%hook QQMessageRecallPackageHandler
+ (BOOL)parseC2CRecallNotify:(id)arg1 bufferLen:(int)arg2 subcmd:(int)arg3 model:(id)arg4 {
    if (gEnableMessageRecall) return NO;
    return %orig;
}
%end

%hook QQMessageRecallNetEngine
- (BOOL)parseC2CRecallNotify:(id)arg1 bufferLen:(int)arg2 subcmd:(int)arg3 model:(id)arg4 {
    if (gEnableMessageRecall) return NO;
    return %orig;
}
%end

// =====================================================================
//  闪图防撤回：拦截闪图“已焚毁”销毁通知
//  NTAIOChat.NTAIOChatFlashPicContentView 为 Swift 桥接类（类名含点），
//  Logos %hook 会触发告警(-Werror)且“无法捕获全部调用”，故用 MSHookMessageEx。
//  发送者主动撤回闪图走 onMsgRecall，已被上面的主链路覆盖。
// =====================================================================
__attribute__((constructor)) static void qqnorecall_init_flashpic(void) {
    Class cls = objc_getClass("NTAIOChat.NTAIOChatFlashPicContentView");
    if (cls) {
        MSHookMessageEx(cls,
                        @selector(notificationActionWithSender:),
                        (IMP)hookedFlashPicNotificationAction,
                        (IMP *)&origFlashPicNotificationAction);
    }
}

// =====================================================================
//  QQ 内设置入口：hook「设置」主 VC，导航栏右上角加「防撤回」按钮
// =====================================================================
@interface QQNewSettingsViewController : UIViewController
- (void)qqnorecall_openSettings;
@end

%hook QQNewSettingsViewController
- (void)viewDidLoad {
    %orig;
    if (objc_getAssociatedObject(self, "qqnorecall_added")) return;
    objc_setAssociatedObject(self, "qqnorecall_added", @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIBarButtonItem *mine = [[UIBarButtonItem alloc] initWithTitle:@"防撤回"
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(qqnorecall_openSettings)];
    UIBarButtonItem *existing = self.navigationItem.rightBarButtonItem;
    if (existing) {
        self.navigationItem.rightBarButtonItems = @[existing, mine];
    } else {
        self.navigationItem.rightBarButtonItem = mine;
    }
}
%end
