//  QQNoRecall — QQ 消息防撤回 / 闪图防撤回
//  Target: QQ (com.tencent.mqq) 9.3.35 (NT kernel)
//  Framework: Theos + Logos (Objective-C, ARC)
//
//  Hook 设计依据（来自 QQ9.3.35 头文件 class-dump）：
//  * 消息撤回：NT kernel 通过监听者回调 -[KTIKernelMsgListener onMsgRecall:peerUid:seq:]
//    通知上层把消息替换成“撤回”灰条。拦截该回调即可让消息保持原样。
//    旧链路（关联账号/老协议）由 QQMessageRecallModule / QQMessageRecallPackageHandler /
//    QQMessageRecallNetEngine 处理，同样拦截作为纵深防御。
//  * 闪图防撤回：闪图(阅后即焚)在被查看后由 NTAIOChat.NTAIOChatFlashPicContentView
//    收到销毁通知( -notificationActionWithSender: )后替换为“已焚毁”占位。
//    拦截该通知即可让闪图保持可见；同时闪图被发送者撤回也走 onMsgRecall，一并覆盖。
//
//  偏好读取：直接用 CFPreferences 读取 com.qaz9190.qqnorecall 域，
//  无需依赖 Cephei，兼容 rootless / roothide。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <substrate.h>

// ---- 偏好开关（默认全部开启，提前声明以便下方闪图 hook 存根引用）----
static BOOL gEnableMessageRecall = YES; // 消息防撤回
static BOOL gEnableFlashPic = YES;      // 闪图防撤回
static BOOL gShowToast = NO;            // 拦截时顶部提示

// 闪图“销毁”通知的原生实现存根（用 MSHookMessageEx 运行时替换，
// 以绕过 Logos 对 Swift 桥接类 hook 的告警/不可靠行为）
static void (*origFlashPicNotificationAction)(id, SEL, id) = NULL;
static void hookedFlashPicNotificationAction(id self, SEL _cmd, id sender) {
    if (gEnableFlashPic) return; // 拦截销毁通知，保留原图
    if (origFlashPicNotificationAction) origFlashPicNotificationAction(self, _cmd, sender);
}

#define PREF_DOMAIN CFSTR("com.qaz9190.qqnorecall")
#define PREFS_CHANGED_NOTIFICATION CFSTR("com.qaz9190.qqnorecall/prefsChanged")

static void loadPrefs() {
    CFPropertyListRef v;
    v = CFPreferencesCopyAppValue(CFSTR("kEnableMessageRecall"), PREF_DOMAIN);
    if (v) { gEnableMessageRecall = [(__bridge id)v boolValue]; CFRelease(v); }
    v = CFPreferencesCopyAppValue(CFSTR("kEnableFlashPic"), PREF_DOMAIN);
    if (v) { gEnableFlashPic = [(__bridge id)v boolValue]; CFRelease(v); }
    v = CFPreferencesCopyAppValue(CFSTR("kShowToast"), PREF_DOMAIN);
    if (v) { gShowToast = [(__bridge id)v boolValue]; CFRelease(v); }
    CFPreferencesAppSynchronize(PREF_DOMAIN);
}

static void showBlockToast(NSString *text) {
    if (!gShowToast || !text.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]] &&
                    ((UIWindowScene *)scene).activationState == UISceneActivationStateForegroundActive) {
                    win = ((UIWindowScene *)scene).windows.firstObject;
                    break;
                }
            }
        } else {
            win = UIApplication.sharedApplication.keyWindow;
        }
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
//  该视图为 Swift 桥接类（NTAIOChat.NTAIOChatFlashPicContentView），
//  Logos %hook 会触发告警且“无法捕获全部调用”，故改用 MSHookMessageEx。
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
