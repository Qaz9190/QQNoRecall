ARCHS = arm64 arm64e
# 不锁定具体 SDK 版本，交给 theos-action 安装的 SDK 自动匹配（当前为 iPhoneOS17.x.sdk）
TARGET = iphone:clang

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QQNoRecall
QQNoRecall_FILES = Tweak.xm
QQNoRecall_CFLAGS = -fobjc-arc
QQNoRecall_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

# 安装后杀掉 QQ 让 tweak 重新注入
after-install::
	install.exec "killall -9 QQ" 2>/dev/null || true
