#include "script.h"
#include "switchview_proto.h"

#include <SDL2/SDL.h>
#include <dirent.h>
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
#include <unistd.h>

#define MAX_SCRIPTS 64
#define MAX_RULES 64
#define MAX_RULE_WORDS 8
#define DEFAULT_HOLD 0.12  // shorter taps can fall between controller reports

struct rule {
  char label[48];
  char words[MAX_RULE_WORDS][64];
  int nwords;
};

struct script {
  struct ocr *ocr;
  char dir[1024];
  char names[MAX_SCRIPTS][128];
  int count;

  pthread_t th;
  atomic_int running, stop;

  pthread_mutex_t lock;  // guards everything below
  struct link_state input;
  char textq[1024];
  size_t textq_len;
  char screen[48];
  char log[SCRIPT_LOG_LINES][SCRIPT_LOG_COLS];
  int log_head, log_count;
  struct rule rules[MAX_RULES];
  int nrules;
  char path[1200];
  char hl[MAX_RULE_WORDS][64];
  int nhl;
  atomic_int leds;
};

static const struct { const char *name; uint32_t bit; } BUTTONS[] = {
  {"A", SV_BTN_A}, {"B", SV_BTN_B}, {"X", SV_BTN_X}, {"Y", SV_BTN_Y},
  {"L", SV_BTN_L}, {"R", SV_BTN_R}, {"ZL", SV_BTN_ZL}, {"ZR", SV_BTN_ZR},
  {"PLUS", SV_BTN_PLUS}, {"+", SV_BTN_PLUS}, {"MINUS", SV_BTN_MINUS}, {"-", SV_BTN_MINUS},
  {"HOME", SV_BTN_HOME}, {"CAPTURE", SV_BTN_CAPTURE}, {"L3", SV_BTN_L3}, {"R3", SV_BTN_R3},
};

static const struct { const char *name; uint8_t hat; } HATS[] = {
  {"up", SV_HAT_UP}, {"upright", SV_HAT_UPRIGHT}, {"right", SV_HAT_RIGHT},
  {"downright", SV_HAT_DOWNRIGHT}, {"down", SV_HAT_DOWN}, {"downleft", SV_HAT_DOWNLEFT},
  {"left", SV_HAT_LEFT}, {"upleft", SV_HAT_UPLEFT}, {"center", SV_HAT_CENTER},
};

/* ---------------- shared state helpers ---------------- */

static void logf_(struct script *s, const char *fmt, ...)
{
  char line[SCRIPT_LOG_COLS];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(line, sizeof line, fmt, ap);
  va_end(ap);
  fprintf(stderr, "script: %s\n", line);
  pthread_mutex_lock(&s->lock);
  int idx = (s->log_head + s->log_count) % SCRIPT_LOG_LINES;
  if (s->log_count == SCRIPT_LOG_LINES) s->log_head = (s->log_head + 1) % SCRIPT_LOG_LINES;
  else s->log_count++;
  snprintf(s->log[idx], SCRIPT_LOG_COLS, "%s", line);
  pthread_mutex_unlock(&s->lock);
}

static struct script *self(lua_State *L)
{
  lua_getfield(L, LUA_REGISTRYINDEX, "sv_script");
  struct script *s = lua_touserdata(L, -1);
  lua_pop(L, 1);
  return s;
}

// Sleep in small slices so Stop takes effect immediately.
static void nap(lua_State *L, struct script *s, double seconds)
{
  uint32_t end = SDL_GetTicks() + (uint32_t)(seconds * 1000);
  while ((int32_t)(end - SDL_GetTicks()) > 0) {
    if (atomic_load(&s->stop)) luaL_error(L, "stopped");
    usleep(5000);
  }
  if (atomic_load(&s->stop)) luaL_error(L, "stopped");
}

static uint32_t button_bits(lua_State *L, int first)
{
  uint32_t bits = 0;
  for (int i = first; i <= lua_gettop(L); i++) {
    if (lua_type(L, i) != LUA_TSTRING) continue;
    const char *n = lua_tostring(L, i);
    unsigned k;
    for (k = 0; k < sizeof BUTTONS / sizeof BUTTONS[0]; k++)
      if (!strcasecmp(n, BUTTONS[k].name)) { bits |= BUTTONS[k].bit; break; }
    if (k == sizeof BUTTONS / sizeof BUTTONS[0]) luaL_error(L, "unknown button '%s'", n);
  }
  return bits;
}

