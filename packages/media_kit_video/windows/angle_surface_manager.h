// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#ifndef ANGLE_SURFACE_MANAGER_H_
#define ANGLE_SURFACE_MANAGER_H_

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglplatform.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#include <Windows.h>

#include <d3d.h>
#include <d3d11.h>
#include <wrl.h>

#include "utils.h"

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>

// |ANGLESurfaceManager| provides an abstraction around ANGLE to easily draw
// OpenGL ES 2.0 content & read as D3D 11 texture using shared |HANDLE|.
// * |Draw|: Takes callback where OpenGL ES 2.0 calls can be made for rendering,
//           then copies the complete frame to the public texture and publishes
//           an atomic snapshot.
// * |CopyPublishedSnapshot|: Thread-safe snapshot of the latest published
//           shared handle, dimensions, generation, and backing refcount.

class ANGLESurfaceManager {
 public:
  struct SurfaceBacking {
    int32_t width = 1;
    int32_t height = 1;
    uint64_t generation = 0;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> internal_texture;
    static constexpr int kMaxPublicSlots = 3;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> public_textures[kMaxPublicSlots];
    Microsoft::WRL::ComPtr<ID3D11Query> copy_queries[kMaxPublicSlots];
    bool query_issued[kMaxPublicSlots] = {false, false, false};
    HANDLE internal_handle = nullptr;
    HANDLE public_handles[kMaxPublicSlots] = {nullptr, nullptr, nullptr};
    int slot_count = 1;
    int next_slot = 0;
    int published_slot = -1;
  };

  struct PublishedSurface {
    std::shared_ptr<SurfaceBacking> backing;
    HANDLE handle = nullptr;
    int32_t width = 1;
    int32_t height = 1;
    uint64_t generation = 0;
    uint64_t publish_count = 0;
  };

  int32_t width() const { return width_; }
  int32_t height() const { return height_; }
  int64_t adapter_luid() const { return adapter_luid_; }
  const std::string& adapter_name() const { return adapter_name_; }
  uint64_t resize_allocations() const {
    return resize_allocations_.load(std::memory_order_relaxed);
  }
  uint64_t publish_count() const {
    return publish_count_.load(std::memory_order_relaxed);
  }
  int64_t last_copy_submit_us() const {
    return last_copy_submit_us_.load(std::memory_order_relaxed);
  }
  uint64_t gpu_missed_publishes() const {
    return gpu_missed_publishes_.load(std::memory_order_relaxed);
  }

  PublishedSurface CopyPublishedSnapshot() const {
    std::lock_guard<std::mutex> lock(publish_mutex_);
    return published_;
  }

  ANGLESurfaceManager(int32_t width, int32_t height);

  ~ANGLESurfaceManager();

  bool SetSize(int32_t width, int32_t height);

  bool Draw(const std::function<bool()>& callback, bool present = true);

  void Read();

  // Releases D3D residency and flushes pending GPU work. Serialized with
  // |Draw| and |SetSize| by the same mutex.
  void Trim();

  bool MakeCurrent(bool value);

 private:
  void SwapBuffers();

  void Create();

  void CleanUp(bool release_context);

  // Transactionally allocates new D3D textures and an EGL pbuffer at
  // |width|x|height| without dropping the Flutter texture ID or losing the
  // previously published frame if allocation/bind fails.
  bool RecreateSurface(int32_t width, int32_t height);

  bool EnsureD3DDevice();

  bool CreateBacking(int32_t width,
                     int32_t height,
                     uint64_t generation,
                     std::shared_ptr<SurfaceBacking>* out_backing);

  bool CreateSharedTexture(Microsoft::WRL::ComPtr<ID3D11Texture2D>& texture,
                           HANDLE* handle,
                           const D3D11_TEXTURE2D_DESC& desc);

  bool CreateEGLDisplay();

  bool CreateAndBindEGLSurface(HANDLE internal_handle,
                               int32_t width,
                               int32_t height,
                               EGLSurface* out_surface,
                               GLuint* out_tex_id);

  void DestroyEGLSurface(EGLSurface* surface, GLuint* tex_id);

  void Publish(const std::shared_ptr<SurfaceBacking>& backing, int slot);

  int32_t width_ = 1;
  int32_t height_ = 1;
  uint64_t generation_ = 0;
  bool angle_shares_d3d_device_ = false;
  int64_t adapter_luid_ = 0;
  std::string adapter_name_;

  std::atomic<uint64_t> resize_allocations_{0};
  std::atomic<uint64_t> publish_count_{0};
  std::atomic<int64_t> last_copy_submit_us_{0};
  std::atomic<uint64_t> gpu_missed_publishes_{0};

  // Sync |Draw|, |SetSize| and |Trim|.
  std::mutex mutex_;
  mutable std::mutex publish_mutex_;
  PublishedSurface published_;

  // D3D 11
  ID3D11Device* d3d_11_device_ = nullptr;
  ID3D11DeviceContext* d3d_11_device_context_ = nullptr;
  std::shared_ptr<SurfaceBacking> active_backing_;

  // ANGLE
  EGLSurface surface_ = EGL_NO_SURFACE;
  EGLDisplay display_ = EGL_NO_DISPLAY;
  EGLContext context_ = nullptr;
  EGLConfig config_ = nullptr;
  GLuint tex_id_ = 0;

  static constexpr EGLint kEGLConfigurationAttributes[] = {
      EGL_RED_SIZE,   8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE,    8,
      EGL_ALPHA_SIZE, 8, EGL_DEPTH_SIZE, 0, EGL_STENCIL_SIZE, 0,
      EGL_NONE,
  };
  static constexpr EGLint kEGLContextAttributesES3[] = {
      EGL_CONTEXT_CLIENT_VERSION,
      3,
      EGL_NONE,
  };
  static constexpr EGLint kEGLContextAttributesES2[] = {
      EGL_CONTEXT_CLIENT_VERSION,
      2,
      EGL_NONE,
  };
  static constexpr EGLint kD3D11DisplayAttributes[] = {
      EGL_PLATFORM_ANGLE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE,
      EGL_PLATFORM_ANGLE_ENABLE_AUTOMATIC_TRIM_ANGLE,
      EGL_TRUE,
      EGL_NONE,
  };
  static constexpr EGLint kD3D11_9_3DisplayAttributes[] = {
      EGL_PLATFORM_ANGLE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE,
      EGL_PLATFORM_ANGLE_MAX_VERSION_MAJOR_ANGLE,
      9,
      EGL_PLATFORM_ANGLE_MAX_VERSION_MINOR_ANGLE,
      3,
      EGL_NONE,
  };
  static constexpr EGLint kD3D9DisplayAttributes[] = {
      EGL_PLATFORM_ANGLE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_TYPE_D3D9_ANGLE,
      EGL_NONE,
  };
  static constexpr EGLint kWrapDisplayAttributes[] = {
      EGL_PLATFORM_ANGLE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE,
      EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_DEVICE_TYPE_D3D_WARP_ANGLE,
      EGL_NONE,
  };

  static int instance_count_;
};

#endif  // ANGLE_SURFACE_MANAGER_H_
