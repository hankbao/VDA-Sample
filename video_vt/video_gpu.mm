// Sample code to play a video file using hardware decoding.
// This is free software released into the public domain.

#import <Cocoa/Cocoa.h>
#include <VideoToolbox/VideoToolbox.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>
}
#include <list>
#import "IOSurfaceTestView.h"
#include "util.h"

const int MAX_DECODE_QUEUE_SIZE = 5;
const int MAX_PLAY_QUEUE_SIZE = 5;

static void CFDictionarySetSInt32(CFMutableDictionaryRef dictionary,
                                  CFStringRef key,
                                  SInt32 numberSInt32)
{
  CFNumberRef number;

  number = CFNumberCreate(NULL, kCFNumberSInt32Type, &numberSInt32);
  CFDictionarySetValue(dictionary, key, number);
  CFRelease(number);
}

static CMFormatDescriptionRef
CreateFormatDescriptionFromCodecData(CMVideoCodecType format_id,
                                     int width,
                                     int height,
                                     const uint8_t *extradata,
                                     int extradata_size)
{
    CMFormatDescriptionRef fmt_desc;

    /* SampleDescriptionExtensionAtoms dict */
    CFMutableDictionaryRef atoms = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDataRef atomsData = CFDataCreate(NULL, extradata, extradata_size);
    CFDictionarySetValue(atoms, CFSTR("avcC"), atomsData);
    CFRelease(atomsData);

    /* Extensions dict */
    CFMutableDictionaryRef extensions = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(extensions, CFSTR("SampleDescriptionExtensionAtoms"), atoms);

    OSStatus status = CMVideoFormatDescriptionCreate(
        NULL,
        format_id,
        width,
        height,
        extensions,
        &fmt_desc);

    if (status == noErr)
        return fmt_desc;
    else
        return NULL;
}

class GPUDecoder {
 public:
  struct DecodedImage {
    CVImageBufferRef image;
    int64_t display_time;
  };

  GPUDecoder() : vt_session_(NULL),
                 format_(NULL),
                 pending_image_count_(0),
                 is_waiting_(false) {
    assert(pthread_mutex_init(&mutex_, NULL) == 0);
    assert(pthread_cond_init(&frame_ready_condition_, NULL) == 0);
  }

  ~GPUDecoder() {
    pthread_mutex_destroy(&mutex_);
    pthread_cond_destroy(&frame_ready_condition_);
    VTDecompressionSessionInvalidate(vt_session_);
    CFRelease(vt_session_);
    CFRelease(format_);
  }

  void Create(int width, int height, OSType source_format,
              uint8_t* avc_bytes, int avc_size) {
    CFMutableDictionaryRef destinationPixelBufferAttributes =
        CFDictionaryCreateMutable(NULL, // CFAllocatorRef allocator
                                  0,    // CFIndex capacity
                                  &kCFTypeDictionaryKeyCallBacks,
                                  &kCFTypeDictionaryValueCallBacks);
    // The recommended pixel format choices are
    //   kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange or
    //   kCVPixelFormatType_32BGRA.
    CFDictionarySetSInt32(destinationPixelBufferAttributes,
                          kCVPixelBufferPixelFormatTypeKey,
                          kCVPixelFormatType_32BGRA);
    CFDictionarySetSInt32(destinationPixelBufferAttributes,
                          kCVPixelBufferWidthKey,
                          width);
    CFDictionarySetSInt32(destinationPixelBufferAttributes,
                          kCVPixelBufferHeightKey,
                          height);

    VTDecompressionOutputCallbackRecord outputCallback =
        { VTDecoderCallback, this };

    format_ = CreateFormatDescriptionFromCodecData(
        kCMVideoCodecType_H264,
        width, height, avc_bytes, avc_size);
    fprintf(stderr, "CreateFormat: %p\n", format_);

    OSStatus status = VTDecompressionSessionCreate(
        NULL, // CFAllocatorRef allocator
        format_,
        NULL, // videoDecoderSpecification
        destinationPixelBufferAttributes,
        &outputCallback,
        &vt_session_);
    assert(status == noErr);

    assert(avc_bytes);
  }

