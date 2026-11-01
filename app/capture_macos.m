// AVFoundation video and SDL/CoreAudio audio. The render thread owns SDL textures.
#include "capture.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct capture {
  void *owner;                       // Retained SVCaptureReceiver; released in close.
  unsigned width, height;
  OSType pixel_format;
  SDL_Texture *tex;
  pthread_mutex_t frame_lock;
  pthread_cond_t frame_ready;
  CVPixelBufferRef latest;
  unsigned frame_seq, uploaded_seq;
  atomic_int closing, frame_error;
  pthread_mutex_t luma_lock;
  uint8_t *luma;
  unsigned luma_seq;
  atomic_int luma_wanted;
  SDL_AudioDeviceID in, out;
  unsigned audio_bytes_per_second, max_audio_bytes;
  int have_audio;
  pthread_mutex_t audio_lock;
  atomic_int muted;
};

@interface SVCaptureReceiver : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureVideoDataOutput *output;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, assign) struct capture *capture;
@end

@implementation SVCaptureReceiver
- (void)captureOutput:(AVCaptureOutput *)output
 didOutputSampleBuffer:(CMSampleBufferRef)sample
       fromConnection:(AVCaptureConnection *)connection
{
  (void)output; (void)connection;
  struct capture *c = self.capture;
  if (!c || atomic_load(&c->closing)) return;
  CVPixelBufferRef image = CMSampleBufferGetImageBuffer(sample);
  if (!image) return;
  if (CVPixelBufferGetWidth(image) != c->width ||
      CVPixelBufferGetHeight(image) != c->height ||
      CVPixelBufferGetPixelFormatType(image) != c->pixel_format) {
    if (!atomic_exchange(&c->frame_error, 1))
      fprintf(stderr, "video: capture format changed; reopen the device with its current mode\n");
    return;
  }
  CVPixelBufferRetain(image);
  pthread_mutex_lock(&c->frame_lock);
  CVPixelBufferRef old = c->latest;
  c->latest = image;
  if (++c->frame_seq == 0) ++c->frame_seq;
  pthread_cond_signal(&c->frame_ready);
  pthread_mutex_unlock(&c->frame_lock);
  if (old) CVPixelBufferRelease(old);
}
@end

static NSArray<AVCaptureDevice *> *video_devices(void)
{
  if (@available(macOS 14.0, *)) {
    return [AVCaptureDeviceDiscoverySession
      discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternal,
                                         AVCaptureDeviceTypeBuiltInWideAngleCamera]
                            mediaType:AVMediaTypeVideo
                             position:AVCaptureDevicePositionUnspecified].devices;
  }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  return [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
#pragma clang diagnostic pop
}

void capture_list_devices(void)
{
  @autoreleasepool {
    NSArray<AVCaptureDevice *> *devices = video_devices();
    fprintf(stderr, "AVFoundation video devices (-d index, exact name, or UID):\n");
    for (NSUInteger i = 0; i < devices.count; ++i)
      fprintf(stderr, "  %lu: %s [UID: %s]\n", (unsigned long)i,
              devices[i].localizedName.UTF8String, devices[i].uniqueID.UTF8String);
    if (!devices.count) fprintf(stderr, "  no video devices found\n");
    fprintf(stderr, "SDL audio capture devices (-a index or exact name):\n");
    int count = SDL_GetNumAudioDevices(1);
    for (int i = 0; i < count; ++i)
      fprintf(stderr, "  %d: %s\n", i, SDL_GetAudioDeviceName(i, 1));
    if (count <= 0) fprintf(stderr, "  no audio capture devices found\n");
  }
}

static int decimal_index(const char *name, long *index)
{
  if (!name || !*name) return 0;
  for (const char *p = name; *p; ++p) if (*p < '0' || *p > '9') return 0;
  char *end;
  errno = 0;
  long value = strtol(name, &end, 10);
  if (errno || *end || value < 0) return -1;
  *index = value;
  return 1;
}

static AVCaptureDevice *select_video(const char *selector)
{
  NSArray<AVCaptureDevice *> *devices = video_devices();
  if (!selector || !*selector) selector = "0";
  long index;
  int numeric = decimal_index(selector, &index);
  if (numeric)
    return numeric > 0 && (NSUInteger)index < devices.count ? devices[(NSUInteger)index] : nil;
  NSString *name = [NSString stringWithUTF8String:selector];
  for (AVCaptureDevice *device in devices)
    if ([device.uniqueID isEqualToString:name]) return device;
  AVCaptureDevice *match = nil;
  for (AVCaptureDevice *device in devices) {
    if (![device.localizedName isEqualToString:name]) continue;
    if (match) {
      fprintf(stderr, "video: device name is ambiguous; use its UID or index\n");
      return nil;
    }
    match = device;
  }
  return match;
}

