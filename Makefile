# SwitchView: capture viewer + Pro Controller/keyboard command panel (app/),
# Pico 2 W firmware (firmware/), shared wire protocol (proto/).

CFLAGS ?= -O2 -Wall -Wextra
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
PKG_CONFIG ?= $(shell if command -v brew >/dev/null 2>&1 && test -x "$$(brew --prefix)/bin/pkg-config"; then printf "%s/bin/pkg-config" "$$(brew --prefix)"; else command -v pkg-config 2>/dev/null || printf pkg-config; fi)
else
PKG_CONFIG ?= pkg-config
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
