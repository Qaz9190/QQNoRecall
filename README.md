# QQNoRecall — QQ 消息防撤回 / 闪图防撤回

针对 **QQ（com.tencent.mqq）9.3.35（NT 架构 / KMM 桥接）** 的 iOS 越狱插件。

基于 QQ 9.3.35 的头文件 class-dump 定位撤回链路与设置页结构实现，源码见 [`Tweak.xm`](Tweak.xm)。

## 功能

- **消息防撤回**：QQ 9.3.35 的撤回是“用一条独立的撤回灰条消息替换原消息”。插件在 `QQMessageRecallModule -convertRecallItemToMsg:` 转换出口直接返回原消息，使**原消息内容继续留在聊天界面**、不生成灰条。
- **闪图防撤回**：拦截闪图“已焚毁”销毁通知，保留原图可见。
- **QQ 设置页内开关**：在 QQ 自带「设置」页（导航栏右上角「防撤回」按钮）打开设置面板，含三个开关，改动即时生效，无需重启 QQ。
- **系统设置备选**：同时提供 PreferenceLoader 面板（iOS「设置」→「QQ 防撤回」），与 QQ 内开关共用同一套偏好，二选一即可。

## 在 QQ 里打开设置

```
QQ → 左上角头像 → 设置
```
进入「设置」页后，右上角出现 **「防撤回」** 按钮，点击打开设置面板：

| 开关 | 作用 |
|---|---|
| 消息防撤回 | 拦截他人/自己发出的消息撤回 |
| 闪图防撤回 | 拦截闪图被查看后的自动销毁 |
| 拦截时顶部提示 | 每次成功拦截时在屏幕顶部弹一条提示（默认开，便于确认插件在生效；确认后可关闭）|

> 偏好存储域：`com.qaz9190.qqnorecall`，key：`kEnableMessageRecall` / `kEnableFlashPic` / `kShowToast`。

## 验证防撤回是否真的生效（重要）

若 hook 命中，对方撤回消息时**聊天界面里该消息内容保持可见（不再变灰条）**，且屏幕顶部会弹出
**「已拦截一次消息撤回」** 提示（需开启“拦截时顶部提示”）。

- **原消息内容仍在、且能看到顶部提示** → hook 已命中，功能正常。
- **看不到提示、且消息仍变灰条/消失** → 说明 hook 未命中（多为 deb 格式与设备越狱类型不匹配，或该撤回走了未覆盖的路径）。

> 注：QQ 9.3.35 的 `OCMsgRecord.recallTime` 字段并不被显示层读取，旧版“拦截 recallTime”的写法对本版无效；本版改为在撤回灰条转换出口返回原消息。

## 安装（请按你的越狱类型选 deb）

仓库 Actions 自动产出两种 `.deb`：

| 越狱类型 | 产物 | 说明 |
|---|---|---|
| **rootless**（Dopamine / palera1n，iOS 15+） | `qqnorecall-deb-rootless` | 文件落 `/var/jb`，依赖 `com.opa334.substrate` |
| **roothide**（A12+ / arm64e） | `qqnorecall-deb-roothide` | 相对 jbroot，依赖 `com.roothide.substrate` |

下载对应 artifact 里的 `.deb`，用已装的包管理器（Sileo / Zebra / Filza）安装，**杀掉 QQ 重进**即可。
装错格式（如在 roothide 上装 rootless）会导致插件完全不加载——这是“设置里没插件 / 防撤回不生效”最常见的原因。

## 本地构建

```bash
# rootless
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
# roothide（需 roothide/theos fork）
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

## 已知边界

- 闪图防撤回仅拦截 `NTAIOChat.NTAIOChatFlashPicContentView -notificationActionWithSender:` 一个销毁触发点；
  若某 QQ 小版本改了销毁逻辑，可在 `Tweak.xm` 补 `QQFlashPicturePlayer` /
  `AIOPhotoBrowser.NTAIOFlashPicturePhotoBrowserViewController -finishFlashImgPreview` 等备选类。
- 仅影响本机显示（本地拦截），对方仍会收到正常撤回。

## 防撤回失效自查

如果装对 deb 后仍无法拦截：

1. **确认 deb 格式与越狱匹配**：Dopamine/palera1n（iOS15+）用 rootless；roothide（A12+ arm64e）用 roothide。装错格式插件不加载（表现为设置里无「防撤回」且无拦截提示）。
2. **看顶部提示**：对方撤回后屏幕顶部若弹出「已拦截一次消息撤回」，说明 hook 已命中、功能生效；若没提示且撤回照常，多半是格式装错或 deb 未生效（重装后杀 QQ 重进）。
3. **核心机制**：防撤回通过拦截 `OCMsgRecord.recallTime` 的写入实现——只要该字段保持 0，原消息永远正常显示、不会变灰条。这比只拦截 `onMsgRecall` 事件更彻底（覆盖内核经 `onMsgInfoListUpdate` 刷新列表的路径）。
