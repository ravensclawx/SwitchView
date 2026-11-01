#ifndef SV_VIEWER_UTIL_H
#define SV_VIEWER_UTIL_H

#include <SDL2/SDL.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>

/* Decimal-only options: reject partial conversions, signs and overflow. */
static inline int sv_parse_int(const char *text, int min, int max, int *value)
{
  if (!text || !*text) return 0;
  for (const char *p = text; *p; ++p) if (*p < '0' || *p > '9') return 0;
  errno = 0;
  char *end;
  long parsed = strtol(text, &end, 10);
  if (errno || *end || parsed < min || parsed > max) return 0;
  *value = (int)parsed;
  return 1;
}

static inline int sv_parse_size(const char *text, int *width, int *height)
{
  if (!text) return 0;
  char first[16];
  size_t n = 0;
  while (text[n] && text[n] != 'x') {
    if (n >= sizeof first - 1) return 0;
    first[n] = text[n];
    ++n;
  }
  if (text[n] != 'x') return 0;
  first[n] = 0;
  int w, h;
  if (!sv_parse_int(first, 1, 16384, &w) ||
      !sv_parse_int(text + n + 1, 1, 16384, &h)) return 0;
  *width = w; *height = h;
  return 1;
}

static inline int sv_parse_scale(const char *text, float *value)
{
  if (!text || !*text || *text == ' ' || *text == '\t' || *text == '\n' ||
      *text == '\r' || *text == '\f' || *text == '\v') return 0;
  errno = 0;
  char *end;
  float parsed = strtof(text, &end);
  if (errno || end == text || *end || !isfinite(parsed) || parsed <= 0 || parsed > 100) return 0;
  *value = parsed;
  return 1;
}

static inline int sv_pointer_coordinate(int point, int logical, int pixels)
{
  if (logical <= 0 || pixels <= 0) return point;
  int64_t scaled = (int64_t)point * pixels / logical;
  return scaled > INT_MAX ? INT_MAX : scaled < INT_MIN ? INT_MIN : (int)scaled;
}

/* Preserve fractional sensitivity without an out-of-range float-to-int cast.
 * Saturate extreme synthetic/OS deltas rather than wrapping their direction. */
static inline int sv_relative_motion(int delta, float scale, double *fraction)
{
  double total = *fraction + (double)delta * scale;
  if (!(total >= INT_MIN && total <= INT_MAX)) {
    *fraction = 0;
    return total > 0 ? INT_MAX : total < 0 ? INT_MIN : 0;
  }
  int whole = (int)total;
  *fraction = total - whole;
  return whole;
}

/* SDL events are in window points; renderer layouts are in drawable pixels.
 * Relative mouse deltas are device motion, and must not be scaled. */
static inline void sv_pointer_to_drawable(SDL_Event *event, int width, int height,
                                         int pixel_width, int pixel_height)
{
  if (event->type == SDL_MOUSEMOTION) {
    event->motion.x = sv_pointer_coordinate(event->motion.x, width, pixel_width);
    event->motion.y = sv_pointer_coordinate(event->motion.y, height, pixel_height);
  } else if (event->type == SDL_MOUSEBUTTONDOWN || event->type == SDL_MOUSEBUTTONUP) {
    event->button.x = sv_pointer_coordinate(event->button.x, width, pixel_width);
    event->button.y = sv_pointer_coordinate(event->button.y, height, pixel_height);
  }
}

/* Uint32 subtraction remains correct across SDL_GetTicks wraparound. */
static inline int sv_refresh_due(Uint32 now, Uint32 *last, Uint32 interval)
{
  if (now - *last < interval) return 0;
  *last = now;
  return 1;
}

#endif