// Collapse spaces: OCR drops and adds them unpredictably.
static void squash(const char *in, char *out, size_t len)
{
  size_t n = 0;
  for (; *in && n + 1 < len; in++) if (*in != ' ') out[n++] = *in;
  out[n] = 0;
}

static const char *classify(struct script *s, const char *text)
{
  static char squashed[8192];  // script thread only
  squash(text, squashed, sizeof squashed);
  pthread_mutex_lock(&s->lock);
  const char *label = "unknown";
  for (int i = 0; i < s->nrules; i++) {
    int all = 1;
    for (int w = 0; w < s->rules[i].nwords && all; w++)
      if (!strstr(squashed, s->rules[i].words[w])) all = 0;
    if (all) {
      label = s->rules[i].label;
      s->nhl = s->rules[i].nwords;
      memcpy(s->hl, s->rules[i].words, sizeof s->hl);
      break;
    }
  }
  snprintf(s->screen, sizeof s->screen, "%s", label);
  pthread_mutex_unlock(&s->lock);
  return label;
}

// Block until an OCR result for a frame requested at/after `since` exists.
static void fresh_text(lua_State *L, struct script *s, uint32_t since, char *buf, size_t len)
{
  for (;;) {
    uint32_t started;
    if (ocr_latest(s->ocr, buf, len, &started) && (int32_t)(started - since) >= 0) return;
    nap(L, s, 0.02);
  }
}

/* ---------------- Lua API ---------------- */

static int l_log(lua_State *L)
{
  int n = lua_gettop(L), parts = 0;
  for (int i = 1; i <= n; i++) {
    if (i > 1) { lua_pushliteral(L, " "); parts++; }
    luaL_tolstring(L, i, NULL);
    parts++;
  }
  if (parts) lua_concat(L, parts); else lua_pushliteral(L, "");
  logf_(self(L), "%s", lua_tostring(L, -1));
  return 0;
}

static int l_sleep(lua_State *L)
{
  nap(L, self(L), luaL_checknumber(L, 1));
  return 0;
}

static int l_press(lua_State *L)
{
  struct script *s = self(L);
  uint32_t bits = button_bits(L, 1);
  pthread_mutex_lock(&s->lock);
  s->input.buttons |= bits;
  pthread_mutex_unlock(&s->lock);
  return 0;
}

static int l_release(lua_State *L)
{
  struct script *s = self(L);
  uint32_t bits = lua_gettop(L) ? button_bits(L, 1) : 0xffffffffu;
  pthread_mutex_lock(&s->lock);
  s->input.buttons &= ~bits;
  pthread_mutex_unlock(&s->lock);
  return 0;
}

// tap("A") / tap("A", 0.3) / tap("L", "R", 0.2)
static int l_tap(lua_State *L)
{
  struct script *s = self(L);
  double hold = DEFAULT_HOLD;
  int top = lua_gettop(L);
  if (top && lua_type(L, top) == LUA_TNUMBER) { hold = lua_tonumber(L, top); lua_pop(L, 1); }
  uint32_t bits = button_bits(L, 1);
  pthread_mutex_lock(&s->lock);
  s->input.buttons |= bits;
  pthread_mutex_unlock(&s->lock);
  nap(L, s, hold);
  pthread_mutex_lock(&s->lock);
  s->input.buttons &= ~bits;
  pthread_mutex_unlock(&s->lock);
  nap(L, s, 0.05);  // let the release register before the next input
  return 0;
}

