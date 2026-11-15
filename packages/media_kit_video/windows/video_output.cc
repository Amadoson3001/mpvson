// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "video_output.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <utility>

#define SW_RENDERING_MAX_WIDTH 1920
#define SW_RENDERING_MAX_HEIGHT 1080
#define SW_RENDERING_PIXEL_BUFFER_SIZE \
  (static_cast<size_t>(SW_RENDERING_MAX_WIDTH) * \
   static_cast<size_t>(SW_RENDERING_MAX_HEIGHT) * 4u)

static int64_t NowMicros() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

static void UpdateMax(std::atomic<int64_t>& target, int64_t value) {
  int64_t prev = target.load(std::memory_order_relaxed);
  while (value > prev &&
         !target.compare_exchange_weak(prev, value, std::memory_order_relaxed)) {
  }
}

static bool IsEnvFlagEnabled(const wchar_t* name) {
  wchar_t buf[16]{};
  const DWORD len = ::GetEnvironmentVariableW(name, buf, 16);
  if (len == 0 || len >= 16) return false;
  return wcscmp(buf, L"1") == 0 || _wcsicmp(buf, L"true") == 0;
}

static bool IsForcedAngleFailStage(const wchar_t* expected) {
  wchar_t buf[32]{};
  const DWORD len =
      ::GetEnvironmentVariableW(L"MPVSON_FORCE_ANGLE_FAIL_STAGE", buf, 32);
  if (len == 0 || len >= 32) return false;
  return _wcsicmp(buf, expected) == 0;
}

static std::pair<int64_t, int64_t> FitSoftwareDimensions(
    int64_t width, int64_t height) {
  if (width <= 0 || height <= 0) return {width, height};
  const double scale = (std::min)(
      {1.0, static_cast<double>(SW_RENDERING_MAX_WIDTH) / width,
       static_cast<double>(SW_RENDERING_MAX_HEIGHT) / height});
  return {
      (std::max<int64_t>)(
          1, static_cast<int64_t>(std::floor(width * scale))),
      (std::max<int64_t>)(
          1, static_cast<int64_t>(std::floor(height * scale))),
  };
}

