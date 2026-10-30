// Link to the Pico 2 W: UDP today; the interface is transport-agnostic so a
// serial backend can be dropped in later.
#ifndef SV_LINK_H
#define SV_LINK_H

#include <stdint.h>

struct link;

struct link_state {
  uint32_t buttons;  // SV_BTN_*
  int16_t lx, ly, rx, ry;
  uint8_t hat;       // SV_HAT_*
};

struct link_stats {
  unsigned long packets;     // state + text packets sent
  unsigned long send_errors;
  unsigned text_queued;      // chars waiting to go to the Pico
  uint32_t last_send_ms;
  int up;                    // Pico echoed a ping within the last 2 s
  float rtt_ms;              // last measured round trip
  int leds;                  // host keyboard LEDs (SV_LED_*), -1 = not reported yet
};

struct link *link_open(const char *host, int port);
void link_close(struct link *l);

// Latest desired state. Sent immediately if changed, and re-sent as a
// keepalive so a lost packet costs milliseconds, not a stuck button.
void link_set_state(struct link *l, const struct link_state *s);

// Relative mouse motion / buttons for the Switch's USB mouse. Deltas are
// accumulated and flushed once per link_poll.
void link_mouse(struct link *l, int dx, int dy, int wheel, unsigned buttons);

// Queue text for the keyboard interface. Paced to the firmware's typing rate.
void link_send_text(struct link *l, const char *text);

// Call often (every loop iteration). now_ms = SDL_GetTicks().
void link_poll(struct link *l, uint32_t now_ms);

void link_get_stats(struct link *l, struct link_stats *out);
const char *link_describe(struct link *l);

#endif