// dpad("right") holds; dpad("right", 0.1) taps; dpad("center") releases.
static int l_dpad(lua_State *L)
{
  struct script *s = self(L);
  const char *d = luaL_checkstring(L, 1);
  int hat = -1;
  for (unsigned k = 0; k < sizeof HATS / sizeof HATS[0]; k++)
    if (!strcasecmp(d, HATS[k].name)) hat = HATS[k].hat;
  if (hat < 0) return luaL_error(L, "unknown direction '%s'", d);
  pthread_mutex_lock(&s->lock);
  s->input.hat = (uint8_t)hat;
  pthread_mutex_unlock(&s->lock);
  if (lua_isnumber(L, 2)) {
    nap(L, s, lua_tonumber(L, 2));
    pthread_mutex_lock(&s->lock);
    s->input.hat = SV_HAT_CENTER;
    pthread_mutex_unlock(&s->lock);
    nap(L, s, 0.05);
  }
  return 0;
}

static int16_t axis(double v)
{
  if (v > 1) v = 1;
  if (v < -1) v = -1;
  return (int16_t)(v * 32767);
}

// stick("l", x, y [, seconds]); x/y in -1..1, y up. With seconds it recentres.
static int l_stick(lua_State *L)
{
  struct script *s = self(L);
  const char *which = luaL_checkstring(L, 1);
  int16_t x = axis(luaL_checknumber(L, 2)), y = axis(luaL_checknumber(L, 3));
  int right = which[0] == 'r' || which[0] == 'R';
  pthread_mutex_lock(&s->lock);
  if (right) { s->input.rx = x; s->input.ry = y; } else { s->input.lx = x; s->input.ly = y; }
  pthread_mutex_unlock(&s->lock);
  if (lua_isnumber(L, 4)) {
    nap(L, s, lua_tonumber(L, 4));
    pthread_mutex_lock(&s->lock);
    if (right) s->input.rx = s->input.ry = 0; else s->input.lx = s->input.ly = 0;
    pthread_mutex_unlock(&s->lock);
  }
  return 0;
}

// type("hello\n") - queued to the keyboard; waits roughly as long as typing takes.
static int l_type(lua_State *L)
{
  struct script *s = self(L);
  size_t n;
  const char *t = luaL_checklstring(L, 1, &n);
  pthread_mutex_lock(&s->lock);
  size_t room = sizeof s->textq - 1 - s->textq_len;
  if (n > room) n = room;
  memcpy(s->textq + s->textq_len, t, n);
  s->textq_len += n;
  pthread_mutex_unlock(&s->lock);
  nap(L, s, 0.1 + n / (double)SV_TEXT_CHARS_PER_SEC);
  return 0;
}

// key("capslock" | "enter" | "esc" | "backspace" | "tab" | "up" | "down" |
//     "left" | "right") - press one non-printing key on the keyboard.
static int l_key(lua_State *L)
{
  static const struct { const char *name; char ch; } KEYS[] = {
    {"capslock", SV_KEY_CAPSLOCK}, {"enter", '\n'}, {"esc", 27}, {"backspace", '\b'},
    {"tab", '\t'}, {"up", SV_KEY_UP}, {"down", SV_KEY_DOWN}, {"left", SV_KEY_LEFT},
    {"right", SV_KEY_RIGHT},
  };
  struct script *s = self(L);
  const char *n = luaL_checkstring(L, 1);
  for (unsigned k = 0; k < sizeof KEYS / sizeof KEYS[0]; k++)
    if (!strcasecmp(n, KEYS[k].name)) {
      pthread_mutex_lock(&s->lock);
      if (s->textq_len + 1 < sizeof s->textq) s->textq[s->textq_len++] = KEYS[k].ch;
      pthread_mutex_unlock(&s->lock);
      nap(L, s, 0.25);
      return 0;
    }
  return luaL_error(L, "unknown key '%s'", n);
}

// capslock() -> true/false from the console's keyboard LED, nil if unknown.
static int l_capslock(lua_State *L)
{
  int leds = atomic_load(&self(L)->leds);
  if (leds < 0) lua_pushnil(L); else lua_pushboolean(L, leds & SV_LED_CAPSLOCK);
  return 1;
}

// text() -> OCR text of a frame captured after this call.
static int l_text(lua_State *L)
{
  struct script *s = self(L);
  char buf[8192];
  fresh_text(L, s, SDL_GetTicks(), buf, sizeof buf);
  lua_pushstring(L, buf);
  return 1;
}