static int video_authorized(void)
{
  AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  if (status == AVAuthorizationStatusAuthorized) return 1;
  if (status == AVAuthorizationStatusNotDetermined) {
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
      (void)granted;
      dispatch_semaphore_signal(answered);
    }];
    // Keep the main run loop responsive while macOS presents its camera prompt.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    while (dispatch_semaphore_wait(answered, DISPATCH_TIME_NOW) != 0) {
      if (deadline.timeIntervalSinceNow <= 0) {
        fprintf(stderr, "video: camera permission is pending; grant it and launch again\n");
        return 0;
      }
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  }
  if (status != AVAuthorizationStatusAuthorized) {
    fprintf(stderr, "video: camera access denied; enable it in System Settings > Privacy & Security > Camera\n");
    return 0;
  }
  return 1;
}

static AVCaptureDeviceFormat *select_format(AVCaptureDevice *device, const struct capture_opts *o,
                                             AVFrameRateRange **selected_range)
{
  for (AVCaptureDeviceFormat *format in device.formats) {
    CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    if (size.width != o->width || size.height != o->height) continue;
    for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges)
      if (o->fps >= range.minFrameRate - 0.001 && o->fps <= range.maxFrameRate + 0.001) {
        *selected_range = range;
        return format;
      }
  }
  fprintf(stderr, "video: %s does not support %dx%d at %d fps; available modes:\n",
          device.localizedName.UTF8String, o->width, o->height, o->fps);
  for (AVCaptureDeviceFormat *format in device.formats) {
    CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges)
      fprintf(stderr, "  %dx%d %.3f..%.3f fps\n", size.width, size.height,
              range.minFrameRate, range.maxFrameRate);
  }
  return nil;
}

static OSType output_format(AVCaptureVideoDataOutput *output, unsigned requested)
{
  // FourCC YUYV is platform independent; AVFoundation calls this layout yuvs.
  const unsigned yuyv = (unsigned)'Y' | (unsigned)'U' << 8 | (unsigned)'Y' << 16 | (unsigned)'V' << 24;
  OSType first = requested == yuyv ? kCVPixelFormatType_422YpCbCr8_yuvs
                                 : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  OSType choices[] = {first, kCVPixelFormatType_422YpCbCr8,
                     kCVPixelFormatType_32BGRA,
                     kCVPixelFormatType_420YpCbCr8BiPlanarFullRange};
  for (unsigned i = 0; i < sizeof choices / sizeof choices[0]; ++i)
    if ([output.availableVideoCVPixelFormatTypes containsObject:@(choices[i])]) return choices[i];
  return 0;
}

static Uint32 texture_format(OSType format)
{
  if (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
      format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) return SDL_PIXELFORMAT_NV12;
  if (format == kCVPixelFormatType_422YpCbCr8_yuvs) return SDL_PIXELFORMAT_YUY2;
  if (format == kCVPixelFormatType_422YpCbCr8) return SDL_PIXELFORMAT_UYVY;
  return SDL_PIXELFORMAT_BGRA32;
}

static void audio_callback(void *data, Uint8 *stream, int len)
{
  struct capture *c = data;
  pthread_mutex_lock(&c->audio_lock);
  if (!atomic_load(&c->muted) && !atomic_load(&c->closing) && c->out && len > 0) {
    Uint32 queued = SDL_GetQueuedAudioSize(c->out);
    Uint32 available = queued < c->max_audio_bytes ? c->max_audio_bytes - queued : 0;
    Uint32 bytes = (Uint32)len < available ? (Uint32)len : available;
    bytes -= bytes % 4;              // S16 stereo frame alignment.
    if (bytes) SDL_QueueAudio(c->out, stream, bytes);
  }
  pthread_mutex_unlock(&c->audio_lock);
}

