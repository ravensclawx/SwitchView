// Synthetic backend regression tests: no camera, microphone, or input link.
#include "../app/capture_macos.m"
#include <assert.h>

static void test_pixels(SDL_Renderer *renderer, OSType format, uint8_t shade)
{
  struct capture *c = calloc(1, sizeof *c);
  assert(c);
  c->width = 4; c->height = 2; c->pixel_format = format;
  pthread_mutex_init(&c->frame_lock, NULL);
  pthread_cond_init(&c->frame_ready, NULL);
  pthread_mutex_init(&c->luma_lock, NULL);
  pthread_mutex_init(&c->audio_lock, NULL);
  c->luma = malloc(8);
  assert(c->luma);
  // Deliberately poison global mode so texture creation must select the correct one.
  SDL_SetYUVConversionMode(SDL_YUV_CONVERSION_BT709);
  c->tex = create_texture(renderer, format, 4, 2);
  assert(c->tex);
  CVPixelBufferRef image = NULL;
  assert(CVPixelBufferCreate(NULL, 4, 2, format, NULL, &image) == kCVReturnSuccess);
  assert(CVPixelBufferLockBaseAddress(image, 0) == kCVReturnSuccess);
  int planar = CVPixelBufferIsPlanar(image);
  uint8_t *pixels = planar ? CVPixelBufferGetBaseAddressOfPlane(image, 0) : CVPixelBufferGetBaseAddress(image);
  size_t stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(image, 0) : CVPixelBufferGetBytesPerRow(image);
  for (unsigned y = 0; y < 2; ++y) {
    uint8_t *row = pixels + y * stride;
    for (unsigned x = 0; x < 4; ++x) {
      if (planar) row[x] = shade;
      else if (format == kCVPixelFormatType_32BGRA) {
        row[4*x] = row[4*x+1] = row[4*x+2] = shade; row[4*x+3] = 255;
      } else if (format == kCVPixelFormatType_422YpCbCr8_yuvs) { row[2*x] = shade; row[2*x+1] = 128; }
      else { row[2*x] = 128; row[2*x+1] = shade; }
    }
  }
  if (planar) memset(CVPixelBufferGetBaseAddressOfPlane(image, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(image, 1));
  CVPixelBufferUnlockBaseAddress(image, 0);
  c->latest = image; c->frame_seq = 1;
  uint8_t luma[8] = {0};
  assert(capture_copy_luma(c, luma) == 0);
  capture_want_luma(c);
  assert(capture_poll(c, 0) == 1);
  assert(capture_copy_luma(c, luma) == 1);
  for (int i = 0; i < 8; ++i) assert(luma[i] == shade);
  assert(capture_poll(c, 1) == 0);
  SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
  assert(SDL_RenderClear(renderer) == 0);
  assert(SDL_RenderCopy(renderer, c->tex, NULL, NULL) == 0);
  uint8_t rgb[4 * 2 * 4];
  assert(SDL_RenderReadPixels(renderer, NULL, SDL_PIXELFORMAT_RGBA32, rgb, 16) == 0);
  int full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_32BGRA;
  int expected = full ? shade : (int)((shade - 16) * 255.0 / 219.0 + 0.5);
  if (expected < 0) expected = 0;
  if (expected > 255) expected = 255;
  for (int i = 0; i < 8; ++i)
    for (int channel = 0; channel < 3; ++channel) assert(abs((int)rgb[4*i+channel] - expected) <= 3);
  capture_set_muted(c, 1); assert(capture_muted(c));
  capture_set_muted(c, 0); assert(!capture_muted(c));
  capture_close(c);
}

static void test_color_matrices(SDL_Renderer *renderer)
{
  // Independent RGB references for Y=128, Cb=90, Cr=180. JPEG uses full-range
  // coefficients; BT.601/709 use studio-range Y scaling (255/219). The expected
  // bytes are rounded from their published matrix equations, not SDL output.
  const struct {
    OSType format;
    unsigned height;
    uint8_t rgb[3];
  } cases[] = {
    {kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 2, {201, 104, 61}},
    {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 2, {213, 103, 54}},
    {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 720, {224, 111, 50}}
  };
  // Recreate in alternating order: a texture must not inherit its predecessor's
  // cached conversion matrix. Tall BT.709 textures are scaled into the 4x2 view.
  const unsigned order[] = {2, 0, 1, 0, 2, 1};
  for (unsigned run = 0; run < sizeof order / sizeof order[0]; ++run) {
    unsigned index = order[run];
    size_t y_size = 4 * cases[index].height;
    uint8_t *y = malloc(y_size), *uv = malloc(y_size / 2);
    assert(y && uv);
    memset(y, 128, y_size);
    for (size_t i = 0; i < y_size / 2; i += 2) { uv[i] = 90; uv[i + 1] = 180; }
    SDL_Texture *texture = create_texture(renderer, cases[index].format, 4, cases[index].height);
    assert(texture);
    assert(SDL_UpdateNVTexture(texture, NULL, y, 4, uv, 4) == 0);
    SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    assert(SDL_RenderClear(renderer) == 0);
    assert(SDL_RenderCopy(renderer, texture, NULL, NULL) == 0);
    uint8_t rgb[4 * 2 * 4];
    assert(SDL_RenderReadPixels(renderer, NULL, SDL_PIXELFORMAT_RGBA32, rgb, 16) == 0);
    for (unsigned pixel = 0; pixel < 8; ++pixel)
      for (unsigned channel = 0; channel < 3; ++channel)
        assert(abs((int)rgb[4 * pixel + channel] - cases[index].rgb[channel]) <= 3);
    SDL_DestroyTexture(texture);
    free(uv); free(y);
  }
}

static const char *fixture_name(int index, int capture)
{
  assert(capture == 1);
  const char *names[] = {"Card", NULL, "Other", "Card"};
  return names[index];
}

static void test_selection_and_wait(void)
{
  assert(unique_audio_index("Card", 4, fixture_name) == -2);
  assert(unique_audio_index("Card", 3, fixture_name) == 0);
  assert(unique_audio_index("Other", 4, fixture_name) == 2);
  assert(unique_audio_index("missing", 4, fixture_name) == -1);
  const int rates[] = {24, 30, 60, 120, 240};
  for (unsigned i = 0; i < sizeof rates / sizeof rates[0]; ++i) {
    double ntsc = rates[i] * 1000.0 / 1001.0;
    assert(!rate_in_range(rates[i], ntsc, ntsc));
    assert(rate_in_range(nominal_fractional_rate(rates[i]), ntsc, ntsc));
    assert(rate_in_range(rates[i], rates[i], rates[i]));
  }
  assert(nominal_fractional_rate(25) == 0);
  assert(rate_in_range(30, 30.00003, 30.00003));
  assert(!rate_in_range(30, 29, 29));
  struct timespec remaining;
  assert(remaining_wait((struct timespec){2, 100}, (struct timespec){1, 900000000}, &remaining));
  assert(remaining.tv_sec == 0 && remaining.tv_nsec == 100000100);
  assert(!remaining_wait((struct timespec){2, 100}, (struct timespec){2, 100}, &remaining));
  assert(!remaining_wait((struct timespec){2, 100}, (struct timespec){3, 0}, &remaining));
}

static void deliver(SVCaptureReceiver *receiver, CVPixelBufferRef image)
{
  CMVideoFormatDescriptionRef format = NULL;
  CMSampleBufferRef sample = NULL;
  assert(CMVideoFormatDescriptionCreateForImageBuffer(NULL, image, &format) == noErr);
  CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeZero, kCMTimeInvalid};
  assert(CMSampleBufferCreateReadyWithImageBuffer(NULL, image, format, &timing, &sample) == noErr);
  // The delegate does not use these objects; keep the fixture device-free.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
  [receiver captureOutput:nil didOutputSampleBuffer:sample fromConnection:nil];
#pragma clang diagnostic pop
  CFRelease(sample); CFRelease(format);
}