// screen() -> label of the current screen per the rules.
static int l_screen(lua_State *L)
{
  struct script *s = self(L);
  char buf[8192];
  fresh_text(L, s, SDL_GetTicks(), buf, sizeof buf);
  lua_pushstring(L, classify(s, buf));
  return 1;
}

static int label_in(lua_State *L, int idx, const char *label)
{
  if (lua_type(L, idx) == LUA_TTABLE) {
    for (lua_Integer i = 1;; i++) {
      lua_rawgeti(L, idx, i);
      if (lua_isnil(L, -1)) { lua_pop(L, 1); return 0; }
      int hit = !strcmp(lua_tostring(L, -1), label);
      lua_pop(L, 1);
      if (hit) return 1;
    }
  }
  // "menu,dialog"
  const char *list = luaL_checkstring(L, idx);
  size_t ln = strlen(label);
  for (const char *p = list; *p;) {
    while (*p == ',' || *p == ' ') p++;
    const char *e = p;
    while (*e && *e != ',') e++;
    const char *t = e;
    while (t > p && t[-1] == ' ') t--;
    if ((size_t)(t - p) == ln && !strncmp(p, label, ln)) return 1;
    p = e;
  }
  return 0;
}

// wait("menu,dialog" | {"menu","dialog"}, timeout=30) -> label or nil
static int l_wait(lua_State *L)
{
  struct script *s = self(L);
  double timeout = luaL_optnumber(L, 2, 30);
  uint32_t end = SDL_GetTicks() + (uint32_t)(timeout * 1000);
  char buf[8192];
  unsigned last = 0;
  while ((int32_t)(end - SDL_GetTicks()) > 0) {
    unsigned seq = ocr_latest(s->ocr, buf, sizeof buf, NULL);
    if (seq && seq != last) {
      last = seq;
      const char *label = classify(s, buf);
      if (label_in(L, 1, label)) { lua_pushstring(L, label); return 1; }
    }
    nap(L, s, 0.02);
  }
  lua_pushnil(L);
  return 1;
}

// find("word", timeout=0) -> true if the word (spaces ignored) is on screen.
static int l_find(lua_State *L)
{
  struct script *s = self(L);
  char want[256], buf[8192], sq[8192];
  squash(luaL_checkstring(L, 1), want, sizeof want);
  for (char *c = want; *c; c++) *c = (char)tolower((unsigned char)*c);
  double timeout = luaL_optnumber(L, 2, 0);
  uint32_t end = SDL_GetTicks() + (uint32_t)(timeout * 1000);
  pthread_mutex_lock(&s->lock);
  snprintf(s->hl[0], sizeof s->hl[0], "%.63s", want);
  s->nhl = 1;
  pthread_mutex_unlock(&s->lock);
  fresh_text(L, s, SDL_GetTicks(), buf, sizeof buf);
  for (;;) {
    squash(buf, sq, sizeof sq);
    if (strstr(sq, want)) { lua_pushboolean(L, 1); return 1; }
    if ((int32_t)(end - SDL_GetTicks()) <= 0) break;
    fresh_text(L, s, SDL_GetTicks(), buf, sizeof buf);
  }
  lua_pushboolean(L, 0);
  return 1;
}

static void add_rule(lua_State *L, struct script *s, const char *label, int words_idx, int first_word)
{
  struct rule r = {0};
  snprintf(r.label, sizeof r.label, "%s", label);
  if (words_idx) {
    for (lua_Integer i = 1; r.nwords < MAX_RULE_WORDS; i++) {
      lua_rawgeti(L, words_idx, i);
      if (lua_isnil(L, -1)) { lua_pop(L, 1); break; }
      squash(lua_tostring(L, -1), r.words[r.nwords], sizeof r.words[0]);
      r.nwords++;
      lua_pop(L, 1);
    }
  } else {
    for (int i = first_word; i <= lua_gettop(L) && r.nwords < MAX_RULE_WORDS; i++)
      squash(luaL_checkstring(L, i), r.words[r.nwords++], sizeof r.words[0]);
  }
  for (int w = 0; w < r.nwords; w++)
    for (char *c = r.words[w]; *c; c++) *c = (char)tolower((unsigned char)*c);
  pthread_mutex_lock(&s->lock);
  if (s->nrules < MAX_RULES) s->rules[s->nrules++] = r;
  pthread_mutex_unlock(&s->lock);
}