static const char *audio_name(const char *selector, const char *video_name, int *valid)
{
  *valid = 1;
  if (selector && !strcmp(selector, "default")) return NULL;
  int count = SDL_GetNumAudioDevices(1);
  if (!selector || !*selector || !strcmp(selector, "auto")) {
    for (int i = 0; i < count; ++i) {
      const char *name = SDL_GetAudioDeviceName(i, 1);
      if (name && !strcmp(name, video_name)) return name;
    }
    fprintf(stderr, "audio: select a capture-card input with -a (use device listing); automatic match unavailable\n");
    *valid = 0;
    return NULL;
  }
  long index;
  int numeric = decimal_index(selector, &index);
  if (numeric) {
    if (numeric > 0 && index < count) return SDL_GetAudioDeviceName((int)index, 1);
  } else {
    for (int i = 0; i < count; ++i) {
      const char *name = SDL_GetAudioDeviceName(i, 1);
      if (name && !strcmp(name, selector)) return name;
    }
  }
  fprintf(stderr, "audio: input '%s' not found; use device listing\n", selector);
  *valid = 0;
  return NULL;
}

static int audio_start(struct capture *c, const struct capture_opts *o, const char *video_name)
{
  int valid;
  const char *name = audio_name(o->audio_dev, video_name, &valid);
  if (!valid) return -1;
  SDL_AudioSpec want = {0}, have;
  want.freq = 48000;
  want.format = AUDIO_S16SYS;
  want.channels = 2;
  want.samples = 256;
  want.callback = audio_callback;
  want.userdata = c;
  c->in = SDL_OpenAudioDevice(name, 1, &want, &have, SDL_AUDIO_ALLOW_FREQUENCY_CHANGE);
  if (!c->in) {
    fprintf(stderr, "audio: capture open: %s\n", SDL_GetError());
    return -1;
  }
  want = have;
  want.callback = NULL;
  want.userdata = NULL;
  c->out = SDL_OpenAudioDevice(NULL, 0, &want, NULL, 0);
  if (!c->out) {
    fprintf(stderr, "audio: output open: %s\n", SDL_GetError());
    SDL_CloseAudioDevice(c->in);
    c->in = 0;
    return -1;
  }
  c->audio_bytes_per_second = (unsigned)have.freq * 4;
  c->max_audio_bytes = (unsigned)((uint64_t)c->audio_bytes_per_second * o->audio_max_ms / 1000);
  c->max_audio_bytes -= c->max_audio_bytes % 4;
  fprintf(stderr, "audio: %s, %d Hz stereo, queue capped at %d ms\n",
          name ? name : "default", have.freq, o->audio_max_ms);
  SDL_PauseAudioDevice(c->out, 0);
  SDL_PauseAudioDevice(c->in, 0);
  return 0;
}

