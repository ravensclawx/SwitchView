#include "viewer_util.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void parsing(void)
{
  int n = 7, w = 0, h = 0;
  assert(sv_parse_int("65535", 1, 65535, &n) && n == 65535);
  const char *bad[] = {"", "0", "-1", "+1", " 1", "1 ", "1junk", "1.5", "65536",
                      "184467440737095516160000000"};
  for (unsigned i = 0; i < sizeof bad / sizeof *bad; ++i) {
    n = 7;
    assert(!sv_parse_int(bad[i], 1, 65535, &n));
    assert(n == 7);
  }
  assert(!sv_parse_int(NULL, 1, 65535, &n));
  assert(sv_parse_size("1920x1080", &w, &h) && w == 1920 && h == 1080);
  assert(sv_parse_size("16384x16384", &w, &h));
  const char *bad_size[] = {"0x1080", "1920x0", "1920x1080junk", "1920X1080",
                           "1920x1080x1", "-1x10", "16385x1", "1x16385",
                           "999999999999999999999x1080", "1920", "x1080"};
  for (unsigned i = 0; i < sizeof bad_size / sizeof *bad_size; ++i)
    assert(!sv_parse_size(bad_size[i], &w, &h));
  float scale = 0;
  assert(sv_parse_scale("0.5", &scale) && scale == .5f);
  assert(sv_parse_scale("100", &scale) && scale == 100.f);
  const char *bad_scale[] = {"nan", "NaN", "inf", "-inf", "0", "-1", "100.1", "1junk",
                            "", " 1", "1 ", "1e9999", "1e-9999"};
  for (unsigned i = 0; i < sizeof bad_scale / sizeof *bad_scale; ++i)
    assert(!sv_parse_scale(bad_scale[i], &scale));
}

static void pointer_mapping(void)
{
  SDL_Event event = {0};
  event.type = SDL_MOUSEMOTION;
  event.motion.x = 480; event.motion.y = 300;
  event.motion.xrel = -13; event.motion.yrel = 7;
  sv_pointer_to_drawable(&event, 960, 600, 960, 600);
  assert(event.motion.x == 480 && event.motion.y == 300);
  sv_pointer_to_drawable(&event, 960, 600, 1920, 1200);
  assert(event.motion.x == 960 && event.motion.y == 600);
  assert(event.motion.xrel == -13 && event.motion.yrel == 7);
  for (Uint32 type = SDL_MOUSEBUTTONDOWN; type <= SDL_MOUSEBUTTONUP; ++type) {
    memset(&event, 0, sizeof event);
    event.type = type; event.button.x = 32; event.button.y = 500;
    sv_pointer_to_drawable(&event, 960, 600, 1920, 1200);
    assert(event.button.x == 64 && event.button.y == 1000);
  }
  assert(sv_pointer_coordinate(-10, 100, 200) == -20);
  assert(sv_pointer_coordinate(150, 100, 200) == 300);
  assert(sv_pointer_coordinate(75, 100, 150) == 112);
  assert(sv_pointer_coordinate(75, 0, 200) == 75);
  assert(sv_pointer_coordinate(INT_MAX, 1, INT_MAX) == INT_MAX);
  assert(sv_pointer_coordinate(INT_MIN, 1, INT_MAX) == INT_MIN);
  memset(&event, 0, sizeof event);
  event.type = SDL_KEYDOWN; event.key.keysym.sym = SDLK_a;
  SDL_Event saved = event;
  sv_pointer_to_drawable(&event, 960, 600, 1920, 1200);
  assert(!memcmp(&event, &saved, sizeof event));
}

static void relative_motion(void)
{
  double fraction = 0;
  assert(sv_relative_motion(1, .5f, &fraction) == 0 && fraction == .5);
  assert(sv_relative_motion(1, .5f, &fraction) == 1 && fraction == 0);
  assert(sv_relative_motion(-1, .5f, &fraction) == 0 && fraction == -.5);
  assert(sv_relative_motion(-1, .5f, &fraction) == -1 && fraction == 0);
  assert(sv_relative_motion(INT_MAX, 100.f, &fraction) == INT_MAX && fraction == 0);
  assert(sv_relative_motion(INT_MIN, 100.f, &fraction) == INT_MIN && fraction == 0);
  assert(sv_relative_motion(INT_MAX, 1.f, &fraction) == INT_MAX);
  assert(sv_relative_motion(INT_MIN, 1.f, &fraction) == INT_MIN);
  assert(sv_relative_motion(2, .25f, &fraction) == 0 && fraction == .5);
  assert(sv_relative_motion(-2, .25f, &fraction) == 0 && fraction == 0);
  fraction = NAN;
  assert(sv_relative_motion(1, 1.f, &fraction) == 0 && fraction == 0);
}

static void refresh_timing(void)
{
  Uint32 last = 1000;
  assert(!sv_refresh_due(1032, &last, 33) && last == 1000);
  assert(sv_refresh_due(1033, &last, 33) && last == 1033);
  assert(!sv_refresh_due(1034, &last, 33));
  unsigned redraws = 0;
  last = 0;
  for (Uint32 now = 0; now < 1000; now += 4)
    redraws += sv_refresh_due(now, &last, 33);
  assert(redraws >= 27 && redraws <= 30); /* Not ~250 redraws/second. */
  last = UINT32_MAX - 10;
  assert(!sv_refresh_due(10, &last, 33));
  assert(sv_refresh_due(22, &last, 33));
}

int main(void)
{
  parsing(); pointer_mapping(); relative_motion(); refresh_timing();
  puts("viewer utility tests passed: strict options, DPI input, refresh pacing/wraparound");
  return 0;
}
