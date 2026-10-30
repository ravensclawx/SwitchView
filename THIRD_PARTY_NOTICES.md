# Third-party notices

SwitchView includes code derived from the projects below. Their licenses apply
to those portions.

## retro-pico-switch

https://github.com/DavidPagels/retro-pico-switch

The firmware's Pro Controller USB descriptors, report handling and
handshake replies (`firmware/src/SwitchCommon.cpp`, `firmware/src/SwitchUsb.cpp`,
`firmware/include/SwitchCommon.h`, `SwitchConsts.h`, `SwitchUsb.h`,
`Controller.h`) are derived from this project.

```
MIT License

Copyright (c) 2023 David Pagels

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## TinyUSB

https://github.com/hathach/tinyusb — MIT License, Copyright (c) 2019 Ha Thach
(tinyusb.org). Portions of `firmware/src/SwitchUsb.cpp` follow TinyUSB example
code and carry its notice in the file header. TinyUSB itself is used through
the Raspberry Pi Pico SDK.
