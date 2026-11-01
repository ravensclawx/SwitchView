/* Physical capture/OCR smoke test. Never creates an input link or runs scripts. */
#include "capture.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tesseract/capi.h>

int main(int argc, char **argv)
{
  int result = 1;
  if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO)) return 1;
  SDL_Window *win = SDL_CreateWindow("SwitchView capture test", 0, 0, 640, 360, SDL_WINDOW_HIDDEN);
  SDL_Renderer *ren = win ? SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED) : NULL;
  if (!ren) { fprintf(stderr, "%s\n", SDL_GetError()); SDL_DestroyWindow(win); SDL_Quit(); return 1; }
  int duration = argc > 3 ? atoi(argv[3]) : 5;
  if (duration < 1 || duration > 300) { fprintf(stderr, "Duration must be 1..300 seconds\n"); goto done; }
  int no_audio = argc > 2 && !strcmp(argv[2], "none");
  struct capture_opts opts = {.video_dev = argc > 1 ? argv[1] : "0",
    .audio_dev = argc > 2 ? argv[2] : "auto", .width = 1920, .height = 1080,
    .fps = 30, .fourcc = argc > 4 && !strcmp(argv[4], "yuyv") ? SV_PIX_FMT_YUYV : SV_PIX_FMT_NV12,
    .no_audio = no_audio, .audio_max_ms = 20};
  struct capture *cap = capture_open(&opts, ren);
  if (!cap) goto done;
  size_t size = (size_t)capture_width(cap) * capture_height(cap);
  uint8_t *pixels = malloc(size);
  if (!pixels) goto close_capture;
  unsigned frames = 0, seq = 0;
  double max_queue_ms = 0;
  Uint32 start = SDL_GetTicks();
  while (SDL_GetTicks() - start < (Uint32)duration * 1000) {
    SDL_PumpEvents();
    capture_want_luma(cap);
    frames += capture_poll(cap, 10) > 0;
    seq = capture_copy_luma(cap, pixels);
    double queued = capture_audio_queued_ms(cap);
    if (queued > max_queue_ms) max_queue_ms = queued;
    SDL_RenderClear(ren);
    if (SDL_RenderCopy(ren, capture_texture(cap), NULL, NULL) < 0) goto free_pixels;
    SDL_RenderPresent(ren);
  }
  unsigned low = 255, high = 0;
  if (seq) for (size_t i = 0; i < size; ++i) {
    if (pixels[i] < low) low = pixels[i];
    if (pixels[i] > high) high = pixels[i];
  }
  printf("frames=%u elapsed_ms=%u luma_sequence=%u luma_range=%u..%u audio=%d queue_ms=%.3f\n",
    frames, SDL_GetTicks()-start, seq, low, high, capture_has_audio(cap), capture_audio_queued_ms(cap));
  printf("max_audio_queue_ms=%.3f\n", max_queue_ms);
  if (frames < (unsigned)duration * 3 || !seq || high <= low || max_queue_ms > opts.audio_max_ms + 1) goto free_pixels;
  if (argc > 2 && !no_audio && !capture_has_audio(cap)) goto free_pixels;
  TessBaseAPI *ocr = TessBaseAPICreate();
  if (TessBaseAPIInit3(ocr, NULL, "eng")) { TessBaseAPIDelete(ocr); goto free_pixels; }
  TessBaseAPISetPageSegMode(ocr, PSM_SPARSE_TEXT);
  TessBaseAPISetVariable(ocr, "user_defined_dpi", "150");
  TessBaseAPISetImage(ocr, pixels, capture_width(cap), capture_height(cap), 1, capture_width(cap));
  char *text = TessBaseAPIGetUTF8Text(ocr);
  printf("OCR:\n%s\n", text ? text : "");
  int readable = text && *text;
  if (text) TessDeleteText(text);
  TessBaseAPIDelete(ocr);
  capture_set_muted(cap, 1);
  SDL_Delay(50);
  printf("muted=%d queue_after_mute_ms=%.3f\n", capture_muted(cap), capture_audio_queued_ms(cap));
  result = !readable || !capture_muted(cap) || capture_audio_queued_ms(cap) != 0;
free_pixels:
  free(pixels);
close_capture:
  capture_close(cap);
done:
  SDL_DestroyRenderer(ren);
  SDL_DestroyWindow(win);
  SDL_Quit();
  return result;
}