struct capture *capture_open(const struct capture_opts *o, SDL_Renderer *ren)
{
  @autoreleasepool {
    if (!o || !ren || o->width <= 0 || o->height <= 0 || o->width > 16384 ||
        o->height > 16384 || o->fps <= 0 || o->fps > 1000 ||
        (!o->no_audio && (o->audio_max_ms <= 0 || o->audio_max_ms > 4000))) {
      fprintf(stderr, "capture: invalid dimensions, frame rate, or audio queue limit\n");
      return NULL;
    }
    AVCaptureDevice *device = select_video(o->video_dev);
    if (!device) {
      fprintf(stderr, "video: device '%s' not found; use device listing\n", o->video_dev ?: "0");
      return NULL;
    }
    if (!video_authorized()) return NULL;
    AVFrameRateRange *frame_range = nil;
    AVCaptureDeviceFormat *format = select_format(device, o, &frame_range);
    if (!format) return NULL;
    // Capture devices may advertise nominal 30 Hz as 30.00003. Select with
    // tolerance, then assign an exact supported rational duration, not 1/30.
    CMTime frame_duration = CMTimeMake(1, o->fps);
    if (CMTimeCompare(frame_duration, frame_range.minFrameDuration) < 0)
      frame_duration = frame_range.minFrameDuration;
    if (CMTimeCompare(frame_duration, frame_range.maxFrameDuration) > 0)
      frame_duration = frame_range.maxFrameDuration;
    struct capture *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->width = (unsigned)o->width;
    c->height = (unsigned)o->height;
    pthread_mutex_init(&c->frame_lock, NULL);
    pthread_cond_init(&c->frame_ready, NULL);
    pthread_mutex_init(&c->luma_lock, NULL);
    pthread_mutex_init(&c->audio_lock, NULL);
    c->luma = malloc((size_t)c->width * c->height);
    if (!c->luma) { capture_close(c); return NULL; }

    SVCaptureReceiver *receiver = [SVCaptureReceiver new];
    receiver.capture = c;
    receiver.session = [AVCaptureSession new];
    receiver.output = [AVCaptureVideoDataOutput new];
    receiver.queue = dispatch_queue_create("org.switchview.capture", DISPATCH_QUEUE_SERIAL);
    c->owner = (__bridge_retained void *)receiver;
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input) {
      fprintf(stderr, "video: input: %s\n", error.localizedDescription.UTF8String);
      capture_close(c);
      return NULL;
    }
    [receiver.session beginConfiguration];
    if (![receiver.session canAddInput:input]) {
      fprintf(stderr, "video: session rejected input\n");
      [receiver.session commitConfiguration];
      capture_close(c);
      return NULL;
    }
    [receiver.session addInput:input];
    if (![device lockForConfiguration:&error]) {
      fprintf(stderr, "video: configuration: %s\n", error.localizedDescription.UTF8String);
      [receiver.session commitConfiguration];
      capture_close(c);
      return NULL;
    }
    BOOL configured = YES;
    @try {
      device.activeFormat = format;
      device.activeVideoMinFrameDuration = frame_duration;
      device.activeVideoMaxFrameDuration = frame_duration;
    } @catch (NSException *exception) {
      fprintf(stderr, "video: requested mode rejected: %s\n", exception.reason.UTF8String);
      configured = NO;
    }
    [device unlockForConfiguration];
    c->pixel_format = output_format(receiver.output, o->fourcc);
    if (!configured || !c->pixel_format || ![receiver.session canAddOutput:receiver.output]) {
      if (configured) fprintf(stderr, "video: compatible video output unavailable\n");
      [receiver.session commitConfiguration];
      capture_close(c);
      return NULL;
    }
    receiver.output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(c->pixel_format)};
    receiver.output.alwaysDiscardsLateVideoFrames = YES;
    [receiver.output setSampleBufferDelegate:receiver queue:receiver.queue];
    [receiver.session addOutput:receiver.output];
    [receiver.session commitConfiguration];
    c->tex = SDL_CreateTexture(ren, texture_format(c->pixel_format), SDL_TEXTUREACCESS_STREAMING,
                               o->width, o->height);
    if (!c->tex) {
      fprintf(stderr, "video: SDL texture: %s\n", SDL_GetError());
      capture_close(c);
      return NULL;
    }
    SDL_SetYUVConversionMode(c->pixel_format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                            ? SDL_YUV_CONVERSION_JPEG
                            : (c->height > 576 ? SDL_YUV_CONVERSION_BT709 : SDL_YUV_CONVERSION_BT601));
    @try {
      [receiver.session startRunning];
    } @catch (NSException *exception) {
      fprintf(stderr, "video: start failed: %s\n", exception.reason.UTF8String);
    }
    if (!receiver.session.isRunning) {
      fprintf(stderr, "video: capture session did not start\n");
      capture_close(c);
      return NULL;
    }
    fprintf(stderr, "video: %s %ux%u @ %.6f fps (requested %d), AVFoundation pixel format 0x%08x\n",
            device.localizedName.UTF8String, c->width, c->height,
            1.0 / CMTimeGetSeconds(frame_duration), o->fps, (unsigned)c->pixel_format);
    c->have_audio = !o->no_audio && audio_start(c, o, device.localizedName.UTF8String) == 0;
    return c;
  }
}

void capture_close(struct capture *c)
{
  if (!c) return;
  @autoreleasepool {
    atomic_store(&c->closing, 1);
    SVCaptureReceiver *receiver = (__bridge SVCaptureReceiver *)c->owner;
    if (receiver) {
      [receiver.session stopRunning];
      [receiver.output setSampleBufferDelegate:nil queue:NULL];
      // stopRunning plus draining the serial callback queue prevents callbacks
      // from retaining the C state after it is freed.
      dispatch_sync(receiver.queue, ^{});
      receiver.capture = NULL;
    }
    if (c->in) SDL_CloseAudioDevice(c->in);  // Joins the capture callback before output closes.
    if (c->out) SDL_CloseAudioDevice(c->out);
    if (c->latest) CVPixelBufferRelease(c->latest);
    if (c->tex) SDL_DestroyTexture(c->tex);
    free(c->luma);
    pthread_mutex_destroy(&c->audio_lock);
    pthread_mutex_destroy(&c->luma_lock);
    pthread_cond_destroy(&c->frame_ready);
    pthread_mutex_destroy(&c->frame_lock);
    if (c->owner) {
      id retained = CFBridgingRelease(c->owner);
      c->owner = NULL;
      (void)retained;
    }
    free(c);
  }
}

