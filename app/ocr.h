// Screen OCR: a worker thread that reads the newest capture frame with
// Tesseract while enabled. Results are lower-case with whitespace collapsed.
#ifndef SV_OCR_H
#define SV_OCR_H

#include <stddef.h>
#include <stdint.h>

#include "capture.h"

struct ocr;

// One recognised word, in capture-frame pixels.
struct ocr_box {
  int x, y, w, h;
  char word[32];  // lower-case
};
#define OCR_MAX_BOXES 256

struct ocr *ocr_create(struct capture *cap);
void ocr_destroy(struct ocr *o);

// Reading only runs while enabled (a script is running), to save CPU.
void ocr_set_enabled(struct ocr *o, int on);

// Restrict reading to a region in 0..1 frame coordinates; w or h <= 0 = full frame.
void ocr_set_region(struct ocr *o, float x, float y, float w, float h);

// Copy the latest result. Returns its sequence number (0 = none yet).
// started_ms is SDL_GetTicks() when the frame for it was requested.
unsigned ocr_latest(struct ocr *o, char *buf, size_t len, uint32_t *started_ms);

// Word boxes of the latest result. Returns its sequence number; *n = count.
unsigned ocr_boxes(struct ocr *o, struct ocr_box *out, int max, int *n);

// 1 while a read is in flight (for the scanning animation), and the
// SDL_GetTicks() it started.
int ocr_busy(struct ocr *o, uint32_t *since_ms);
int ocr_enabled(struct ocr *o);

#endif
