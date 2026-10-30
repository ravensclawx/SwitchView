# SwitchView: capture viewer + Pro Controller/keyboard command panel (app/),
# Pico 2 W firmware (firmware/), shared wire protocol (proto/).

CFLAGS ?= -O2 -Wall -Wextra
PKGS = sdl2 SDL2_ttf alsa tesseract lua5.4
PICO_SDK_PATH ?= $(HOME)/Development/pico-sdk
USB_LAYOUT ?= 1        # 0 controller only, 1 controller + keyboard, 2 keyboard only

APP = app/switchview
SRCS = app/main.c app/capture.c app/panel.c app/link.c app/ocr.c app/script.c
OBJS = $(SRCS:.c=.o)

all: $(APP)

$(APP): $(OBJS)
	$(CC) $(CFLAGS) $(OBJS) -o $@ $$(pkg-config --libs $(PKGS)) -lpthread -lm

app/%.o: app/%.c app/*.h proto/switchview_proto.h
	$(CC) $(CFLAGS) -Iproto $$(pkg-config --cflags $(PKGS)) -c $< -o $@

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
