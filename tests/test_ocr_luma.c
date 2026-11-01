/* Exercise actual OCR polling helper without capture hardware or OCR work. */
#include <assert.h>
#include <string.h>
#include "../app/ocr.c"

struct capture { unsigned sequence, queries, copies; uint8_t pixels[4]; };
unsigned capture_width(struct capture *c) { (void)c; return 2; }
unsigned capture_height(struct capture *c) { (void)c; return 2; }
void capture_want_luma(struct capture *c) { (void)c; }
unsigned capture_copy_luma(struct capture *c, uint8_t *dst)
{
  if (dst) { ++c->copies; memcpy(dst, c->pixels, sizeof c->pixels); }
  else ++c->queries;
  return c->sequence;
}

int main(void)
{
  struct capture cap = {.sequence = 7, .pixels = {1, 2, 3, 4}};
  uint8_t frame[4] = {0};
  for (int i = 0; i < 100; ++i) assert(copy_new_luma(&cap, frame, 7) == 0);
  assert(cap.queries == 100 && cap.copies == 0);
  assert(frame[0] == 0); /* Stale polling did not touch the destination. */
  cap.sequence = 8;
  assert(copy_new_luma(&cap, frame, 7) == 8);
  assert(cap.queries == 101 && cap.copies == 1);
  assert(!memcmp(frame, cap.pixels, sizeof frame));
  cap.sequence = 0;
  assert(copy_new_luma(&cap, frame, 8) == 0 && cap.copies == 1);
  puts("OCR luma tests passed: 100 stale polls, zero pixel copies; new frame copied once");
  return 0;
}
