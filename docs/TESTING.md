# Testing the desktop viewer

## Host regression suite

Install the dependencies documented in README.md (Linux) or MACOS.md, then run:

```sh
make -B -j4 test
```

This builds the viewer and exercises strict option parsing, drawable-coordinate mapping, refresh cadence/tick wrap, bounded relative mouse arithmetic, link accumulators, launcher locking, stale OCR snapshots, and script restart/cancellation/join behavior. Lua tests use synthetic fixtures and no input link. The macOS-only backend test uses synthetic CoreVideo buffers and a hidden SDL renderer; it opens no camera or microphone.

The backend suite covers five pixel layouts, luma and RGB range/matrix readback, latest-frame replacement and ownership, sequence wrap, incompatible-frame rejection, conventional nominal/fractional rate matching, ambiguous audio names, and monotonic timeout budgets. These tests do not replace capture-device tests.

For memory and undefined-behavior instrumentation:

```sh
make -B -j4 test CFLAGS='-O1 -g -Wall -Wextra -fsanitize=address,undefined -fno-omit-frame-pointer'
```

On macOS, Make exposes the SDL3 library directory reported by pkg-config to child processes when an SDL2 compatibility package is installed. This avoids dependency-loader failures before a test reaches main. Sanitizer coverage applies to instrumented application code; system and prebuilt dependencies are not fully instrumented.

Rebuild normally after an instrumented build:

```sh
make -B -j4
```

## Manual capture checks

```sh
make capture-smoke
./build/capture-smoke "VIDEO DEVICE" "AUDIO DEVICE" 60
./build/capture-smoke "VIDEO DEVICE" none 5 yuyv
```

Use the actual device names or indices. The test renders frames, requests luma, checks nonempty OCR, measures the maximum queued audio, and verifies mute clears the queue. It requires visible text. An explicit audio selector must open successfully; `none` disables audio. Run one capture test at a time. A successful result does not prove audible output, synchronization, or a live console signal.

Also check invalid devices/modes, permission denial, unplug/replug, repeated open/close, resize/Retina input, and shutdown while a script is running. Hardware-dependent cases need their own observations. Never use a real controller link for automated host tests.

## Evidence limits

Synthetic color tests do not establish HDR or every device color-space metadata combination. Frame throughput depends on the capture device, output mode and renderer; distinguish requested FPS from measured frames. Script stop requests are asynchronous, but destruction joins the worker: an unbounded native Lua call can delay shutdown until it returns. Host builds do not validate firmware, controller pairing, or Linux capture hardware.
