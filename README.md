# QQNoRecall

QQ 消息防撤回 / 闪图（阅后即焚）防撤回的 iOS 越狱插件（Theos + Logos）。

> 仅用于学习与研究，请遵守你所在地区法律法规，仅在本人设备上使用。

## 功能

- **消息防撤回**：拦截 QQ NT kernel 的撤回回调，被撤回的文字 / 图片 / 文件等消息保持原样显示，不出现"撤回"灰条。
- **闪图防撤回**：拦截闪图被查看后的"销毁"通知，使闪图保留可见；发送者主动撤回闪图同样被拦截。
- **设置页开关**：iOS「设置」→「QQ 防撤回」，三个开关：消息防撤回 / 闪图防撤回 / 拦截时顶部提示，改动即时生效。
- 偏好通过 `CFPreferences` 直读，无 Cephei 依赖，兼容 rootless / roothide。

## Hook 依据（QQ 9.3.35 版本头文件）

| 功能 | Hook 类 / 方法 | 方式 |
| --- | --- | --- |
| 消息撤回（主链路） | `KTIKernelMsgListener -onMsgRecall:peerUid:seq:` | Logos `%hook` |
| 消息撤回（旧协议/关联账号纵深防御） | `QQMessageRecallModule -handleSideAccountRecallNotify:bufferLen:subcmd:bindUin:tracelessFlag:`<br>`QQMessageRecallPackageHandler +parseC2CRecallNotify:bufferLen:subcmd:model:`<br>`QQMessageRecallNetEngine -parseC2CRecallNotify:bufferLen:subcmd:model:` | Logos `%hook` |
| 闪图销毁 | `NTAIOChat.NTAIOChatFlashPicContentView -notificationActionWithSender:` | `MSHookMessageEx`（Swift 桥接类，见下） |

**为什么闪图 hook 不用 `%hook`**：该类是 Swift 桥接类（类名含点），Logos 会产生告警且开启 `-Werror` 导致编译失败，同时官方说明"无法捕获全部调用"，因此改用 `MSHookMessageEx` 运行时替换。

## 编译

### CI（推荐）

推送到 `main` 分支或手动触发 Actions 即自动构建 rootless `.deb`（产物在 Actions → Artifacts → `qqnorecall-deb`）。构建失败时 `build-log` 产物内含完整日志。

### 本地（macOS / Linux / WSL + Theos）

```bash
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

产物在 `packages/*.deb`。

## 安装

Sileo / Zebra / Filza 安装 `.deb`，重启 QQ。设置入口：iOS 设置 → QQ 防撤回。

## 已验证的 CI 环境结论（避坑）

1. `Randomblock1/theos-action@v1` **只安装** Theos 与 iOS SDK（当前 `iPhoneOS16.5.sdk`）并导出 `$THEOS`，**不会执行 make**，必须写独立的 `make package` 步骤；其有效输入仅有 `theos-dir / theos-src / theos-sdks / theos-sdks-branch / orion`。
2. Theos 开启 `-Werror`：deprecated API（如 `UIApplication.keyWindow`，iOS 13 废弃）会直接编译失败，需用 `UIWindowScene.windows` 遍历替代或用 `#pragma clang diagnostic ignored "-Wdeprecated-declarations"` 包住。
3. Logos 对 Swift 桥接类（类名含点）的 `%hook` 告警同样被当错误处理。
4. Makefile 中 SDK 版本留空（`TARGET = iphone:clang::15.0`）自动匹配已安装 SDK；写死 `15.0` 会因 SDK 不存在而失败。
5. 部署目标需 ≥ 15.0（rootless 要求），同时满足 `safeAreaInsets`(iOS 11) / `UIWindowScene`(iOS 13) 的可用性检查。

## 已知边界

- 闪图防撤回依赖拦截 `-notificationActionWithSender:`；QQ 小版本若调整销毁触发点，可在 `Tweak.xm` 补充 Hook。头文件中的备选类：`AIOPhotoBrowser.NTAIOFlashPicturePhotoBrowserViewController`（`finishFlashImgPreview` / `hideFlashImgPreview`）、`AIOPhotoBrowser.NTAIOFlashPicturePhotoBrowserSecretView`、`QQFlashPicturePlayer`。
- 防撤回为"本地拦截"，服务器侧仍记录撤回动作，不影响对端。
