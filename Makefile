ARCHS = arm64 arm64e
TARGET = iphone:clang:15.0:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QQNoRecall
QQNoRecall_FILES = Tweak.xm
QQNoRecall_CFLAGS = -fobjc-arc
QQNoRecall_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

# 安装后杀掉 QQ 让 tweak 重新注入
after-install::
	install.exec "killall -9 QQ" 2>/dev/null || true
