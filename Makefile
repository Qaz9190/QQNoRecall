ARCHS = arm64 arm64e
# SDK 版本留空 = 自动匹配 theos-action 安装的 SDK（当前为 iPhoneOS16.5.sdk，勿写死 15.0，CI 上不存在会直接报错）
# 部署目标 15.0：rootless 越狱要求，且满足 safeAreaInsets(iOS11)/UIWindowScene(iOS13)
TARGET = iphone:clang::15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QQNoRecall
QQNoRecall_FILES = Tweak.xm
QQNoRecall_CFLAGS = -fobjc-arc
QQNoRecall_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

# 安装后杀掉 QQ 让 tweak 重新注入
after-install::
	install.exec "killall -9 QQ" 2>/dev/null || true
