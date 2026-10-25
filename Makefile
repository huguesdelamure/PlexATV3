# PlexATV3 - native Plex client for the Apple TV 3 (ATV Software 7.x / iOS 8.4, armv7)
#
# Toolchain (see README):
#   - clang from a current Xcode (compiles armv7 fine),
#   - iPhoneOS 8.4 SDK and ld64-242 from Xcode 6.4: the current linker emits
#     armv7 binaries that crash on the iOS 8 dyld. ld64-242 runs under Rosetta.
#
#   make              debug build (SSH dev channel enabled)
#   make RELEASE=1    release build
#   make deploy       copy to the Apple TV ($ATV_HOST, see scripts/atv-env.sh)

TOOLCHAIN ?= $(abspath ../toolchain)
SDK      ?= $(TOOLCHAIN)/iPhoneOS8.4.sdk
LD64     ?= $(TOOLCHAIN)/bin/ld64-242
CC       := xcrun clang
TARGET   := -target armv7-apple-ios8.0 -isysroot $(SDK)

NAME     := PlexATV3
BUNDLE   := build/$(NAME).frappliance
SRCS     := $(wildcard Kit/*/*.m App/*/*.m)
HDRS     := $(wildcard Kit/*/*.h App/*/*.h)
OBJS     := $(patsubst %.m,build/obj/%.o,$(SRCS))
INCLUDES := $(addprefix -I,$(sort $(dir $(HDRS))))

CFLAGS   := $(TARGET) -fobjc-arc -Os -g -Wall -Wno-unused-function -include Kit/Core/PXKit.h $(INCLUDES)
ifndef RELEASE
CFLAGS   += -DDEBUG=1
endif
# ARC on iOS 8 needs no libarclite: compile with -fobjc-arc, link without it.
LDFLAGS  := $(TARGET) -mlinker-version=242 -fuse-ld=$(LD64) -bundle -Wl,-w \
            -framework Foundation -framework UIKit -framework QuartzCore \
            -framework CoreGraphics -framework AVFoundation -framework CoreMedia \
            -framework Security -framework ImageIO -framework CoreText

all: $(BUNDLE)/$(NAME)

build/obj/%.o: %.m $(HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUNDLE)/$(NAME): $(OBJS) App/Resources/Info.plist
	@mkdir -p $(BUNDLE)/Fonts
	$(CC) $(LDFLAGS) $(OBJS) -o $@
	ldid -S $@
	cp -R App/Resources/* $(BUNDLE)/
	cp Kit/Resources/Fonts/* $(BUNDLE)/Fonts/

deploy: all
	./scripts/deploy.sh $(NAME)

clean:
	rm -rf build

.PHONY: all deploy clean