  void DecodeNextFrame(uint8_t* bytes, int size, int64_t display_time) {
    {
      ScopedLock lock(&mutex_);
      pending_image_count_++;
    }
    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        NULL,  // allocator
        bytes, // memoryBlock
        size,  // blockLength,
        NULL,  // blockAllocator
        NULL,  // customBlockSource
        0,     // offsetToData
        size,  // dataLength
        FALSE,    // flags
        &block);  // newBBufOut
    assert(status == noErr);

    CMSampleBufferRef buffer = NULL;
    status = CMSampleBufferCreate(
        NULL,  // allocator
        block, // dataBuffer
        TRUE,  // dataReady
        NULL,  // makeDataReadyCallback,
        NULL,  // makeDataReadyRefcon
        format_,  // formatDescription
        1,        // numSamples
        0,        // numSampleTimingEntries
        NULL,     // sampleTimingArray
        0,        // numSampleSizeEntries
        NULL,     // sampleSizeArray
        &buffer);
    assert(status == noErr);
    CFRelease(block);

    VTDecodeInfoFlags flags;
    status = VTDecompressionSessionDecodeFrame(
        vt_session_,
        buffer,
        kVTDecodeFrame_EnableAsynchronousDecompression |
        kVTDecodeFrame_EnableTemporalProcessing,
        &buffer,
        &flags);
    assert(status == noErr);

    /* Flush in-process frames. */
    VTDecompressionSessionFinishDelayedFrames(vt_session_);
    /* Block until our callback has been called with the last frame. */
    VTDecompressionSessionWaitForAsynchronousFrames(vt_session_);
  }

  int GetDecodedImageCount() {
    ScopedLock lock(&mutex_);
    return images_.size();
  }

  DecodedImage GetNextDecodedImage() {
    ScopedLock lock(&mutex_);
    return images_.front();
  }

  DecodedImage PopNextDecodedImage() {
    ScopedLock lock(&mutex_);
    DecodedImage image = images_.front();
    images_.pop_front();
    return image;
  }

  void WaitForDecodedImage() {
    ScopedLock lock(&mutex_);
    is_waiting_ = true;
    pthread_cond_wait(&frame_ready_condition_, &mutex_);
    is_waiting_ = false;
  }

  int pending_image_count() {
    ScopedLock lock(&mutex_);
    return pending_image_count_;
  }

 private:
  static void VTDecoderCallback(
      void* decompressionOutputRefCon,
      void* sourceFrameRefCon,
      OSStatus status,
      VTDecodeInfoFlags info,
      CVImageBufferRef imageBuffer,
      CMTime presentationTimeStamp,
      CMTime presentationDuration)
  {
    if (status != noErr || !imageBuffer) {
      fprintf(stderr, "Error %d decoding frame!\n", status);
      return;
    }

    ScopedPool pool;
    assert(status == 0);
    assert(imageBuffer);
    GPUDecoder* gpu_decoder = static_cast<GPUDecoder*>(decompressionOutputRefCon);
    gpu_decoder->OnFrameReady(imageBuffer, presentationTimeStamp.epoch);
  }

  void OnFrameReady(CVImageBufferRef image_buffer,
                    int64_t display_time) {
    ScopedLock lock(&mutex_);

    if (image_buffer) {
      DecodedImage image;
      image.image = CVBufferRetain(image_buffer);
      image.display_time = display_time;

      std::list<DecodedImage>::iterator it = images_.begin();
      while (it != images_.end() && it->display_time <= display_time)
        it++;
      images_.insert(it, image);
    }

    pending_image_count_--;
    if (is_waiting_)
      pthread_cond_signal(&frame_ready_condition_);
  }

  VTDecompressionSessionRef vt_session_;
  CMVideoFormatDescriptionRef format_;
  std::list<DecodedImage> images_;
  int pending_image_count_;
  pthread_mutex_t mutex_;
  bool is_waiting_;
  pthread_cond_t frame_ready_condition_;
};

class Video {
 public:
  Video() : format_context_(NULL),
            codec_context_(NULL),
            codec_(NULL),
            video_stream_index_(-1),
            has_reached_end_of_file_(false) {
  }

