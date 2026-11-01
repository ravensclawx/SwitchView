/* Pure accumulator test: no socket is opened and no input is sent. */
#include <assert.h>
#include <limits.h>
#include "../app/link.c"

int main(void)
{
  struct link l = {0};
  link_mouse(&l, 12, -9, 1, 0);
  link_mouse(&l, -2, 4, -1, 0);
  assert(l.mdx == 10 && l.mdy == -5 && l.mwheel == 0);
  link_mouse(&l, INT_MAX, INT_MIN, INT_MAX, 0);
  assert(l.mdx == INT_MAX && l.mdy == INT_MIN && l.mwheel == INT_MAX);
  link_mouse(&l, 1, -1, 1, 0);
  assert(l.mdx == INT_MAX && l.mdy == INT_MIN && l.mwheel == INT_MAX);
  link_mouse(&l, INT_MIN, INT_MAX, INT_MIN, 0);
  assert(l.mdx == -1 && l.mdy == -1 && l.mwheel == -1);
  link_mouse(&l, INT_MIN, INT_MIN, INT_MIN, 0);
  assert(l.mdx == INT_MIN && l.mdy == INT_MIN && l.mwheel == INT_MIN);
  link_mouse(&l, INT_MAX, INT_MAX, INT_MAX, SV_MOUSE_LEFT);
  assert(l.mdx == -1 && l.mdy == -1 && l.mwheel == -1);
  assert(l.mbtn == SV_MOUSE_LEFT && l.mdirty);
  puts("link motion tests passed: small deltas, signed extremes, saturation and recovery");
  return 0;
}
