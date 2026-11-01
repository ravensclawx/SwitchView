/* Synthetic Lua only: no capture device, network link, or user scripts. */
#include <assert.h>
#include <stdatomic.h>
#include <lauxlib.h>
#include <lua.h>

static lua_State *test_newstate(void);
#define luaL_newstate test_newstate
#include "../app/script.c"
#undef luaL_newstate

struct ocr { atomic_int enabled; };
void ocr_set_enabled(struct ocr *o, int on) { atomic_store(&o->enabled, on); }
void ocr_set_region(struct ocr *o, float x, float y, float w, float h)
{ (void)o; (void)x; (void)y; (void)w; (void)h; }
unsigned ocr_latest(struct ocr *o, char *buf, size_t len, uint32_t *started)
{ (void)o; if (buf && len) *buf = 0; if (started) *started = 0; return 0; }

static atomic_int entered, finished;
static int fail_lua_allocation;
static int native_wait(lua_State *L)
{
  (void)L;
  atomic_store(&entered, 1);
  usleep(1300000); /* Longer than the former one-second stop timeout. */
  atomic_store(&finished, 1);
  return 0;
}

static lua_State *test_newstate(void)
{
  if (fail_lua_allocation) return NULL;
  lua_State *L = luaL_newstate();
  assert(L);
  lua_register(L, "native_wait", native_wait);
  return L;
}

static void write_fixture(const char *path, const char *source)
{
  FILE *file = fopen(path, "w");
  assert(file); assert(fputs(source, file) >= 0); assert(fclose(file) == 0);
}

static void wait_idle(struct script *s)
{
  for (int i = 0; i < 2000 && script_running(s); ++i) usleep(1000);
  assert(!script_running(s));
}

int main(void)
{
  char directory[] = "/tmp/switchview-script-test-XXXXXX";
  assert(mkdtemp(directory));
  char file[1200];
  snprintf(file, sizeof file, "%s/test.lua", directory);
  struct ocr o = {0};

  write_fixture(file, "return 1\n");
  char long_name[129], long_file[1400];
  memset(long_name, 'z', 124);
  memcpy(long_name + 124, ".lua", 5); /* 128 bytes: cannot fit names[128]. */
  snprintf(long_file, sizeof long_file, "%s/%s", directory, long_name);
  write_fixture(long_file, "error('must not run truncated filename')\n");
  struct script *s = script_create(&o, directory);
  assert(s && script_count(s) == 1);
  for (int i = 0; i < 10; ++i) {
    assert(script_start(s, 0) == 0);
    wait_idle(s);
    assert(s->joinable); /* Finished threads must be reaped on restart/destroy. */
    assert(!atomic_load(&o.enabled));
  }
  fail_lua_allocation = 1;
  assert(script_start(s, 0) == 0);
  wait_idle(s);
  assert(!atomic_load(&o.enabled));
  struct link_state input;
  int active;
  script_get_input(s, &input, &active);
  assert(!active && input.buttons == 0 && input.hat == SV_HAT_CENTER);
  fail_lua_allocation = 0;
  script_destroy(s);

  write_fixture(file, "native_wait()\n");
  s = script_create(&o, directory);
  assert(s && script_start(s, 0) == 0);
  for (int i = 0; i < 2000 && !atomic_load(&entered); ++i) usleep(1000);
  assert(atomic_load(&entered));
  Uint32 before_stop = SDL_GetTicks();
  script_stop(s);
  assert(SDL_GetTicks() - before_stop < 100); /* UI stop never blocks on native work. */
  assert(script_start(s, 0) == -1); /* Cannot reuse still-running state. */
  script_destroy(s);
  assert(atomic_load(&finished)); /* The state was not freed before worker exit. */
  assert(!atomic_load(&o.enabled));

  assert(unlink(long_file) == 0);
  /* The largest representable filename remains intact and discoverable. */
  long_name[123] = '.'; memcpy(long_name + 124, "lua", 4);
  snprintf(long_file, sizeof long_file, "%s/%s", directory, long_name);
  write_fixture(long_file, "return 1\n");
  s = script_create(&o, directory);
  assert(s && script_count(s) == 2);
  assert(!strcmp(script_name(s, 1), long_name) && strlen(script_name(s, 1)) == 127);
  script_destroy(s);
  assert(unlink(long_file) == 0);
  assert(unlink(file) == 0 && rmdir(directory) == 0);
  puts("script lifecycle tests passed: restart/reap, Lua OOM, prompt stop, joined shutdown");
  return 0;
}
