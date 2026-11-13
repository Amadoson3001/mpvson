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
#include <mutex>

// |ANGLESurfaceManager| provides an abstraction around ANGLE to easily draw
// OpenGL ES 2.0 content & read as D3D 11 texture using shared |HANDLE|.
// * |Draw|: Takes callback where OpenGL ES 2.0 calls can be made for rendering,
//           then copies the complete frame to the inactive public texture and
//           publishes that HANDLE. Flutter samples the other public texture.
// * |Read|: No-op. Flutter's raster thread loads the published HANDLE without
//           waiting on the render mutex.

// A large part of implementation is inspired from Flutter.
// https://github.com/flutter/engine/blob/master/shell/platform/windows/angle_surface_manager.h

class ANGLESurfaceManager {
 public:
  const int32_t width() const { return width_; }
  const int32_t height() const { return height_; }
  const int32_t published_width() const {
    return published_width_.load(std::memory_order_relaxed);
  }
  const int32_t published_height() const {
    return published_height_.load(std::memory_order_relaxed);
  }
  const HANDLE handle() const {
    return published_handle_.load(std::memory_order_acquire);
  }

  ANGLESurfaceManager(int32_t width, int32_t height);

  ~ANGLESurfaceManager();

  void SetSize(int32_t width, int32_t height);

  void Draw(std::function<void()> callback, bool present = true);

  void Read();

  // Releases D3D residency and flushes pending GPU work. Serialized with
  // |Draw| and |SetSize| by the same mutex.
  void Trim();

  void MakeCurrent(bool value);

 private:
  void SwapBuffers();

  void Create();

  void CleanUp(bool release_context);

  // Recreates D3D textures and the EGL pbuffer without dropping the Flutter
  // texture ID. Previous public textures are retained only across the swap
  // transition and released after a few presented frames or on Trim.
  void RecreateSurface();

  void DestroyEGLSurface();

  void ReleasePreviousTextures();

  bool CreateD3DTexture();

  bool CreateSharedTexture(Microsoft::WRL::ComPtr<ID3D11Texture2D>& texture,
                           HANDLE* handle,
                           const D3D11_TEXTURE2D_DESC& desc);

  bool CreateEGLDisplay();

  bool CreateAndBindEGLSurface();

  void Publish(int index);

  int32_t width_ = 1;
  int32_t height_ = 1;
  HANDLE internal_handle_ = nullptr;
  HANDLE public_handle_[2] = {nullptr, nullptr};
  std::atomic<HANDLE> published_handle_{nullptr};
  std::atomic<int32_t> published_width_{1};
  std::atomic<int32_t> published_height_{1};
  int front_index_ = 0;
  bool angle_shares_d3d_device_ = false;

  // Sync |Draw|, |SetSize| and |Trim|. Flutter's raster thread reads the
  // published HANDLE without this lock.
  std::mutex mutex_;
  // D3D 11
  ID3D11Device* d3d_11_device_ = nullptr;
  ID3D11DeviceContext* d3d_11_device_context_ = nullptr;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> internal_d3d_11_texture_2D_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> public_texture_[2];
  Microsoft::WRL::ComPtr<ID3D11Texture2D> previous_internal_d3d_11_texture_2D_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> previous_public_texture_[2];
  int previous_textures_frames_remaining_ = 0;
  // ANGLE
  EGLSurface surface_ = EGL_NO_SURFACE;
  EGLDisplay display_ = EGL_NO_DISPLAY;
  EGLContext context_ = nullptr;
  EGLConfig config_ = nullptr;
  // GL texture object bound to the pbuffer surface via eglBindTexImage. Kept
  // so it can be deleted when the surface is destroyed (|CleanUp|), otherwise
  // it leaks on every resize and on teardown.
  GLuint tex_id_ = 0;

  static constexpr EGLint kEGLConfigurationAttributes[] = {
      EGL_RED_SIZE,   8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE,    8,
      EGL_ALPHA_SIZE, 8, EGL_DEPTH_SIZE, 0, EGL_STENCIL_SIZE, 0,
      EGL_NONE,
  };
  static constexpr EGLint kEGLContextAttributes[] = {
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
      EGL_PLATFORM_ANGLE_ENABLE_AUTOMATIC_TRIM_ANGLE,
      EGL_TRUE,
      EGL_NONE,
  };
  static constexpr EGLint kD3D9DisplayAttributes[] = {
      EGL_PLATFORM_ANGLE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_TYPE_D3D9_ANGLE,
      EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_DEVICE_TYPE_HARDWARE_ANGLE,
      EGL_NONE,
  };
  static constexpr EGLint kWrapDisplayAttributes[] = {
      EGL_PLATFORM_ANGLE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE,
      EGL_PLATFORM_ANGLE_ENABLE_AUTOMATIC_TRIM_ANGLE,
      EGL_TRUE,
      EGL_NONE,
  };

  // Number of active instances of ANGLESurfaceManager.
  static int32_t instance_count_;
};

#endif  // ANGLE_SURFACE_MANAGER_H_
