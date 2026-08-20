//  QQNoRecall — QQ 消息防撤回 / 闪图防撤回
//  Target: QQ (com.tencent.mqq) 9.3.35（NT kernel, KMM 桥接）
//  Framework: Theos + Logos (Objective-C, ARC)
//
//  Hook 依据（QQ 9.3.35 版本头文件 class-dump）：
//
//  ★ 撤回真正生效的位置（QQ 9.3.35 实测结论）：
//    撤回由 Kotlin 内核层处理，处理后通过 KTIKernelMsgListener 回调通知 OC：
//      1) -[KTIKernelMsgListener onMsgRecall:peerUid:seq:]  通知“有撤回事件」
//      2) -[KTIKernelMsgListener onMsgDelete:msgIds:]      通知 OC「删除原消息」← 关键拦截点
//      3) -[KTIKernelMsgListener onMsgInfoListAdd:]        通知 OC「插入撤回灰条」
//    → 防撤回核心：onMsgRecall 设标志位，onMsgDelete:msgIds: 检测到标志位就跳过 %orig
//    （不删除原消息）。onMsgInfoListAdd 不拦截（让灰条照常插入），最终效果：
//    原内容保留在聊天界面 + 下方带一条「撤回了以上消息」灰条（你截图里那种效果）。
//    （v2.2/v2.3/v2.4 都失败——它们都只盯着 OC 侧的 QQMessageRecallModule/convertRecallItemToMsg，
//     但 9.3.35 的撤回是 Kotlin 层驱动，根本不调那些 OC 方法。）
//
//  ★ 旧协议 / 关联账号链路（纵深防御）：QQMessageRecallModule /
//    QQMessageRecallPackageHandler / QQMessageRecallNetEngine。
//
//  ★ 撤回事件入口（首参 int 匹配头文件）：
//    -[KTIKernelMsgListener onMsgRecall:(int)peerUid:(id)seq:(unsigned long long)]
//    ⚠️ 头文件签名首参为 int（KMM 桥接：Kotlin Int → OC int，32bit）。
//
//  ★ 闪图销毁：NTAIOChat.NTAIOChatFlashPicContentView -notificationActionWithSender:
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
//     UIWindowScene(13.0) 均可用，无需 @available 守卫；
//  4. Logos %hook Swift 桥接类（类名含点）会告警(-Werror)且“无法捕获全部调用”，
//     故闪图 hook 用 MSHookMessageEx 而非 %hook。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <substrate.h>

#define PREF_DOMAIN CFSTR("com.qaz9190.qqnorecall")
#define PREFS_CHANGED_NOTIFICATION CFSTR("com.qaz9190.qqnorecall/prefsChanged")

// ---- 偏好开关（默认全部开启）----
static BOOL gEnableMessageRecall = YES; // 消息防撤回
static BOOL gEnableFlashPic = YES;      // 闪图防撤回

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

static void showBlockToast(NSString *text) { /* 已移除顶部提示功能 */ }

// =====================================================================
//  QQ 内设置面板（自建 UIViewController + 标准 UITableView，三开关）
// =====================================================================
@interface QQNoRecallPrefsVC : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tv;
@end

static NSString *const kQQNoRecallKeys[] = {@"kEnableMessageRecall", @"kEnableFlashPic"};
static NSString *const kQQNoRecallTitles[] = {@"消息防撤回", @"闪图防撤回"};

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
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return 2; }
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
//  消息防撤回 —— 核心：拦截 KTIKernelMsgListener 的多个回调保留原消息
//  QQ 9.3.35 撤回由 Kotlin 内核驱动，OC 侧 QQMessageRecallModule 根本不调。
//  Kotlin 处理完后通过以下回调通知 OC（撤回窗口内全部跳过）：
//    1) onMsgRecall:peerUid:seq:    —— 撤回事件（设标志位）
//    2) onMsgDelete:msgIds:          —— 删除原消息（跳过）
//    3) onMsgInfoListUpdate:         —— 列表整体刷新（含"删原+加灰"）（跳过，
//                                     关键：如果原消息是通过此回调从 OC AIO 视图
//                                     移除的，跳过它就能让原消息保留在视图里）
//    4) onMsgInfoListAdd:            —— 插入撤回灰条（不拦截，让灰条照常插入）
//  → 最终效果：原内容留在聊天里 + 下方带一条「撤回了以上消息」灰条。
//  → 标志位用 dispatch_after 延迟 0.8s 清零，确保多个回调都在窗口内被拦截。
// =====================================================================
static BOOL gIsInRecall = NO;

%hook KTIKernelMsgListener
- (void)onMsgRecall:(int)arg1 peerUid:(id)arg2 seq:(unsigned long long)arg3 {
    if (gEnableMessageRecall) {
        gIsInRecall = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ gIsInRecall = NO; });
    }
    %orig;
}
- (void)onMsgDelete:(id)arg1 msgIds:(id)arg2 {
    if (gEnableMessageRecall && gIsInRecall) {
        return; // 撤回期间的删除跳过，原消息保留
    }
    %orig;
}
- (void)onMsgInfoListUpdate:(id)arg1 {
    if (gEnableMessageRecall && gIsInRecall) {
        return; // 撤回期间的列表更新跳过，原消息保留在 OC AIO 视图里
    }
    %orig;
}
- (void)onMsgInfoListAdd:(id)arg1 {
    %orig; // 让灰条照常插入
}
%end

// 备份防御：OC 侧召回模块（如有走 OC 路径的撤回）
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
