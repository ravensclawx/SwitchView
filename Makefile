# SwitchView: capture viewer + Pro Controller/keyboard command panel (app/),
# Pico 2 W firmware (firmware/), shared wire protocol (proto/).

CFLAGS ?= -O2 -Wall -Wextra
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
PKG_CONFIG ?= $(shell if command -v brew >/dev/null 2>&1 && test -x "$$(brew --prefix)/bin/pkg-config"; then printf "%s/bin/pkg-config" "$$(brew --prefix)"; else command -v pkg-config 2>/dev/null || printf pkg-config; fi)
else
PKG_CONFIG ?= pkg-config
endif
# SDL2 compatibility packages load SDL3 dynamically; expose its pkg-config
# library directory to child tests on macOS without changing system settings.
ifeq ($(UNAME_S),Darwin)
SDL3_LIBDIR := $(shell $(PKG_CONFIG) --variable=libdir sdl3 2>/dev/null)
ifneq ($(SDL3_LIBDIR),)
export DYLD_FALLBACK_LIBRARY_PATH := $(SDL3_LIBDIR):$(DYLD_FALLBACK_LIBRARY_PATH):/usr/local/lib:/usr/lib
endif
endif

PKGS = sdl2 SDL2_ttf tesseract lua5.4
ifeq ($(UNAME_S),Darwin)
CAPTURE_SRC = app/capture_macos.m
PLATFORM_LIBS = -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework Foundation
else
CAPTURE_SRC = app/capture.c
PKGS += alsa
endif
PICO_SDK_PATH ?= $(HOME)/Development/pico-sdk
USB_LAYOUT ?= 1        # 0 controller only, 1 controller + keyboard, 2 keyboard only

APP = app/switchview
SRCS = app/main.c app/panel.c app/link.c app/ocr.c app/script.c $(CAPTURE_SRC)
OBJS = $(patsubst %.m,%.o,$(SRCS:.c=.o))

all: $(APP)

$(APP): $(OBJS)
	$(CC) $(CFLAGS) $(OBJS) -o $@ $$($(PKG_CONFIG) --libs $(PKGS)) $(PLATFORM_LIBS) -lpthread -lm

app/%.o: app/%.c app/*.h proto/switchview_proto.h
	$(CC) $(CFLAGS) -Iproto $$($(PKG_CONFIG) --cflags $(PKGS)) -c $< -o $@

app/%.o: app/%.m app/*.h proto/switchview_proto.h
	$(CC) $(CFLAGS) -fobjc-arc -Iproto $$($(PKG_CONFIG) --cflags $(PKGS)) -c $< -o $@

run: $(APP)
	./$(APP)

firmware:
	PICO_SDK_PATH=$(PICO_SDK_PATH) cmake -S firmware -B firmware/build -G Ninja \
	  -DUSB_LAYOUT=$(USB_LAYOUT) -DFETCHCONTENT_FULLY_DISCONNECTED=ON
	PICO_SDK_PATH=$(PICO_SDK_PATH) cmake --build firmware/build
	@echo "UF2: firmware/build/pico_pro_controller.uf2"

# Hold BOOTSEL while plugging the Pico into the PC, then:
flash: firmware
	@vol=$$(ls -d /media/$$USER/RP2350 /run/media/$$USER/RP2350 2>/dev/null | head -1); \
	if [ -z "$$vol" ]; then echo "RP2350 boot volume not mounted (hold BOOTSEL while plugging in)"; exit 1; fi; \
	cp firmware/build/pico_pro_controller.uf2 "$$vol/" && echo "flashed to $$vol"

clean:
	rm -f $(OBJS) $(APP)
	rm -rf firmware/build

.PHONY: all run firmware flash clean

# Build only; running the resulting executable requires a capture device.
capture-smoke: build/capture-smoke

build/capture-smoke: tests/capture_smoke.c $(CAPTURE_SRC) app/capture.h
	mkdir -p build
ifeq ($(UNAME_S),Darwin)
	$(CC) $(CFLAGS) -fobjc-arc -Iapp $$($(PKG_CONFIG) --cflags $(PKGS)) tests/capture_smoke.c $(CAPTURE_SRC) -o $@ $$($(PKG_CONFIG) --libs $(PKGS)) $(PLATFORM_LIBS) -lpthread -lm
else
	$(CC) $(CFLAGS) -Iapp $$($(PKG_CONFIG) --cflags $(PKGS)) tests/capture_smoke.c $(CAPTURE_SRC) -o $@ $$($(PKG_CONFIG) --libs $(PKGS)) -lpthread -lm
endif

.PHONY: capture-smoke

# Regression suite uses synthetic frames and never opens capture/input devices.
build/test-viewer-util: tests/test_viewer_util.c app/viewer_util.h
	mkdir -p build
	$(CC) $(CFLAGS) -Iapp $$($(PKG_CONFIG) --cflags sdl2) $< -o $@

ifeq ($(UNAME_S),Darwin)
build/test-capture-macos: tests/capture_macos_test.m app/capture_macos.m app/capture.h
	mkdir -p build
	$(CC) $(CFLAGS) -fobjc-arc $$($(PKG_CONFIG) --cflags sdl2) $< -o $@ $$($(PKG_CONFIG) --libs sdl2) $(PLATFORM_LIBS) -lpthread -lm
MACOS_TEST = build/test-capture-macos
endif

test: $(APP) build/test-viewer-util build/test-script-lifecycle build/test-ocr-luma build/test-link-motion $(MACOS_TEST)
	./build/test-viewer-util
	./build/test-script-lifecycle
	./build/test-ocr-luma
	./build/test-link-motion
ifeq ($(UNAME_S),Darwin)
	./build/test-capture-macos
endif
	python3 -m unittest discover -s tests -p 'test_*.py' -v

.PHONY: test

build/test-script-lifecycle: tests/test_script_lifecycle.c app/script.c app/script.h app/ocr.h
	mkdir -p build
	$(CC) $(CFLAGS) $$($(PKG_CONFIG) --cflags sdl2 lua5.4) -Iproto $< -o $@ $$($(PKG_CONFIG) --libs sdl2 lua5.4) -lpthread -lm

build/test-ocr-luma: tests/test_ocr_luma.c app/ocr.c app/ocr.h app/capture.h
	mkdir -p build
	$(CC) $(CFLAGS) $$($(PKG_CONFIG) --cflags sdl2 tesseract) $< -o $@ $$($(PKG_CONFIG) --libs sdl2 tesseract) -lpthread -lm

build/test-link-motion: tests/test_link_motion.c app/link.c app/link.h proto/switchview_proto.h
	mkdir -p build
	$(CC) $(CFLAGS) -Iproto $< -o $@ -lm
