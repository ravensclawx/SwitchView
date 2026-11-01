// Lua script runner. A script runs on its own thread; it drives the same
// controller/keyboard as the panel and reads the screen through OCR.
#ifndef SV_SCRIPT_H
#define SV_SCRIPT_H

#include <stddef.h>
#include <stdint.h>

#include "link.h"
#include "ocr.h"

#define SCRIPT_LOG_LINES 64
#define SCRIPT_LOG_COLS 120

struct script;

struct script *script_create(struct ocr *ocr, const char *dir);
// Main-thread lifecycle: destroy joins the worker, including any native Lua call.
void script_destroy(struct script *s);

// Scripts found in the directory (*.lua, sorted). Rescanned on demand.
int script_count(struct script *s);
const char *script_name(struct script *s, int i);
void script_rescan(struct script *s);

int script_start(struct script *s, int index);
// Request cancellation without blocking the UI; script_running reports completion.
void script_stop(struct script *s);
int script_running(struct script *s);

// Controller input the running script wants; *active is 0 when idle.
void script_get_input(struct script *s, struct link_state *out, int *active);
// Host keyboard LED byte from the link (-1 = unknown), for capslock().
void script_set_leds(struct script *s, int leds);

// Text the script typed since the last call (for link_send_text).
int script_take_text(struct script *s, char *buf, size_t len);

// Last screen label the script classified ("" if none) and log lines,
// oldest first; returns the number of lines copied.
void script_screen(struct script *s, char *buf, size_t len);
int script_log(struct script *s, char lines[][SCRIPT_LOG_COLS], int max);

// Words the script is currently looking for (matched rule / find target),
// space-free and lower-case, for highlighting in the OCR overlay.
int script_highlights(struct script *s, char words[][64], int max);

#endif