VideoOutput::VideoOutput(int64_t handle,
                         VideoOutputConfiguration configuration,
                         flutter::PluginRegistrarWindows* registrar,
                         ThreadPool* thread_pool_ref)
    : handle_(reinterpret_cast<mpv_handle*>(handle)),
      width_(configuration.width),
      height_(configuration.height),
      configuration_(configuration),
      registrar_(registrar),
      thread_pool_ref_(thread_pool_ref) {
  auto future = thread_pool_ref_->Post([&]() {
    mpv_set_option_string(handle_, "video-sync", "audio");
    mpv_set_option_string(handle_, "interpolation", "no");
    mpv_set_option_string(handle_, "opengl-es", "yes");
    mpv_set_option_string(handle_, "framedrop", "vo");
    mpv_set_option_string(handle_, "vd-lavc-dr", "yes");
    mpv_set_option_string(handle_, "hwdec-extra-frames", "4");

    auto is_hardware_acceleration_enabled = false;
    const bool force_sw = IsEnvFlagEnabled(L"MPVSON_FORCE_SW_RENDER");

    if (configuration.enable_hardware_acceleration && !force_sw) {
      try {
        surface_manager_ = std::make_unique<ANGLESurfaceManager>(
            static_cast<int32_t>(width_.value_or(1)),
            static_cast<int32_t>(height_.value_or(1)));
        surface_manager_->MakeCurrent(true);
        mpv_opengl_init_params gl_init_params{
            [](auto, auto name) {
              return reinterpret_cast<void*>(eglGetProcAddress(name));
            },
            nullptr,
        };
        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL},
            {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init_params},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        const int rc =
            mpv_render_context_create(&render_context_, handle_, params);
        surface_manager_->MakeCurrent(false);
        if (rc == 0 && render_context_ != nullptr &&
            !IsForcedAngleFailStage(L"context")) {
          Resize(width_.value_or(1), height_.value_or(1));
          if (!init_failed_ && texture_id_ > 0) {
            mpv_render_context_set_update_callback(
                render_context_,
                [](void* context) {
                  auto that = reinterpret_cast<VideoOutput*>(context);
                  that->NotifyRender();
                },
                reinterpret_cast<void*>(this));
            is_hardware_acceleration_enabled = true;
            std::cout << "media_kit: VideoOutput: Using H/W rendering."
                      << std::endl;
          } else {
            surface_manager_->MakeCurrent(true);
            mpv_render_context_free(render_context_);
            render_context_ = nullptr;
            surface_manager_->MakeCurrent(false);
            surface_manager_.reset();
            init_failed_ = false;
          }
        } else {
          if (render_context_ != nullptr) {
            surface_manager_->MakeCurrent(true);
            mpv_render_context_free(render_context_);
            render_context_ = nullptr;
            surface_manager_->MakeCurrent(false);
          }
          init_error_ = IsForcedAngleFailStage(L"context")
                            ? "Forced ANGLE failure after render-context creation"
                            : "mpv_render_context_create(OPENGL) failed: " +
                                  std::to_string(rc);
          surface_manager_.reset();
        }
      } catch (const std::exception& ex) {
        init_error_ = ex.what();
        if (render_context_ != nullptr) {
          if (surface_manager_ != nullptr) surface_manager_->MakeCurrent(true);
          mpv_render_context_free(render_context_);
          render_context_ = nullptr;
          if (surface_manager_ != nullptr) surface_manager_->MakeCurrent(false);
        }
        surface_manager_.reset();
      } catch (...) {
        init_error_ = "ANGLESurfaceManager initialization failed.";
        if (render_context_ != nullptr) {
          if (surface_manager_ != nullptr) surface_manager_->MakeCurrent(true);
          mpv_render_context_free(render_context_);
          render_context_ = nullptr;
          if (surface_manager_ != nullptr) surface_manager_->MakeCurrent(false);
        }
        surface_manager_.reset();
      }
    }

    if (!is_hardware_acceleration_enabled) {
      surface_manager_.reset();
      if (render_context_ != nullptr) {
        mpv_render_context_free(render_context_);
        render_context_ = nullptr;
      }

      std::cout << "media_kit: VideoOutput: Using S/W rendering." << std::endl;
      sw_pool_ = std::make_shared<SwPool>();
      sw_pool_->owner = this;
      for (auto& slot : sw_pool_->slots) {
        slot.bytes.resize(SW_RENDERING_PIXEL_BUFFER_SIZE, 0);
        slot.width = width_.value_or(1);
        slot.height = height_.value_or(1);
      }
      mpv_render_param params[] = {
          {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW},
          {MPV_RENDER_PARAM_INVALID, nullptr},
      };
      const int rc =
          mpv_render_context_create(&render_context_, handle_, params);
      if (rc == 0 && render_context_ != nullptr) {
        sw_initialized_ = true;
        Resize(width_.value_or(1), height_.value_or(1));
        if (!init_failed_ && texture_id_ > 0) {
          mpv_render_context_set_update_callback(
              render_context_,
              [](void* context) {
                auto that = reinterpret_cast<VideoOutput*>(context);
                that->NotifyRender();
              },
              reinterpret_cast<void*>(this));
        } else {
          mpv_render_context_free(render_context_);
          render_context_ = nullptr;
          sw_initialized_ = false;
          sw_pool_.reset();
        }
      } else {
        sw_pool_.reset();
        init_failed_ = true;
        if (!init_error_.empty()) {
          init_error_ += "; ";
        }
        init_error_ +=
            "mpv_render_context_create(SW) failed: " + std::to_string(rc);
      }
    }
  });
  try {
    future.get();
  } catch (const std::exception& ex) {
    init_failed_ = true;
    init_error_ = ex.what();
  } catch (...) {
    init_failed_ = true;
    init_error_ = "VideoOutput worker initialization failed.";
  }
}

VideoOutput::~VideoOutput() {
  {
    std::lock_guard<std::mutex> admission(render_admission_mutex_);
    destroyed_ = true;
  }
  if (sw_pool_) {
    std::lock_guard<std::mutex> sw_lock(sw_pool_->mutex);
    sw_pool_->owner = nullptr;
    sw_pool_->frame_pending = false;
  }
  if (render_context_ != nullptr) {
    mpv_render_context_set_update_callback(render_context_, nullptr, nullptr);
  }
  thread_pool_ref_->Post([this]() { RetireTexture(); }).wait();
  {
    std::unique_lock<std::mutex> lock(retirement_mutex_);
    retirement_cv_.wait(lock, [this]() {
      return pending_texture_retirements_ == 0;
    });
  }
  thread_pool_ref_->Post([this]() {
    std::lock_guard<std::mutex> lock(textures_mutex_);
    texture_variants_.clear();
    textures_.clear();
    pixel_buffer_textures_.clear();
    if (render_context_ != nullptr) {
      if (surface_manager_ != nullptr) surface_manager_->MakeCurrent(true);
      mpv_render_context_free(render_context_);
      render_context_ = nullptr;
      if (surface_manager_ != nullptr) surface_manager_->MakeCurrent(false);
    }
    surface_manager_.reset();
    sw_pool_.reset();
  }).wait();
}

