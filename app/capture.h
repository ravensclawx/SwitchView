// Capture: V4L2/ALSA on Linux, AVFoundation/SDL audio on macOS.
#ifndef SV_CAPTURE_H
#define SV_CAPTURE_H

#include <SDL2/SDL.h>
#include <stdint.h>

#define SV_FOURCC(a,b,c,d) ((unsigned)(a) | ((unsigned)(b)<<8) | ((unsigned)(c)<<16) | ((unsigned)(d)<<24))
#define SV_PIX_FMT_NV12 SV_FOURCC('N','V','1','2')
#define SV_PIX_FMT_YUYV SV_FOURCC('Y','U','Y','V')

struct capture_opts {
  const char *video_dev, *audio_dev;
  int width, height, fps;
  unsigned fourcc;  // SV_PIX_FMT_NV12 or SV_PIX_FMT_YUYV
  int no_audio;
  int audio_max_ms;  // drop input beyond this much queued output
};

struct capture;

#ifdef __APPLE__
void capture_list_devices(void);
#endif

struct capture *capture_open(const struct capture_opts *o, SDL_Renderer *ren);
void capture_close(struct capture *c);

// Waits up to timeout_ms for a frame; uploads the newest one into the texture.
// Returns 1 if the texture was updated.
int capture_poll(struct capture *c, int timeout_ms);

SDL_Texture *capture_texture(struct capture *c);
unsigned capture_width(struct capture *c);
unsigned capture_height(struct capture *c);
int capture_has_audio(struct capture *c);
double capture_audio_queued_ms(struct capture *c);

// Grayscale (luma) snapshots for OCR. Any thread may call capture_want_luma;
// the next frame capture_poll uploads is also copied out. capture_copy_luma
// copies the latest snapshot (width*height bytes) and returns its sequence
// number, 0 if none yet.
void capture_want_luma(struct capture *c);
unsigned capture_copy_luma(struct capture *c, uint8_t *dst);

// Muting keeps capture running (so unmute is instant) but drops the audio.
void capture_set_muted(struct capture *c, int muted);
int capture_muted(struct capture *c);

#endif
