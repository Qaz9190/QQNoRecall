//  QQNoRecall — QQ 消息防撤回 / 闪图防撤回
//  Target: QQ (com.tencent.mqq) 9.3.35（NT kernel）
//  Framework: Theos + Logos (Objective-C, ARC)
//
//  Hook 依据（QQ 9.3.35 版本头文件 class-dump，Hook 点见 README 对照表）：
//  * 消息撤回主链路：-[KTIKernelMsgListener onMsgRecall:peerUid:seq:]
//    NT kernel 撤回回调，拦截后消息保持原样、不生成“撤回”灰条。
//  * 旧协议 / 关联账号链路：QQMessageRecallModule / QQMessageRecallPackageHandler /
//    QQMessageRecallNetEngine（纵深防御，一并拦截）。
//  * 闪图销毁：NTAIOChat.NTAIOChatFlashPicContentView -notificationActionWithSender:
//    闪图被查看后收到销毁通知并替换为“已焚毁”占位；拦截以保留原图。
//    该类是 Swift 桥接类（类名含点），Logos %hook 会触发告警且无法捕获全部调用，
//    故用 MSHookMessageEx 在运行时替换（见文件底部 constructor）。
//
//  CI 环境结论（GitHub Actions + Randomblock1/theos-action@v1 实测）：
//  1. theos-action 只安装 Theos + iPhoneOS16.5.sdk 并导出 $THEOS，不会执行 make；
//  2. Theos 开启 -Werror：deprecated API（如 UIApplication.keyWindow）直接报错，
//     本文件改用 UIWindowScene.windows 遍历，完全避开废弃 API；
//  3. Makefile 部署目标为 iOS 15.0（rootless 越狱要求），safeAreaInsets(11.0)/
//     UIWindowScene(13.0) 均可用，无需 @available 守卫。

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
static BOOL gShowToast = NO;            // 拦截时顶部提示

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

%ctor {
    loadPrefs();
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        (CFNotificationCallback)loadPrefs,
        PREFS_CHANGED_NOTIFICATION,
        NULL,
        CFNotificationSuspensionBehaviorCoalesce);
}

// =====================================================================
//  消息防撤回（NT kernel 主链路）
// =====================================================================
%hook KTIKernelMsgListener
- (void)onMsgRecall:(int)arg1 peerUid:(id)arg2 seq:(unsigned long long)arg3 {
    if (gEnableMessageRecall) {
        showBlockToast(@"已拦截一次消息撤回");
        return; // 不调用 %orig -> 消息保持原样，不生成“撤回”灰条
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
//  NTAIOChat.NTAIOChatFlashPicContentView 为 Swift 桥接类，
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