void VideoOutput::RetireTexture() {
  int64_t id;
  {
    std::lock_guard<std::mutex> lock(textures_mutex_);
    id = texture_id_;
    texture_id_ = 0;
  }
  if (id <= 0) return;
  {
    std::lock_guard<std::mutex> lock(retirement_mutex_);
    ++pending_texture_retirements_;
  }
  registrar_->texture_registrar()->UnregisterTexture(id, [this, id]() {
    {
      std::lock_guard<std::mutex> lock(textures_mutex_);
      texture_variants_.erase(id);
      textures_.erase(id);
      pixel_buffer_textures_.erase(id);
    }
    std::lock_guard<std::mutex> lock(retirement_mutex_);
    --pending_texture_retirements_;
    retirement_cv_.notify_all();
  });
}

void VideoOutput::SetVisibility(
    bool visible,
    std::function<void(bool, const std::string&)> done) {
  visible_.store(visible);
  thread_pool_ref_->Post([this, visible, done = std::move(done)]() {
    if (destroyed_) {
      if (done) done(false, "VideoOutput disposed");
      return;
    }
    if (visible) {
      const auto outcome = CheckAndResize();
      if (outcome == ResizeOutcome::kUnchanged) {
        Render();
      } else if (outcome == ResizeOutcome::kApplied) {
        if (sw_initialized_) {
          Render();
        } else if (texture_id_ > 0) {
          NotifyTextureFrameAvailable();
        }
      } else if (outcome == ResizeOutcome::kFailed) {
        if (done) done(false, "Resize or render failed on visibility restore");
        return;
      }
    }
    if (done) done(true, {});
  });
}

void VideoOutput::TrimMemory() {
  std::lock_guard<std::mutex> admission(render_admission_mutex_);
  if (destroyed_) {
    return;
  }
  thread_pool_ref_->Post([this]() {
    if (destroyed_) {
      return;
    }
    if (surface_manager_ != nullptr) {
      surface_manager_->Trim();
    }
  });
}

void VideoOutput::NotifyTextureFrameAvailable() {
  if (texture_id_ <= 0) return;
  const int64_t t0 = NowMicros();
  last_mark_frame_time_us_.store(t0, std::memory_order_relaxed);
  try {
    registrar_->texture_registrar()->MarkTextureFrameAvailable(texture_id_);
  } catch (...) {
  }
  const int64_t elapsed = NowMicros() - t0;
  last_flutter_notify_us_.store(elapsed, std::memory_order_relaxed);
  UpdateMax(max_flutter_notify_us_, elapsed);
}

void VideoOutput::MaybeNotifyPublishedDimensions(int64_t width,
                                                 int64_t height) {
  if (texture_id_ <= 0 || width < 1 || height < 1) return;
  if (width != reported_width_ || height != reported_height_) {
    reported_width_ = width;
    reported_height_ = height;
    texture_update_callback_(texture_id_, width, height);
  }
}

void VideoOutput::NotifyRender() {
  std::lock_guard<std::mutex> admission(render_admission_mutex_);
  if (destroyed_) {
    return;
  }
  notify_count_.fetch_add(1, std::memory_order_relaxed);
  bool expected = false;
  if (!render_task_pending_.compare_exchange_strong(expected, true)) {
    coalesced_wakeups_.fetch_add(1, std::memory_order_relaxed);
    return;
  }
  pending_notify_time_us_.store(NowMicros(), std::memory_order_relaxed);
  thread_pool_ref_->Post([this]() {
    const int64_t worker_start = NowMicros();
    const int64_t notify_ts =
        pending_notify_time_us_.load(std::memory_order_relaxed);
    if (notify_ts > 0 && worker_start >= notify_ts) {
      const int64_t delay = worker_start - notify_ts;
      last_notify_to_worker_us_.store(delay, std::memory_order_relaxed);
      UpdateMax(max_notify_to_worker_us_, delay);
    }
    render_task_pending_.store(false);
    if (destroyed_) {
      return;
    }
    if (!visible_.load()) {
      if (render_context_ != nullptr) {
        if (surface_manager_ != nullptr) {
          surface_manager_->Draw(
              [&]() {
                int skip = 1;
                int block_for_target_time = 0;
                mpv_render_param params[]{
                    {MPV_RENDER_PARAM_SKIP_RENDERING, &skip},
                    {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,
                     &block_for_target_time},
                    {MPV_RENDER_PARAM_INVALID, nullptr},
                };
                mpv_render_context_render(render_context_, params);
                return true;
              },
              false);
          skip_render_count_.fetch_add(1, std::memory_order_relaxed);
        } else if (sw_initialized_) {
          int skip = 1;
          int block_for_target_time = 0;
          mpv_render_param params[]{
              {MPV_RENDER_PARAM_SKIP_RENDERING, &skip},
              {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block_for_target_time},
              {MPV_RENDER_PARAM_INVALID, nullptr},
          };
          mpv_render_context_render(render_context_, params);
          skip_render_count_.fetch_add(1, std::memory_order_relaxed);
        }
      }
      return;
    }
    const auto outcome = CheckAndResize();
    if (outcome == ResizeOutcome::kUnchanged) {
      Render();
    } else if (outcome == ResizeOutcome::kApplied) {
      if (sw_initialized_) {
        Render();
      } else if (texture_id_ > 0) {
        NotifyTextureFrameAvailable();
      }
    }
  });
}

