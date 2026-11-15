// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#ifndef VIDEO_OUTPUT_H_
#define VIDEO_OUTPUT_H_

#include <optional>
#include <string>

#include <client.h>
#include <render.h>
#include <render_gl.h>

#include <array>
#include <atomic>
#include <condition_variable>
#include <future>
#include <memory>
#include <vector>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include "angle_surface_manager.h"
#include "thread_pool.h"

typedef struct _VideoOutputConfiguration {
  std::optional<int64_t> width;
  std::optional<int64_t> height;
  bool enable_hardware_acceleration;

  _VideoOutputConfiguration(std::optional<int64_t> width = std::nullopt,
                            std::optional<int64_t> height = std::nullopt,
                            bool enable_hardware_acceleration = true)
      : width(width),
        height(height),
        enable_hardware_acceleration(enable_hardware_acceleration) {}
} VideoOutputConfiguration;

class VideoOutput {
 public:
  int64_t texture_id() const { return texture_id_; }
  bool init_failed() const { return init_failed_; }
  const std::string& init_error() const { return init_error_; }

  int64_t width() const {
    if (surface_manager_ != nullptr && texture_id_) {
      return surface_manager_->width();
    }
    if (sw_initialized_ && texture_id_ && sw_pool_) {
      std::lock_guard<std::mutex> lock(sw_pool_->mutex);
      if (sw_pool_->published_index >= 0) {
        return sw_pool_->slots[sw_pool_->published_index].width;
      }
    }
    return width_.value_or(1);
  }
  int64_t height() const {
    if (surface_manager_ != nullptr && texture_id_) {
      return surface_manager_->height();
    }
    if (sw_initialized_ && texture_id_ && sw_pool_) {
      std::lock_guard<std::mutex> lock(sw_pool_->mutex);
      if (sw_pool_->published_index >= 0) {
        return sw_pool_->slots[sw_pool_->published_index].height;
      }
    }
    return height_.value_or(1);
  }

  VideoOutput(int64_t handle,
              VideoOutputConfiguration configuration,
              flutter::PluginRegistrarWindows* registrar,
              ThreadPool* thread_pool_ref);

  ~VideoOutput();

  void SetTextureUpdateCallback(
      std::function<void(int64_t, int64_t, int64_t)> callback);

  void SetSize(
      std::optional<int64_t> width,
      std::optional<int64_t> height,
      std::function<void(bool, const std::string&)> done = nullptr);

  void SetVisibility(
      bool visible,
      std::function<void(bool, const std::string&)> done = nullptr);

  // Flushes and trims video-device memory on the render worker.
  void TrimMemory();

  flutter::EncodableMap GetStats() const;

 private:
  static constexpr int kSwSlotCount = 3;

  struct SwSlot {
    std::vector<uint8_t> bytes;
    int64_t width = 1;
    int64_t height = 1;
    int in_flight_count = 0;
    bool is_published = false;
  };

  struct SwPool {
    std::mutex mutex;
    std::array<SwSlot, kSwSlotCount> slots;
    int published_index = -1;
    VideoOutput* owner = nullptr;
    bool frame_pending = false;
  };

  struct SwLease {
    std::shared_ptr<SwPool> pool;
    int slot_index = -1;
  };

  enum class ResizeOutcome {
    kUnchanged,
    kApplied,
    kDeferredHidden,
    kFailed,
  };

  void NotifyRender();

  bool Render();

  bool PresentHardwareFrame();

  ResizeOutcome CheckAndResize();

  bool Resize(int64_t required_width, int64_t required_height);

  void RetireTexture();

  int64_t GetVideoWidth();

  int64_t GetVideoHeight();

  void GetVideoSize(int64_t* width, int64_t* height);

  void NotifyTextureFrameAvailable();

  void MaybeNotifyPublishedDimensions(int64_t width, int64_t height);

  std::optional<int64_t> height_ = std::nullopt;
  std::optional<int64_t> width_ = std::nullopt;
  int64_t cached_video_width_ = 0;
  int64_t cached_video_height_ = 0;
  int64_t reported_width_ = 0;
  int64_t reported_height_ = 0;
  int64_t last_failed_resize_width_ = 0;
  int64_t last_failed_resize_height_ = 0;
  VideoOutputConfiguration configuration_ = VideoOutputConfiguration{};

  std::atomic<bool> visible_{true};
  std::atomic<bool> render_task_pending_{false};
  std::mutex render_admission_mutex_;

  mpv_handle* handle_ = nullptr;
  mpv_render_context* render_context_ = nullptr;
  int64_t texture_id_ = 0;
  flutter::PluginRegistrarWindows* registrar_ = nullptr;
  ThreadPool* thread_pool_ref_ = nullptr;
  std::atomic<bool> destroyed_{false};
  bool init_failed_ = false;
  std::string init_error_;

  mutable std::mutex textures_mutex_ = std::mutex();
  std::mutex retirement_mutex_;
  std::condition_variable retirement_cv_;
  size_t pending_texture_retirements_ = 0;

  std::unordered_map<int64_t, std::unique_ptr<flutter::TextureVariant>>
      texture_variants_ = {};

  // H/W rendering.
  std::unique_ptr<ANGLESurfaceManager> surface_manager_ = nullptr;
  std::unordered_map<int64_t,
                     std::unique_ptr<FlutterDesktopGpuSurfaceDescriptor>>
      textures_ = {};

  // S/W rendering (bounded 3-slot lease pool).
  bool sw_initialized_ = false;
  std::shared_ptr<SwPool> sw_pool_;
  int64_t sw_target_width_ = 1;
  int64_t sw_target_height_ = 1;
  std::unordered_map<int64_t, std::unique_ptr<FlutterDesktopPixelBuffer>>
      pixel_buffer_textures_ = {};

  std::function<void(int64_t, int64_t, int64_t)> texture_update_callback_ =
      [](int64_t, int64_t, int64_t) {};

  // Instrumentation (monotonic microsecond timestamps & atomic counters).
  std::atomic<int64_t> pending_notify_time_us_{0};
  std::atomic<int64_t> last_mark_frame_time_us_{0};
  std::atomic<uint64_t> notify_count_{0};
  std::atomic<uint64_t> coalesced_wakeups_{0};
  std::atomic<uint64_t> render_count_{0};
  std::atomic<uint64_t> skip_render_count_{0};
  std::atomic<uint64_t> render_failures_{0};
  std::atomic<uint64_t> descriptor_callbacks_{0};
  std::atomic<uint64_t> import_failures_{0};
  std::atomic<uint64_t> sw_missed_publishes_{0};
  std::atomic<uint64_t> frame_seq_{0};
  std::atomic<int64_t> last_notify_to_worker_us_{0};
  std::atomic<int64_t> max_notify_to_worker_us_{0};
  std::atomic<int64_t> last_mpv_render_us_{0};
  std::atomic<int64_t> max_mpv_render_us_{0};
  std::atomic<int64_t> last_flutter_notify_us_{0};
  std::atomic<int64_t> max_flutter_notify_us_{0};
  std::atomic<int64_t> last_acquire_us_{0};
  std::atomic<int64_t> max_acquire_us_{0};
};

#endif  // VIDEO_OUTPUT_H_