static void test_latest_frame(void)
{
  struct capture c = {0};
  c.width = 4; c.height = 2; c.pixel_format = kCVPixelFormatType_32BGRA;
  pthread_mutex_init(&c.frame_lock, NULL); pthread_cond_init(&c.frame_ready, NULL);
  SVCaptureReceiver *receiver = [SVCaptureReceiver new]; receiver.capture = &c;
  CVPixelBufferRef first = NULL, second = NULL, wrong = NULL;
  assert(CVPixelBufferCreate(NULL, 4, 2, c.pixel_format, NULL, &first) == kCVReturnSuccess);
  assert(CVPixelBufferCreate(NULL, 4, 2, c.pixel_format, NULL, &second) == kCVReturnSuccess);
  assert(CVPixelBufferCreate(NULL, 8, 2, c.pixel_format, NULL, &wrong) == kCVReturnSuccess);
  deliver(receiver, first); assert(c.frame_seq == 1 && c.latest == first);
  deliver(receiver, second); assert(c.frame_seq == 2 && c.latest == second);
  deliver(receiver, wrong); assert(c.frame_seq == 2 && c.latest == second && atomic_load(&c.frame_error));
  c.frame_seq = UINT_MAX; deliver(receiver, first); assert(c.frame_seq == 1);
  atomic_store(&c.closing, 1); deliver(receiver, second); assert(c.frame_seq == 1 && c.latest == first);
  receiver.capture = NULL;
  CVPixelBufferRelease(c.latest); CVPixelBufferRelease(first); CVPixelBufferRelease(second); CVPixelBufferRelease(wrong);
  pthread_cond_destroy(&c.frame_ready); pthread_mutex_destroy(&c.frame_lock);
}

int main(void)
{
  test_selection_and_wait();
  test_latest_frame();
  long index = -1;
  assert(decimal_index("0", &index) == 1 && index == 0);
  assert(decimal_index("999999999999999999999999999", &index) == -1);
  assert(decimal_index("device", &index) == 0);
  assert(capture_open(NULL, NULL) == NULL);
  capture_close(NULL);
  assert(SDL_Init(SDL_INIT_VIDEO) == 0);
  SDL_Window *window = SDL_CreateWindow("Backend regression", 0, 0, 4, 2, SDL_WINDOW_HIDDEN);
  assert(window);
  SDL_Renderer *renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
  assert(renderer);
  const OSType formats[] = {kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8_yuvs,
    kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_32BGRA};
  for (unsigned i = 0; i < sizeof formats / sizeof formats[0]; ++i)
    for (unsigned shade = 0; shade < 3; ++shade) {
      const uint8_t shades[] = {0, 32, 255};
      test_pixels(renderer, formats[i], shades[shade]);
    }
  test_color_matrices(renderer);
  SDL_DestroyRenderer(renderer); SDL_DestroyWindow(window); SDL_Quit();
  puts("macOS backend: rates, audio selection, monotonic wait, latest-frame ownership and 15 grayscale/cleanup cases and 6 non-neutral color-matrix cases passed");
  return 0;
}