bool VideoOutput::PresentHardwareFrame() {
  if (surface_manager_ == nullptr || render_context_ == nullptr) {
    return false;
  }
  int render_rc = -1;
  const bool drawn = surface_manager_->Draw([&]() {
    mpv_opengl_fbo fbo{
        0,
        surface_manager_->width(),
        surface_manager_->height(),
        0,
    };
    int block_for_target_time = 0;
    mpv_render_param params[]{
        {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
        {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block_for_target_time},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };
    const int64_t t0 = NowMicros();
    render_rc = mpv_render_context_render(render_context_, params);
    const int64_t elapsed = NowMicros() - t0;
    last_mpv_render_us_.store(elapsed, std::memory_order_relaxed);
    UpdateMax(max_mpv_render_us_, elapsed);
    if (render_rc < 0) {
      render_failures_.fetch_add(1, std::memory_order_relaxed);
      return false;
    }
    return true;
  });
  if (drawn && render_rc >= 0) {
    render_count_.fetch_add(1, std::memory_order_relaxed);
    frame_seq_.fetch_add(1, std::memory_order_relaxed);
    const auto published = surface_manager_->CopyPublishedSnapshot();
    MaybeNotifyPublishedDimensions(published.width, published.height);
    return true;
  }
  return false;
}

bool VideoOutput::Render() {
  if (texture_id_ <= 0) return false;
  bool frame_ready = false;
  bool render_ok = false;
  if (surface_manager_ != nullptr) {
    frame_ready = PresentHardwareFrame();
    render_ok = frame_ready;
  } else if (sw_initialized_ && sw_pool_) {
    int write_slot = -1;
    {
      std::lock_guard<std::mutex> lock(sw_pool_->mutex);
      for (int i = 0; i < kSwSlotCount; ++i) {
        const auto& slot = sw_pool_->slots[i];
        if (slot.in_flight_count == 0 && !slot.is_published) {
          write_slot = i;
          break;
        }
      }
      if (write_slot < 0) {
        sw_pool_->frame_pending = true;
      }
    }
    if (write_slot < 0) {
      sw_missed_publishes_.fetch_add(1, std::memory_order_relaxed);
      return true;
    }

    const int64_t w =
        std::clamp<int64_t>(sw_target_width_, 1, SW_RENDERING_MAX_WIDTH);
    const int64_t h =
        std::clamp<int64_t>(sw_target_height_, 1, SW_RENDERING_MAX_HEIGHT);
    const size_t required_bytes =
        static_cast<size_t>(w) * static_cast<size_t>(h) * 4u;
    auto& slot = sw_pool_->slots[write_slot];
    if (slot.bytes.size() < required_bytes) {
      slot.bytes.resize(required_bytes);
    }

    int32_t size[2] = {static_cast<int32_t>(w), static_cast<int32_t>(h)};
    size_t pitch = static_cast<size_t>(w) * 4u;
    int block_for_target_time = 0;
    mpv_render_param params[]{
        {MPV_RENDER_PARAM_SW_SIZE, size},
        {MPV_RENDER_PARAM_SW_FORMAT, const_cast<char*>("rgba")},
        {MPV_RENDER_PARAM_SW_STRIDE, &pitch},
        {MPV_RENDER_PARAM_SW_POINTER, slot.bytes.data()},
        {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block_for_target_time},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };
    const int64_t t0 = NowMicros();
    const int rc = mpv_render_context_render(render_context_, params);
    const int64_t elapsed = NowMicros() - t0;
    last_mpv_render_us_.store(elapsed, std::memory_order_relaxed);
    UpdateMax(max_mpv_render_us_, elapsed);
    if (rc >= 0) {
      {
        std::lock_guard<std::mutex> lock(sw_pool_->mutex);
        if (sw_pool_->published_index >= 0) {
          sw_pool_->slots[sw_pool_->published_index].is_published = false;
        }
        slot.width = w;
        slot.height = h;
        slot.is_published = true;
        sw_pool_->published_index = write_slot;
      }
      render_count_.fetch_add(1, std::memory_order_relaxed);
      frame_seq_.fetch_add(1, std::memory_order_relaxed);
      MaybeNotifyPublishedDimensions(w, h);
      frame_ready = true;
      render_ok = true;
    } else {
      render_failures_.fetch_add(1, std::memory_order_relaxed);
    }
  }
  if (frame_ready) {
    NotifyTextureFrameAvailable();
  }
  return render_ok;
}

void VideoOutput::SetTextureUpdateCallback(
    std::function<void(int64_t, int64_t, int64_t)> callback) {
  texture_update_callback_ = callback;
  texture_update_callback_(texture_id_, GetVideoWidth(), GetVideoHeight());
}

void VideoOutput::SetSize(
    std::optional<int64_t> width,
    std::optional<int64_t> height,
    std::function<void(bool, const std::string&)> done) {
  thread_pool_ref_->Post([this, width, height, done = std::move(done)]() {
    if (destroyed_) {
      if (done) done(false, "VideoOutput disposed");
      return;
    }
    if (width.has_value()) {
      if (surface_manager_ != nullptr) {
        width_ = width.value();
      } else if (sw_initialized_) {
        width_ = std::clamp(width.value(), static_cast<int64_t>(0),
                            static_cast<int64_t>(SW_RENDERING_MAX_WIDTH));
      }
    } else {
      width_ = std::nullopt;
    }
    if (height.has_value()) {
      if (surface_manager_ != nullptr) {
        height_ = height.value();
      } else if (sw_initialized_) {
        height_ = std::clamp(height.value(), static_cast<int64_t>(0),
                             static_cast<int64_t>(SW_RENDERING_MAX_HEIGHT));
      }
    } else {
      height_ = std::nullopt;
    }
    last_failed_resize_width_ = 0;
    last_failed_resize_height_ = 0;
    if (!visible_.load()) {
      if (done) done(true, "deferred_hidden");
      return;
    }
    const auto outcome = CheckAndResize();
    if (outcome == ResizeOutcome::kFailed) {
      if (done) done(false, "Resize or render failed");
      return;
    }
    if (outcome == ResizeOutcome::kApplied) {
      if (surface_manager_ != nullptr) {
        if (texture_id_ > 0) {
          NotifyTextureFrameAvailable();
        }
        if (done) done(true, {});
        return;
      }
      const bool ok = Render();
      if (done) done(ok, ok ? std::string{} : "Software render failed");
      return;
    }
    const bool ok = Render();
    if (done) done(ok, ok ? std::string{} : "Render failed");
  });
}

VideoOutput::ResizeOutcome VideoOutput::CheckAndResize() {
  int64_t required_width = 0, required_height = 0;
  GetVideoSize(&required_width, &required_height);
  if (required_width < 1 || required_height < 1) {
    return ResizeOutcome::kUnchanged;
  }
  int64_t current_width = -1, current_height = -1;
  if (surface_manager_ != nullptr) {
    current_width = surface_manager_->width();
    current_height = surface_manager_->height();
  } else if (sw_initialized_) {
    current_width = sw_target_width_;
    current_height = sw_target_height_;
  }
  if (current_width < 1 || current_height < 1) {
    return ResizeOutcome::kUnchanged;
  }
  if (required_width == current_width && required_height == current_height) {
    return ResizeOutcome::kUnchanged;
  }
  if (required_width == last_failed_resize_width_ &&
      required_height == last_failed_resize_height_) {
    return ResizeOutcome::kFailed;
  }
  if (Resize(required_width, required_height)) {
    last_failed_resize_width_ = 0;
    last_failed_resize_height_ = 0;
    return ResizeOutcome::kApplied;
  }
  last_failed_resize_width_ = required_width;
  last_failed_resize_height_ = required_height;
  return ResizeOutcome::kFailed;
}

bool VideoOutput::Resize(int64_t required_width, int64_t required_height) {
  if (surface_manager_ != nullptr && texture_id_ > 0) {
    if (!surface_manager_->SetSize(static_cast<int32_t>(required_width),
                                   static_cast<int32_t>(required_height))) {
      return false;
    }
    return PresentHardwareFrame();
  }
  if (sw_initialized_ && texture_id_ > 0) {
    sw_target_width_ =
        std::clamp<int64_t>(required_width, 1, SW_RENDERING_MAX_WIDTH);
    sw_target_height_ =
        std::clamp<int64_t>(required_height, 1, SW_RENDERING_MAX_HEIGHT);
    return true;
  }

  std::lock_guard<std::mutex> texture_lock(textures_mutex_);
  if (surface_manager_ != nullptr) {
    if (!surface_manager_->SetSize(static_cast<int32_t>(required_width),
                                   static_cast<int32_t>(required_height))) {
      init_failed_ = true;
      init_error_ = "ANGLESurfaceManager::SetSize failed during registration";
      return false;
    }
    auto texture = std::make_unique<FlutterDesktopGpuSurfaceDescriptor>();
    texture->struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
    const auto initial = surface_manager_->CopyPublishedSnapshot();
    texture->handle = initial.handle;
    texture->width = texture->visible_width = initial.width;
    texture->height = texture->visible_height = initial.height;
    texture->release_context = nullptr;
    texture->release_callback = [](void* context) {
      delete static_cast<std::shared_ptr<ANGLESurfaceManager::SurfaceBacking>*>(
          context);
    };
    texture->format = kFlutterDesktopPixelFormatBGRA8888;
    auto texture_variant =
        std::make_unique<flutter::TextureVariant>(flutter::GpuSurfaceTexture(
            kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle, [&](auto, auto) {
              const int64_t now = NowMicros();
              const int64_t mark_ts =
                  last_mark_frame_time_us_.load(std::memory_order_relaxed);
              if (mark_ts > 0 && now >= mark_ts) {
                const int64_t acq = now - mark_ts;
                last_acquire_us_.store(acq, std::memory_order_relaxed);
                UpdateMax(max_acquire_us_, acq);
              }
              std::lock_guard<std::mutex> lock(textures_mutex_);
              if (texture_id_ > 0) {
                auto it = textures_.find(texture_id_);
                if (it != textures_.end() && surface_manager_ != nullptr) {
                  auto snapshot = surface_manager_->CopyPublishedSnapshot();
                  if (snapshot.handle == nullptr || !snapshot.backing) {
                    import_failures_.fetch_add(1, std::memory_order_relaxed);
                    return (FlutterDesktopGpuSurfaceDescriptor*)nullptr;
                  }
                  descriptor_callbacks_.fetch_add(1, std::memory_order_relaxed);
                  auto* desc = it->second.get();
                  desc->handle = snapshot.handle;
                  desc->width = desc->visible_width = snapshot.width;
                  desc->height = desc->visible_height = snapshot.height;
                  desc->release_context =
                      new std::shared_ptr<ANGLESurfaceManager::SurfaceBacking>(
                          std::move(snapshot.backing));
                  desc->release_callback = [](void* context) {
                    delete static_cast<
                        std::shared_ptr<ANGLESurfaceManager::SurfaceBacking>*>(
                        context);
                  };
                  return desc;
                }
              }
              import_failures_.fetch_add(1, std::memory_order_relaxed);
              return (FlutterDesktopGpuSurfaceDescriptor*)nullptr;
            }));
    const int64_t new_id =
        registrar_->texture_registrar()->RegisterTexture(texture_variant.get());
    if (new_id <= 0) {
      init_failed_ = true;
      init_error_ = "RegisterTexture(GpuSurfaceTexture) failed";
      return false;
    }
    texture_id_ = new_id;
    std::cout << "media_kit: VideoOutput: Create Texture: " << texture_id_
              << std::endl;

    textures_.emplace(std::make_pair(texture_id_, std::move(texture)));
    texture_variants_.emplace(
        std::make_pair(texture_id_, std::move(texture_variant)));
  } else if (sw_initialized_ && sw_pool_) {
    sw_target_width_ =
        std::clamp<int64_t>(required_width, 1, SW_RENDERING_MAX_WIDTH);
    sw_target_height_ =
        std::clamp<int64_t>(required_height, 1, SW_RENDERING_MAX_HEIGHT);
    auto pixel_buffer_texture = std::make_unique<FlutterDesktopPixelBuffer>();
    {
      std::lock_guard<std::mutex> sw_lock(sw_pool_->mutex);
      pixel_buffer_texture->buffer = sw_pool_->slots[0].bytes.data();
      pixel_buffer_texture->width = static_cast<size_t>(sw_target_width_);
      pixel_buffer_texture->height = static_cast<size_t>(sw_target_height_);
    }
    pixel_buffer_texture->release_context = nullptr;
    pixel_buffer_texture->release_callback = [](void* context) {
      auto* lease = static_cast<SwLease*>(context);
      if (lease != nullptr) {
        if (lease->pool && lease->slot_index >= 0 &&
            lease->slot_index < kSwSlotCount) {
          std::lock_guard<std::mutex> lock(lease->pool->mutex);
          auto& slot = lease->pool->slots[lease->slot_index];
          if (slot.in_flight_count > 0) {
            --slot.in_flight_count;
          }
          if (slot.in_flight_count == 0 && lease->pool->frame_pending &&
              lease->pool->owner != nullptr) {
            lease->pool->frame_pending = false;
            lease->pool->owner->NotifyRender();
          }
        }
        delete lease;
      }
    };
    auto texture_variant = std::make_unique<flutter::TextureVariant>(
        flutter::PixelBufferTexture([&](auto, auto) {
          const int64_t now = NowMicros();
          const int64_t mark_ts =
              last_mark_frame_time_us_.load(std::memory_order_relaxed);
          if (mark_ts > 0 && now >= mark_ts) {
            const int64_t acq = now - mark_ts;
            last_acquire_us_.store(acq, std::memory_order_relaxed);
            UpdateMax(max_acquire_us_, acq);
          }
          std::lock_guard<std::mutex> lock(textures_mutex_);
          if (texture_id_ > 0 && sw_pool_) {
            auto it = pixel_buffer_textures_.find(texture_id_);
            if (it != pixel_buffer_textures_.end()) {
              std::lock_guard<std::mutex> sw_lock(sw_pool_->mutex);
              const int idx = sw_pool_->published_index;
              if (idx < 0 || idx >= kSwSlotCount) {
                import_failures_.fetch_add(1, std::memory_order_relaxed);
                return (FlutterDesktopPixelBuffer*)nullptr;
              }
              auto& slot = sw_pool_->slots[idx];
              slot.in_flight_count++;
              descriptor_callbacks_.fetch_add(1, std::memory_order_relaxed);
              auto* pb = it->second.get();
              pb->buffer = slot.bytes.data();
              pb->width = static_cast<size_t>(slot.width);
              pb->height = static_cast<size_t>(slot.height);
              pb->release_context = new SwLease{sw_pool_, idx};
              return pb;
            }
          }
          import_failures_.fetch_add(1, std::memory_order_relaxed);
          return (FlutterDesktopPixelBuffer*)nullptr;
        }));
    const int64_t new_id =
        registrar_->texture_registrar()->RegisterTexture(texture_variant.get());
    if (new_id <= 0) {
      init_failed_ = true;
      init_error_ = "RegisterTexture(PixelBufferTexture) failed";
      return false;
    }
    texture_id_ = new_id;
    std::cout << "media_kit: VideoOutput: Create Texture: " << texture_id_
              << std::endl;

    pixel_buffer_textures_.emplace(
        std::make_pair(texture_id_, std::move(pixel_buffer_texture)));
    texture_variants_.emplace(
        std::make_pair(texture_id_, std::move(texture_variant)));
  }
  return false;
}

void VideoOutput::GetVideoSize(int64_t* width, int64_t* height) {
  if (width_ && height_) {
    *width = width_.value();
    *height = height_.value();
    if (sw_initialized_) {
      const auto fitted = FitSoftwareDimensions(*width, *height);
      *width = fitted.first;
      *height = fitted.second;
    }
    return;
  }

  int64_t dw = 0, dh = 0, rotate = 0;
  mpv_node params{};
  const int status =
      mpv_get_property(handle_, "video-out-params", MPV_FORMAT_NODE, &params);
  if (status >= 0 && params.format == MPV_FORMAT_NODE_MAP) {
    for (int32_t i = 0; i < params.u.list->num; i++) {
      char* key = params.u.list->keys[i];
      auto value = params.u.list->values[i];
      if (value.format == MPV_FORMAT_INT64) {
        if (strcmp(key, "dw") == 0) {
          dw = value.u.int64;
        }
        if (strcmp(key, "dh") == 0) {
          dh = value.u.int64;
        }
        if (strcmp(key, "rotate") == 0) {
          rotate = value.u.int64;
        }
      }
    }
    mpv_free_node_contents(&params);
  }
  if (dw > 0 && dh > 0) {
    const int64_t w = (rotate == 0 || rotate == 180) ? dw : dh;
    const int64_t h = (rotate == 0 || rotate == 180) ? dh : dw;
    cached_video_width_ = w;
    cached_video_height_ = h;
    *width = w;
    *height = h;
  } else if (cached_video_width_ > 0 && cached_video_height_ > 0) {
    *width = cached_video_width_;
    *height = cached_video_height_;
  } else {
    *width = 0;
    *height = 0;
  }
  if (sw_initialized_ && *width > 0 && *height > 0) {
    const auto fitted = FitSoftwareDimensions(*width, *height);
    *width = fitted.first;
    *height = fitted.second;
  }
}

int64_t VideoOutput::GetVideoWidth() {
  int64_t width = 0, height = 0;
  GetVideoSize(&width, &height);
  return width;
}

int64_t VideoOutput::GetVideoHeight() {
  int64_t width = 0, height = 0;
  GetVideoSize(&width, &height);
  return height;
}

flutter::EncodableMap VideoOutput::GetStats() const {
  flutter::EncodableMap stats;
  const std::string backend = surface_manager_ != nullptr
                                  ? "hardware"
                                  : (sw_initialized_ ? "software" : "none");
  stats[flutter::EncodableValue("backend")] = flutter::EncodableValue(backend);
  stats[flutter::EncodableValue("textureId")] =
      flutter::EncodableValue(texture_id_);
  stats[flutter::EncodableValue("initFailed")] =
      flutter::EncodableValue(init_failed_);
  if (!init_error_.empty()) {
    stats[flutter::EncodableValue("initError")] =
        flutter::EncodableValue(init_error_);
  }
  stats[flutter::EncodableValue("notifyCount")] =
      flutter::EncodableValue(static_cast<int64_t>(
          notify_count_.load(std::memory_order_relaxed)));
  stats[flutter::EncodableValue("coalescedWakeups")] =
      flutter::EncodableValue(static_cast<int64_t>(
          coalesced_wakeups_.load(std::memory_order_relaxed)));
  stats[flutter::EncodableValue("renderCount")] =
      flutter::EncodableValue(static_cast<int64_t>(
          render_count_.load(std::memory_order_relaxed)));
  stats[flutter::EncodableValue("skipRenderCount")] =
      flutter::EncodableValue(static_cast<int64_t>(
          skip_render_count_.load(std::memory_order_relaxed)));
  stats[flutter::EncodableValue("renderFailures")] =
      flutter::EncodableValue(static_cast<int64_t>(
          render_failures_.load(std::memory_order_relaxed)));
  stats[flutter::EncodableValue("descriptorCallbacks")] =
      flutter::EncodableValue(static_cast<int64_t>(
          descriptor_callbacks_.load(std::memory_order_relaxed)));
  stats[flutter::EncodableValue("importFailures")] =
      flutter::EncodableValue(static_cast<int64_t>(
          import_failures_.load(std::memory_order_relaxed)));
  stats[flutter::EncodableValue("swMissedPublishes")] =
      flutter::EncodableValue(static_cast<int64_t>(
          sw_missed_publishes_.load(std::memory_order_relaxed)));
  stats[flutter::EncodableValue("gpuMissedPublishes")] =
      flutter::EncodableValue(static_cast<int64_t>(
          surface_manager_ != nullptr ? surface_manager_->gpu_missed_publishes()
                                      : 0));
  stats[flutter::EncodableValue("frameSeq")] =
      flutter::EncodableValue(static_cast<int64_t>(
          frame_seq_.load(std::memory_order_relaxed)));
  stats[flutter::EncodableValue("lastNotifyToWorkerUs")] =
      flutter::EncodableValue(
          last_notify_to_worker_us_.load(std::memory_order_relaxed));
  stats[flutter::EncodableValue("maxNotifyToWorkerUs")] =
      flutter::EncodableValue(
          max_notify_to_worker_us_.load(std::memory_order_relaxed));
  stats[flutter::EncodableValue("lastMpvRenderUs")] = flutter::EncodableValue(
      last_mpv_render_us_.load(std::memory_order_relaxed));
  stats[flutter::EncodableValue("maxMpvRenderUs")] = flutter::EncodableValue(
      max_mpv_render_us_.load(std::memory_order_relaxed));
  stats[flutter::EncodableValue("lastFlutterNotifyUs")] =
      flutter::EncodableValue(
          last_flutter_notify_us_.load(std::memory_order_relaxed));
  stats[flutter::EncodableValue("maxFlutterNotifyUs")] =
      flutter::EncodableValue(
          max_flutter_notify_us_.load(std::memory_order_relaxed));
  stats[flutter::EncodableValue("lastAcquireUs")] = flutter::EncodableValue(
      last_acquire_us_.load(std::memory_order_relaxed));
  stats[flutter::EncodableValue("maxAcquireUs")] = flutter::EncodableValue(
      max_acquire_us_.load(std::memory_order_relaxed));
  if (surface_manager_ != nullptr) {
    const auto snapshot = surface_manager_->CopyPublishedSnapshot();
    stats[flutter::EncodableValue("adapterLuid")] =
        flutter::EncodableValue(surface_manager_->adapter_luid());
    stats[flutter::EncodableValue("adapterName")] =
        flutter::EncodableValue(surface_manager_->adapter_name());
    stats[flutter::EncodableValue("outputGeneration")] =
        flutter::EncodableValue(static_cast<int64_t>(snapshot.generation));
    stats[flutter::EncodableValue("resizeAllocations")] =
        flutter::EncodableValue(
            static_cast<int64_t>(surface_manager_->resize_allocations()));
    stats[flutter::EncodableValue("publishes")] =
        flutter::EncodableValue(static_cast<int64_t>(snapshot.publish_count));
    stats[flutter::EncodableValue("lastCopySubmitUs")] =
        flutter::EncodableValue(surface_manager_->last_copy_submit_us());
  }
  return stats;
}
