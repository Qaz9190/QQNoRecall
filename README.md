# QQNoRecall

QQ 消息防撤回 / 闪图（阅后即焚）防撤回的 iOS 越狱插件（Theos + Logos）。

> 仅用于学习与研究，请遵守你所在地区法律法规，仅在本人设备上使用。

## 功能

- **消息防撤回**：拦截 QQ NT kernel 的撤回回调，让被撤回的文字 / 图片 / 文件等消息保持原样显示。
- **闪图防撤回**：拦截闪图（阅后即焚）被查看后的“销毁”通知，使闪图保留可见；发送者撤回闪图同样被拦截。
- **设置页开关**：在 iOS「设置」中出现「QQ 防撤回」面板，可分别开关上述两项功能，支持“拦截时顶部提示”。
- 偏好通过 `CFPreferences` 读取，无需 Cephei，兼容 rootless / roothide。

## 依据（QQ 9.3.35 头文件）

| 功能 | Hook 类 / 方法 |
| --- | --- |
| 消息撤回（主链路） | `KTIKernelMsgListener -onMsgRecall:peerUid:seq:` |
| 消息撤回（旧链路） | `QQMessageRecallModule -handleSideAccountRecallNotify:...`、`QQMessageRecallPackageHandler +parseC2CRecallNotify:...`、`QQMessageRecallNetEngine -parseC2CRecallNotify:...` |
| 闪图销毁 | `NTAIOChat.NTAIOChatFlashPicContentView -notificationActionWithSender:` |

## 本地编译

需要 Theos 环境（macOS / Linux / WSL）：

```bash
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

产物在 `packages/*.deb`。

## CI 编译

推送到 `main` 分支后，GitHub Actions 自动用 `Randomblock1/theos-action` 构建 rootless `.deb`，
在 Actions 页面的 Artifacts 中下载。

## 安装

将 `.deb` 用你喜欢的包管理器（Sileo / Zebra / Filza）安装，重启 QQ 即可。
设置入口：iOS 设置 → QQ 防撤回。

## 已知边界

- 闪图防撤回依赖拦截 `-notificationActionWithSender:`；不同 QQ 小版本若改了销毁触发点，
  可能需要在 `Tweak.xm` 中补充对应 Hook（头文件已列出 `QQFlashPicturePlayer`、
  `NTAIOFlashPicturePhotoBrowserViewController`、`NTAIOFlashPictureCountDownCircleView` 等备选类）。
- 防撤回为“本地拦截”，服务器侧仍记录撤回动作，不影响对端。
