#ifndef _TUSB_CONFIG_H_
#define _TUSB_CONFIG_H_
#ifdef __cplusplus
extern "C" {
#endif
#ifndef CFG_TUSB_MCU
#error CFG_TUSB_MCU must be defined
#endif
#ifndef BOARD_DEVICE_RHPORT_NUM
#define BOARD_DEVICE_RHPORT_NUM 0
#endif
#ifndef BOARD_DEVICE_RHPORT_SPEED
#define BOARD_DEVICE_RHPORT_SPEED OPT_MODE_FULL_SPEED
#endif
#define CFG_TUSB_RHPORT0_MODE (OPT_MODE_DEVICE | BOARD_DEVICE_RHPORT_SPEED)
#ifndef CFG_TUSB_OS
#define CFG_TUSB_OS OPT_OS_PICO
#endif
#define CFG_TUD_ENDPOINT0_SIZE 64
#if USB_LAYOUT == 1
#define CFG_TUD_HID 3
#else
#define CFG_TUD_HID 1
#endif
#define CFG_TUD_HID_EP_BUFSIZE 64
#ifdef __cplusplus
}
#endif
#endif