int capture_poll(struct capture *c, int timeout_ms)
{
  pthread_mutex_lock(&c->frame_lock);
  if (timeout_ms > 0 && c->frame_seq == c->uploaded_seq) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += timeout_ms / 1000;
    deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) { ++deadline.tv_sec; deadline.tv_nsec -= 1000000000L; }
    while (c->frame_seq == c->uploaded_seq && !atomic_load(&c->closing))
      if (pthread_cond_timedwait(&c->frame_ready, &c->frame_lock, &deadline) != 0) break;
  }
  CVPixelBufferRef image = c->frame_seq != c->uploaded_seq ? c->latest : NULL;
  if (image) {
    CVPixelBufferRetain(image);
    c->uploaded_seq = c->frame_seq;
  }
  pthread_mutex_unlock(&c->frame_lock);
  if (!image) return 0;
  if (CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
    CVPixelBufferRelease(image);
    return 0;
  }
  int planar = CVPixelBufferIsPlanar(image);
  const uint8_t *pixels = planar ? CVPixelBufferGetBaseAddressOfPlane(image, 0)
                                : CVPixelBufferGetBaseAddress(image);
  size_t stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(image, 0)
                         : CVPixelBufferGetBytesPerRow(image);
  int result = -1;
  if (pixels && stride <= INT_MAX) {
    if (atomic_exchange(&c->luma_wanted, 0)) {
      pthread_mutex_lock(&c->luma_lock);
      for (unsigned y = 0; y < c->height; ++y) {
        const uint8_t *row = pixels + (size_t)y * stride;
        uint8_t *out = c->luma + (size_t)y * c->width;
        if (planar) memcpy(out, row, c->width);
        else if (c->pixel_format == kCVPixelFormatType_422YpCbCr8_yuvs)
          for (unsigned x = 0; x < c->width; ++x) out[x] = row[2 * x];
        else if (c->pixel_format == kCVPixelFormatType_422YpCbCr8)
          for (unsigned x = 0; x < c->width; ++x) out[x] = row[2 * x + 1];
        else
          for (unsigned x = 0; x < c->width; ++x)
            out[x] = (uint8_t)((29u * row[4*x] + 150u * row[4*x+1] + 77u * row[4*x+2]) >> 8);
      }
      if (++c->luma_seq == 0) ++c->luma_seq;
      pthread_mutex_unlock(&c->luma_lock);
    }
    if (planar && CVPixelBufferGetPlaneCount(image) == 2 &&
        CVPixelBufferGetBytesPerRowOfPlane(image, 1) <= INT_MAX)
      result = SDL_UpdateNVTexture(c->tex, NULL, pixels, (int)stride,
                                  CVPixelBufferGetBaseAddressOfPlane(image, 1),
                                  (int)CVPixelBufferGetBytesPerRowOfPlane(image, 1));
    else if (!planar) result = SDL_UpdateTexture(c->tex, NULL, pixels, (int)stride);
  }
  CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
  CVPixelBufferRelease(image);
  if (result < 0 && !atomic_exchange(&c->frame_error, 1))
    fprintf(stderr, "video: texture upload failed: %s\n", SDL_GetError());
  return result == 0;
}

SDL_Texture *capture_texture(struct capture *c) { return c->tex; }
unsigned capture_width(struct capture *c) { return c->width; }
unsigned capture_height(struct capture *c) { return c->height; }
int capture_has_audio(struct capture *c) { return c->have_audio; }
double capture_audio_queued_ms(struct capture *c)
{
  return c->have_audio && c->audio_bytes_per_second
       ? 1000.0 * SDL_GetQueuedAudioSize(c->out) / c->audio_bytes_per_second : 0.0;
}
void capture_set_muted(struct capture *c, int muted)
{
  pthread_mutex_lock(&c->audio_lock);
  atomic_store(&c->muted, muted != 0);
  if (muted && c->out) SDL_ClearQueuedAudio(c->out);
  pthread_mutex_unlock(&c->audio_lock);
}
int capture_muted(struct capture *c) { return atomic_load(&c->muted); }
void capture_want_luma(struct capture *c) { atomic_store(&c->luma_wanted, 1); }
unsigned capture_copy_luma(struct capture *c, uint8_t *dst)
{
  pthread_mutex_lock(&c->luma_lock);
  unsigned sequence = c->luma_seq;
  if (sequence && dst) memcpy(dst, c->luma, (size_t)c->width * c->height);
  pthread_mutex_unlock(&c->luma_lock);
  return sequence;
}