// rule("menu", "press start", ...) - checked in the order added.
static int l_rule(lua_State *L)
{
  add_rule(L, self(L), luaL_checkstring(L, 1), 0, 2);
  return 0;
}

// rules{ menu = {"press start"}, dialog = {"are you sure"} } - unordered.
static int l_rules(lua_State *L)
{
  struct script *s = self(L);
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_pushnil(L);
  while (lua_next(L, 1)) {
    if (lua_type(L, -2) == LUA_TSTRING) {
      if (lua_istable(L, -1)) add_rule(L, s, lua_tostring(L, -2), lua_gettop(L), 0);
      else if (lua_type(L, -1) == LUA_TSTRING) {
        lua_newtable(L);
        lua_pushvalue(L, -2);
        lua_rawseti(L, -2, 1);
        add_rule(L, s, lua_tostring(L, -3), lua_gettop(L), 0);
        lua_pop(L, 1);
      }
    }
    lua_pop(L, 1);
  }
  return 0;
}

// region(x, y, w, h) in 0..1 of the frame; region() = whole screen.
static int l_region(lua_State *L)
{
  struct script *s = self(L);
  if (lua_gettop(L) == 0) ocr_set_region(s->ocr, 0, 0, 0, 0);
  else ocr_set_region(s->ocr, (float)luaL_checknumber(L, 1), (float)luaL_checknumber(L, 2),
                      (float)luaL_checknumber(L, 3), (float)luaL_checknumber(L, 4));
  return 0;
}

static void stop_hook(lua_State *L, lua_Debug *ar)
{
  (void)ar;
  if (atomic_load(&self(L)->stop)) luaL_error(L, "stopped");
}

/* ---------------- thread ---------------- */

static void clear_input(struct script *s)
{
  pthread_mutex_lock(&s->lock);
  memset(&s->input, 0, sizeof s->input);
  s->input.hat = SV_HAT_CENTER;
  pthread_mutex_unlock(&s->lock);
}

static void *script_thread(void *arg)
{
  struct script *s = arg;
  lua_State *L = luaL_newstate();
  luaL_openlibs(L);
  lua_pushlightuserdata(L, s);
  lua_setfield(L, LUA_REGISTRYINDEX, "sv_script");
  static const luaL_Reg api[] = {
    {"log", l_log}, {"sleep", l_sleep}, {"tap", l_tap}, {"press", l_press},
    {"release", l_release}, {"dpad", l_dpad}, {"stick", l_stick}, {"type", l_type},
    {"text", l_text}, {"screen", l_screen}, {"wait", l_wait}, {"find", l_find},
    {"rule", l_rule}, {"rules", l_rules}, {"region", l_region}, {"key", l_key},
    {"capslock", l_capslock}, {NULL, NULL},
  };
  for (const luaL_Reg *r = api; r->name; r++) lua_register(L, r->name, r->func);
  lua_sethook(L, stop_hook, LUA_MASKCOUNT, 1000);

  logf_(s, "> %s", strrchr(s->path, '/') ? strrchr(s->path, '/') + 1 : s->path);
  uint32_t t0 = SDL_GetTicks();
  int rc = luaL_dofile(L, s->path);
  if (rc != LUA_OK) {
    const char *err = lua_tostring(L, -1);
    if (err && strstr(err, "stopped")) logf_(s, "stopped");
    else logf_(s, "error: %s", err ? err : "?");
  } else {
    logf_(s, "done (%.1f s)", (SDL_GetTicks() - t0) / 1000.0);
  }
  lua_close(L);
  clear_input(s);
  ocr_set_enabled(s->ocr, 0);
  ocr_set_region(s->ocr, 0, 0, 0, 0);
  atomic_store(&s->running, 0);
  return NULL;
}

/* ---------------- public ---------------- */

static int cmp_names(const void *a, const void *b) { return strcmp(a, b); }

