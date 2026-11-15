// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "video_output_manager.h"

VideoOutputManager::VideoOutputManager(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {}

void VideoOutputManager::Create(
    int64_t handle,
    VideoOutputConfiguration configuration,
    std::function<void(int64_t, int64_t, int64_t)> texture_update_callback,
    std::function<void(const std::string&)> error_callback) {
  manager_pool_->Post([=]() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (video_outputs_.find(handle) == video_outputs_.end()) {
      std::unique_ptr<VideoOutput> instance;
      try {
        instance = std::make_unique<VideoOutput>(
            handle, configuration, registrar_, thread_pool_.get());
      } catch (const std::exception& ex) {
        if (error_callback) {
          error_callback(ex.what());
        }
        return;
      } catch (...) {
        if (error_callback) {
          error_callback("VideoOutput construction failed.");
        }
        return;
      }
      if (instance->init_failed()) {
        const std::string error = instance->init_error();
        instance.reset();
        if (error_callback) {
          error_callback(error);
        }
        return;
      }
      instance->SetTextureUpdateCallback(texture_update_callback);
      video_outputs_.insert(std::make_pair(handle, std::move(instance)));
    }
  });
}

flutter::EncodableMap VideoOutputManager::GetStats(int64_t handle) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = video_outputs_.find(handle);
  if (it == video_outputs_.end() || !it->second) {
    return flutter::EncodableMap{};
  }
  return it->second->GetStats();
}

void VideoOutputManager::SetSize(
    int64_t handle,
    std::optional<int64_t> width,
    std::optional<int64_t> height,
    std::function<void(bool, const std::string&)> done) {
  manager_pool_->Post([=, done = std::move(done)]() mutable {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = video_outputs_.find(handle);
    if (it != video_outputs_.end() && it->second) {
      it->second->SetSize(width, height, std::move(done));
    } else if (done) {
      done(false, "VideoOutput not found");
    }
  });
}

void VideoOutputManager::SetVisibility(
    int64_t handle,
    bool visible,
    std::function<void(bool, const std::string&)> done) {
  manager_pool_->Post([=, done = std::move(done)]() mutable {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = video_outputs_.find(handle);
    if (it != video_outputs_.end() && it->second) {
      it->second->SetVisibility(visible, std::move(done));
    } else if (done) {
      done(false, "VideoOutput not found");
    }
  });
}

void VideoOutputManager::TrimMemory() {
  manager_pool_->Post([this]() {
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto& entry : video_outputs_) {
      entry.second->TrimMemory();
    }
  });
}

void VideoOutputManager::Dispose(int64_t handle, std::function<void()> done) {
  manager_pool_->Post([=, done = std::move(done)]() {
    std::unique_ptr<VideoOutput> removed;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto it = video_outputs_.find(handle);
      if (it != video_outputs_.end()) {
        removed = std::move(it->second);
        video_outputs_.erase(it);
      }
    }
    // Destroy outside |mutex_| so teardown drains the worker & retires
    // textures without blocking other outputs.
    removed.reset();
    if (done) {
      done();
    }
  });
}

VideoOutputManager::~VideoOutputManager() {
  manager_pool_->Post([this]() {
    std::lock_guard<std::mutex> lock(mutex_);
    video_outputs_.clear();
  }).wait();
  manager_pool_.reset();
}
