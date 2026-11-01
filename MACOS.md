# macOS

SwitchView uses AVFoundation for video capture and SDL/CoreAudio for audio on macOS. The Linux build continues to use V4L2 and ALSA. The Pico firmware and wire protocol are unchanged.

## Build

Install Xcode Command Line Tools and Homebrew dependencies:

```sh
xcode-select --install
brew install sdl2 sdl2_ttf tesseract lua@5.4 pkgconf
make -j4
./app/switchview -L
```

`PKG_CONFIG` can be overridden when dependencies are installed outside Homebrew. This produces a locally linked executable, not a signed, notarized, or standalone application bundle.

## Capture

List devices with `-L`, then select the capture card by the displayed index, exact name, or video UID:

```sh
./app/switchview -d "HDMI Capture" -a "Capture Audio" -r 30
```

Replace the example device names with those reported on your Mac. Video defaults to device 0 at 1920×1080 and nominal 30 fps. Exact rates are preferred. Integer requests such as 24, 30 and 60 also match the conventional 1000/1001 rates when no exact mode exists. Unsupported modes are rejected with a list of available modes. Pixel conversion supports NV12, YUYV, UYVY and BGRA output as available from AVFoundation.

Audio accepts a capture-device index or exact name. Automatic selection requires a unique exact match with the video device name; use `-a` when the names differ. Duplicate audio names are rejected; select an index in that case. `-a default` explicitly selects the system capture input; `-n` disables audio. The audio queue is bounded by `-l` (20 ms by default), and mute clears queued output. Grant camera and microphone permissions when macOS requests them.

The macOS viewer starts with controller input disconnected. Pass `-H <pico-address>` to connect to an existing Pico running the upstream firmware. Linux retains its existing default Pico address. The optional Python 3 launcher prevents duplicate instances started through that launcher:

```sh
python3 tools/launch-viewer.py -d "HDMI Capture" -a "Capture Audio"
```

The launcher starts with input disconnected unless overridden with `-H`. It does not start scripts or flash firmware. Directly launched viewer processes are not covered by its lock.

## Validation

```sh
make test
```

The regression suite opens no capture device or controller link. It checks numeric arguments, Retina input mapping, redraw pacing, launcher locking, script worker shutdown, allocation failure, and stale OCR polling. On macOS it also renders synthetic pixel buffers through SDL to check all five supported layouts, luma, color range, frame ownership, rate matching, and timeout calculations.


```sh
make capture-smoke
./build/capture-smoke "HDMI Capture" "Capture Audio" 60
./build/capture-smoke "HDMI Capture" none 5 yuyv
```

The hardware smoke test defaults to five seconds; the third argument selects 1–300 seconds and the optional fourth argument selects `yuyv` instead of NV12. It checks frame delivery, rendering, luma readback, nonempty OCR output, queue bounds, and mute cleanup. An explicit audio selector requires capture to open; `none` disables audio. This does not verify audible sound or synchronization. It never creates a controller link or runs Lua scripts. Close other software using the capture device first.

macOS capture, luma/OCR, audio availability, and mute cleanup have been exercised locally with a USB HDMI capture device at nominal 1080p30. This does not establish every device or format combination, standalone packaging, or Pico input/firmware acceptance on macOS. Linux capture hardware needs separate validation.

Numeric options reject trailing text and overflow before device access: dimensions are 1–16384, FPS 1–1000, audio queue 1–4000 ms, UDP port 1–65535, and mouse scale greater than 0 through 100. Capture hardware may support only a subset.

Script cancellation requests are asynchronous so the UI stays responsive. Application shutdown joins the script worker before freeing its state; a blocking native Lua call must return before shutdown can complete.