  ~Video() {
    avformat_free_context(format_context_);
  }

  void Open(const char* path) {
    av_register_all();
    assert(avformat_open_input(&format_context_, path, NULL, NULL) == 0);
    assert(avformat_find_stream_info(format_context_, NULL) >= 0);

    for (int i = 0; i < format_context_->nb_streams; ++i) {
      if (format_context_->streams[i]->codec->codec_type == AVMEDIA_TYPE_VIDEO) {
        video_stream_index_ = i;
        codec_context_ = format_context_->streams[i]->codec;
        break;
      }
    }
    assert(codec_context_);

    assert(codec_ = avcodec_find_decoder(codec_context_->codec_id));
    assert(avcodec_open2(codec_context_, codec_, NULL) >= 0);
  }

  bool GetNextPacket(AVPacket* packet) {
    int error = av_read_frame(format_context_, packet);
    if (error == AVERROR_EOF)
      has_reached_end_of_file_ = true;
    return error >= 0;
  }

  int width() { return codec_context_->width; }
  int height() { return codec_context_->height; }
  bool has_reached_end_of_file() { return has_reached_end_of_file_; }
  int video_stream_index() { return video_stream_index_; }
  AVStream* stream() { return format_context_->streams[video_stream_index_]; }
  AVCodecContext* codec_context() { return codec_context_; }

 private:
  AVFormatContext* format_context_;
  AVCodecContext* codec_context_;
  AVCodec* codec_;
  int video_stream_index_;
  bool has_reached_end_of_file_;
};

int main (int argc, const char * argv[]) {
  ScopedPool pool;
  [NSApplication sharedApplication];

  assert(argc == 2);
  Video video;
  video.Open(argv[1]);
  GPUDecoder gpu_decoder;
  gpu_decoder.Create(video.width(), video.height(), 'avc1',
                     video.codec_context()->extradata,
                     video.codec_context()->extradata_size);

  NSRect rect = NSMakeRect(0, 0, video.width(), video.height());
  NSWindow* window = [[[NSWindow alloc]
      initWithContentRect:rect
      styleMask:NSTitledWindowMask
      backing:NSBackingStoreBuffered
      defer:NO] autorelease];
  [window center];
  [window makeKeyAndOrderFront:nil];
  [window retain];

  NSView* content_view = [window contentView];
  IOSurfaceTestView* view = [[[IOSurfaceTestView alloc]
      initWithFrame:[content_view bounds]] autorelease];
  [content_view addSubview:view];
  [view retain];

  DisplayClock clock(video.stream()->time_base);
  clock.Start();

  while (!video.has_reached_end_of_file()) {
    ScopedPool pool2;

    // Block until an image is decoded.
    if (gpu_decoder.pending_image_count() >= MAX_DECODE_QUEUE_SIZE &&
        gpu_decoder.GetDecodedImageCount() == 0) {
      gpu_decoder.WaitForDecodedImage();
    }

    // Decode images until it's time to display something.
    while (gpu_decoder.pending_image_count() < MAX_DECODE_QUEUE_SIZE &&
           gpu_decoder.GetDecodedImageCount() < MAX_PLAY_QUEUE_SIZE) {
      if (gpu_decoder.GetDecodedImageCount() > 0 &&
          clock.CurrentDisplayTime() >= gpu_decoder.GetNextDecodedImage().display_time) {
          break;
      }

      AVPacket packet;
      if (video.GetNextPacket(&packet)) {
        if (packet.stream_index == video.video_stream_index())
          gpu_decoder.DecodeNextFrame(packet.data, packet.size, packet.pts);
        av_free_packet(&packet);
      }
    }

    // Display an image.
    if (gpu_decoder.GetDecodedImageCount() > 0) {
      GPUDecoder::DecodedImage image = gpu_decoder.PopNextDecodedImage();
      [[NSRunLoop currentRunLoop] runUntilDate:
          clock.DisplayTimeToNSDate(image.display_time)];

      [view setImage:image.image];
      [view setNeedsDisplay:YES];
      CVBufferRelease(image.image);
    }
  }

  return 0;
}