void script_rescan(struct script *s)
{
  s->count = 0;
  DIR *d = opendir(s->dir);
  if (!d) return;
  struct dirent *e;
  while ((e = readdir(d)) && s->count < MAX_SCRIPTS) {
    size_t n = strlen(e->d_name);
    if (n > 4 && !strcmp(e->d_name + n - 4, ".lua"))
      snprintf(s->names[s->count++], sizeof s->names[0], "%s", e->d_name);
  }
  closedir(d);
  qsort(s->names, (size_t)s->count, sizeof s->names[0], cmp_names);
}

struct script *script_create(struct ocr *ocr, const char *dir)
{
  struct script *s = calloc(1, sizeof *s);
  s->ocr = ocr;
  snprintf(s->dir, sizeof s->dir, "%s", dir);
  pthread_mutex_init(&s->lock, NULL);
  s->input.hat = SV_HAT_CENTER;
  atomic_store(&s->leds, -1);
  script_rescan(s);
  return s;
}

void script_destroy(struct script *s)
{
  if (!s) return;
  script_stop(s);
  pthread_mutex_destroy(&s->lock);
  free(s);
}

int script_count(struct script *s) { return s->count; }
const char *script_name(struct script *s, int i) { return i >= 0 && i < s->count ? s->names[i] : ""; }

int script_start(struct script *s, int index)
{
  if (atomic_load(&s->running) || index < 0 || index >= s->count || !s->ocr) return -1;
  pthread_mutex_lock(&s->lock);
  snprintf(s->path, sizeof s->path, "%s/%s", s->dir, s->names[index]);
  s->nrules = 0;
  s->nhl = 0;
  s->screen[0] = 0;
  s->textq_len = 0;
  pthread_mutex_unlock(&s->lock);
  clear_input(s);
  atomic_store(&s->stop, 0);
  atomic_store(&s->running, 1);
  ocr_set_enabled(s->ocr, 1);
  if (pthread_create(&s->th, NULL, script_thread, s) != 0) {
    atomic_store(&s->running, 0);
    ocr_set_enabled(s->ocr, 0);
    return -1;
  }
  pthread_detach(s->th);
  return 0;
}

void script_stop(struct script *s)
{
  if (!atomic_load(&s->running)) return;
  atomic_store(&s->stop, 1);
  for (int i = 0; i < 200 && atomic_load(&s->running); i++) usleep(5000);
}

int script_running(struct script *s) { return atomic_load(&s->running); }

void script_get_input(struct script *s, struct link_state *out, int *active)
{
  pthread_mutex_lock(&s->lock);
  *out = s->input;
  pthread_mutex_unlock(&s->lock);
  *active = atomic_load(&s->running);
}

int script_take_text(struct script *s, char *buf, size_t len)
{
  pthread_mutex_lock(&s->lock);
  size_t n = s->textq_len < len - 1 ? s->textq_len : len - 1;
  memcpy(buf, s->textq, n);
  buf[n] = 0;
  memmove(s->textq, s->textq + n, s->textq_len - n);
  s->textq_len -= n;
  pthread_mutex_unlock(&s->lock);
  return n > 0;
}

void script_screen(struct script *s, char *buf, size_t len)
{
  pthread_mutex_lock(&s->lock);
  snprintf(buf, len, "%s", s->screen);
  pthread_mutex_unlock(&s->lock);
}

int script_log(struct script *s, char lines[][SCRIPT_LOG_COLS], int max)
{
  pthread_mutex_lock(&s->lock);
  int n = s->log_count < max ? s->log_count : max;
  int start = s->log_head + s->log_count - n;
  for (int i = 0; i < n; i++)
    memcpy(lines[i], s->log[(start + i) % SCRIPT_LOG_LINES], SCRIPT_LOG_COLS);
  pthread_mutex_unlock(&s->lock);
  return n;
}

int script_highlights(struct script *s, char words[][64], int max)
{
  pthread_mutex_lock(&s->lock);
  int n = s->nhl < max ? s->nhl : max;
  memcpy(words, s->hl, sizeof words[0] * (size_t)n);
  pthread_mutex_unlock(&s->lock);
  return n;
}

void script_set_leds(struct script *s, int leds) { atomic_store(&s->leds, leds); }
