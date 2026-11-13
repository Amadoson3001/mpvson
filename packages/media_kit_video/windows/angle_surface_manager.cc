// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.
#include "angle_surface_manager.h"

#include <EGL/eglext_angle.h>
#include <dxgi1_3.h>

#include <iostream>
#include <stdexcept>

#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3d11.lib")

#define FAIL(message)                                                 \
  std::cout << "media_kit: ANGLESurfaceManager: Failure: " << message \
            << std::endl;                                             \
  return false

#define CHECK_HRESULT(message) \
  if (FAILED(hr)) {            \
    FAIL(message);             \
  }

int ANGLESurfaceManager::instance_count_ = 0;

ANGLESurfaceManager::ANGLESurfaceManager(int32_t width, int32_t height)
    : width_(width), height_(height) {
  Create();
  instance_count_++;
}

ANGLESurfaceManager::~ANGLESurfaceManager() {
  std::lock_guard<std::mutex> lock(mutex_);
  CleanUp(true);
  instance_count_--;
}

void ANGLESurfaceManager::SetSize(int32_t width, int32_t height) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (width == width_ && height == height_) {
    return;
  }
  width_ = width;
  height_ = height;
  RecreateSurface();
}

void ANGLESurfaceManager::Draw(std::function<void()> callback, bool present) {
  std::lock_guard<std::mutex> lock(mutex_);
  MakeCurrent(true);
  callback();
  if (!present) {
    MakeCurrent(false);
    return;
  }
  SwapBuffers();
  // Copy into the public texture Flutter is not sampling. The raster thread
  // only loads the published HANDLE, so this never blocks UI.
  const int back = 1 - front_index_;
  if (d3d_11_device_context_ != nullptr && internal_d3d_11_texture_2D_ &&
      public_texture_[back]) {
    d3d_11_device_context_->CopyResource(public_texture_[back].Get(),
                                         internal_d3d_11_texture_2D_.Get());
    d3d_11_device_context_->Flush();
    Publish(back);
    if (previous_textures_frames_remaining_ > 0) {
      --previous_textures_frames_remaining_;
      if (previous_textures_frames_remaining_ == 0) {
        ReleasePreviousTextures();
      }
    }
  }
  MakeCurrent(false);
}

void ANGLESurfaceManager::Publish(int index) {
  published_width_.store(width_, std::memory_order_relaxed);
  published_height_.store(height_, std::memory_order_relaxed);
  published_handle_.store(public_handle_[index], std::memory_order_release);
  front_index_ = index;
}

void ANGLESurfaceManager::Read() {
  // Flutter samples the published DXGI handle after this callback returns.
  // Do not wait on |mutex_|: |Draw| holds it for the whole GL submit.
}

void ANGLESurfaceManager::ReleasePreviousTextures() {
  previous_internal_d3d_11_texture_2D_.Reset();
  previous_public_texture_[0].Reset();
  previous_public_texture_[1].Reset();
  previous_textures_frames_remaining_ = 0;
}

void ANGLESurfaceManager::DestroyEGLSurface() {
  if (display_ != EGL_NO_DISPLAY && surface_ != EGL_NO_SURFACE &&
      tex_id_ != 0) {
    MakeCurrent(true);
    eglReleaseTexImage(display_, surface_, EGL_BACK_BUFFER);
    glDeleteTextures(1, &tex_id_);
    tex_id_ = 0;
    MakeCurrent(false);
  }
  if (display_ != EGL_NO_DISPLAY) {
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, context_);
  }
  if (display_ != EGL_NO_DISPLAY && surface_ != EGL_NO_SURFACE) {
    eglDestroySurface(display_, surface_);
  }
  surface_ = EGL_NO_SURFACE;
}

void ANGLESurfaceManager::RecreateSurface() {
  DestroyEGLSurface();
  // Keep the generation Flutter is still sampling until the next |Draw|
  // publishes a filled texture at the new size.
  ReleasePreviousTextures();
  previous_internal_d3d_11_texture_2D_ = internal_d3d_11_texture_2D_;
  previous_public_texture_[0] = public_texture_[0];
  previous_public_texture_[1] = public_texture_[1];
  previous_textures_frames_remaining_ = 4;
  internal_d3d_11_texture_2D_.Reset();
  public_texture_[0].Reset();
  public_texture_[1].Reset();
  internal_handle_ = nullptr;
  public_handle_[0] = nullptr;
  public_handle_[1] = nullptr;
  if (!CreateD3DTexture()) {
    throw std::runtime_error("Unable to create Windows Direct3D device.");
  }
  if (!CreateAndBindEGLSurface()) {
    throw std::runtime_error("Unable to create ANGLE EGL surface.");
  }
  if (internal_handle_ == nullptr || public_handle_[0] == nullptr ||
      public_handle_[1] == nullptr) {
    throw std::runtime_error("Unable to retrieve Direct3D shared HANDLE.");
  }
}

void ANGLESurfaceManager::Trim() {
  std::lock_guard<std::mutex> lock(mutex_);
  ReleasePreviousTextures();
  if (d3d_11_device_ != nullptr) {
    Microsoft::WRL::ComPtr<IDXGIDevice3> dxgi_device;
    if (SUCCEEDED(d3d_11_device_->QueryInterface(
            IID_PPV_ARGS(dxgi_device.GetAddressOf()))) &&
        dxgi_device) {
      dxgi_device->Trim();
    }
  }
  if (d3d_11_device_context_ != nullptr) {
    d3d_11_device_context_->Flush();
  }
}

void ANGLESurfaceManager::MakeCurrent(bool value) {
  if (value) {
    if (eglGetCurrentDisplay() == display_ &&
        eglGetCurrentContext() == context_ &&
        eglGetCurrentSurface(EGL_DRAW) == surface_ &&
        eglGetCurrentSurface(EGL_READ) == surface_) {
      return;
    }
    eglMakeCurrent(display_, surface_, surface_, context_);
  } else {
    if (eglGetCurrentContext() == EGL_NO_CONTEXT &&
        eglGetCurrentSurface(EGL_DRAW) == EGL_NO_SURFACE &&
        eglGetCurrentSurface(EGL_READ) == EGL_NO_SURFACE) {
      return;
    }
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  }
}

void ANGLESurfaceManager::SwapBuffers() {
  // Same-device ANGLE can submit with glFlush; CopyResource then waits on the
  // GPU. Separate devices still need glFinish so the copy is not stale.
  if (angle_shares_d3d_device_) {
    glFlush();
  } else {
    glFinish();
  }
}

void ANGLESurfaceManager::Create() {
  CleanUp(false);
  if (!CreateD3DTexture()) {
    throw std::runtime_error("Unable to create Windows Direct3D device.");
    return;
  }
  if (!CreateEGLDisplay()) {
    throw std::runtime_error("Unable to create ANGLE EGL display.");
    return;
  }
  if (!CreateAndBindEGLSurface()) {
    throw std::runtime_error("Unable to create ANGLE EGL surface.");
    return;
  }
  if (internal_handle_ == nullptr || public_handle_[0] == nullptr ||
      public_handle_[1] == nullptr) {
    throw std::runtime_error("Unable to retrieve Direct3D shared HANDLE.");
    return;
  }
}

void ANGLESurfaceManager::CleanUp(bool release_context) {
  if (release_context) {
    if (display_ != EGL_NO_DISPLAY && surface_ != EGL_NO_SURFACE) {
      eglReleaseTexImage(display_, surface_, EGL_BACK_BUFFER);
    }
    if (display_ != EGL_NO_DISPLAY && context_ != EGL_NO_CONTEXT &&
        surface_ != EGL_NO_SURFACE) {
      // Delete the GL texture object that was bound to the pbuffer surface.
      // glDeleteTextures requires a current context, so this happens while the
      // context & surface still exist.
      MakeCurrent(true);
      if (tex_id_ != 0) {
        glDeleteTextures(1, &tex_id_);
        tex_id_ = 0;
      }
      MakeCurrent(false);
    }
    if (display_ != EGL_NO_DISPLAY && context_ != EGL_NO_CONTEXT) {
      eglDestroyContext(display_, context_);
      context_ = EGL_NO_CONTEXT;
    }
    if (surface_ != EGL_NO_SURFACE) {
      eglDestroySurface(display_, surface_);
      surface_ = EGL_NO_SURFACE;
    }
    if (instance_count_ == 1) {
      eglTerminate(display_);
    }
    display_ = EGL_NO_DISPLAY;
    // Release D3D device & context if the instance is being destroyed.
    if (d3d_11_device_context_) {
      d3d_11_device_context_->Release();
      d3d_11_device_context_ = nullptr;
    }
    if (d3d_11_device_) {
      d3d_11_device_->Release();
      d3d_11_device_ = nullptr;
    }
  } else {
    // Clear context & destroy existing |surface_|.
    if (display_ != EGL_NO_DISPLAY && surface_ != EGL_NO_SURFACE &&
        tex_id_ != 0) {
      // Release the GL texture object bound to the surface & delete it before
      // the surface goes away, otherwise it leaks on every |Resize|.
      // glDeleteTextures requires a current context.
      MakeCurrent(true);
      eglReleaseTexImage(display_, surface_, EGL_BACK_BUFFER);
      glDeleteTextures(1, &tex_id_);
      tex_id_ = 0;
      MakeCurrent(false);
    }
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, context_);
    if (display_ != EGL_NO_DISPLAY && surface_ != EGL_NO_SURFACE) {
      eglDestroySurface(display_, surface_);
    }
    surface_ = EGL_NO_SURFACE;
  }
  // Release D3D 11 texture(s).
  internal_d3d_11_texture_2D_.Reset();
  public_texture_[0].Reset();
  public_texture_[1].Reset();
  internal_handle_ = nullptr;
  public_handle_[0] = nullptr;
  public_handle_[1] = nullptr;
  published_handle_.store(nullptr, std::memory_order_release);
  ReleasePreviousTextures();
}

bool ANGLESurfaceManager::CreateD3DTexture() {
  if (d3d_11_device_ == nullptr) {
    // NOTE: Not enabling Feature Level 12. It crashes directly on Windows 7.
    const auto feature_levels = {
        D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1,
        D3D_FEATURE_LEVEL_10_0,
        D3D_FEATURE_LEVEL_9_3,
    };

    // Kept in a |ComPtr| so the adapter (and the factory below) are released
    // when this function returns. D3D11CreateDevice takes its own reference,
    // so the one acquired here must not be leaked: a new set of interfaces is
    // acquired for every surface (re)creation, e.g. on each resize.
    Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
    D3D_DRIVER_TYPE driver_type = D3D_DRIVER_TYPE_UNKNOWN;

    // NOTE: Automatically selecting adapter on Windows 10 RTM or greater.
    if (Utils::IsWindows10RTMOrGreater()) {
      driver_type = D3D_DRIVER_TYPE_HARDWARE;
    } else {
      Microsoft::WRL::ComPtr<IDXGIFactory> dxgi;
      // As far as my experience goes, this is the safest approach. Passing NULL
      // (so-called default) seems to cause issues on Windows 7 or maybe some
      // older graphics drivers. First adapter is the default.
      // D3D_DRIVER_TYPE_UNKNOWN| must be passed with manual adapter selection.
      if (SUCCEEDED(
              ::CreateDXGIFactory(IID_PPV_ARGS(dxgi.GetAddressOf()))) &&
          dxgi) {
        dxgi->EnumAdapters(0, adapter.GetAddressOf());
      }
    }

    auto hr = ::D3D11CreateDevice(
        adapter.Get(), driver_type, 0, 0, feature_levels.begin(),
        static_cast<UINT>(feature_levels.size()), D3D11_SDK_VERSION,
        &d3d_11_device_, 0, &d3d_11_device_context_);
    CHECK_HRESULT("D3D11CreateDevice");
  }

  Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device = nullptr;
  auto dxgi_device_success = d3d_11_device_->QueryInterface(
      __uuidof(IDXGIDevice), (void**)&dxgi_device);
  if (SUCCEEDED(dxgi_device_success) && dxgi_device != nullptr) {
    dxgi_device->SetGPUThreadPriority(5);  // Must be in interval [-7, 7].
  }

  auto level = d3d_11_device_->GetFeatureLevel();
  std::cout << "media_kit: ANGLESurfaceManager: Direct3D Feature Level: "
            << (((unsigned)level) >> 12) << "_"
            << ((((unsigned)level) >> 8) & 0xf) << std::endl;
  auto d3d11_texture2D_desc = D3D11_TEXTURE2D_DESC{0};
  d3d11_texture2D_desc.Width = width_;
  d3d11_texture2D_desc.Height = height_;
  d3d11_texture2D_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  d3d11_texture2D_desc.MipLevels = 1;
  d3d11_texture2D_desc.ArraySize = 1;
  d3d11_texture2D_desc.SampleDesc.Count = 1;
  d3d11_texture2D_desc.SampleDesc.Quality = 0;
  d3d11_texture2D_desc.Usage = D3D11_USAGE_DEFAULT;
  d3d11_texture2D_desc.BindFlags =
      D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  d3d11_texture2D_desc.CPUAccessFlags = 0;
  d3d11_texture2D_desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;

  // Internal texture is the ANGLE draw target. Two public textures ping-pong
  // so Flutter can sample a complete frame while the next copy runs.
  if (!CreateSharedTexture(internal_d3d_11_texture_2D_, &internal_handle_,
                           d3d11_texture2D_desc)) {
    return false;
  }
  if (!CreateSharedTexture(public_texture_[0], &public_handle_[0],
                           d3d11_texture2D_desc)) {
    return false;
  }
  if (!CreateSharedTexture(public_texture_[1], &public_handle_[1],
                           d3d11_texture2D_desc)) {
    return false;
  }
  // First construction publishes an empty 1x1. Resizes keep the previous
  // HANDLE until |Draw| fills and publishes a new one.
  if (published_handle_.load(std::memory_order_acquire) == nullptr) {
    Publish(0);
  }
  return true;
}

bool ANGLESurfaceManager::CreateSharedTexture(
    Microsoft::WRL::ComPtr<ID3D11Texture2D>& texture,
    HANDLE* handle,
    const D3D11_TEXTURE2D_DESC& desc) {
  auto hr = d3d_11_device_->CreateTexture2D(&desc, nullptr, &texture);
  CHECK_HRESULT("ID3D11Device::CreateTexture2D");
  auto resource = Microsoft::WRL::ComPtr<IDXGIResource>{};
  hr = texture.As(&resource);
  CHECK_HRESULT("ID3D11Texture2D::As");
  hr = resource->GetSharedHandle(handle);
  CHECK_HRESULT("IDXGIResource::GetSharedHandle");
  return true;
}

bool ANGLESurfaceManager::CreateEGLDisplay() {
  if (display_ != EGL_NO_DISPLAY) {
    return true;
  }
  auto eglGetPlatformDisplayEXT =
      reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
          eglGetProcAddress("eglGetPlatformDisplayEXT"));
  if (!eglGetPlatformDisplayEXT) {
    FAIL("eglGetProcAddress");
  }

  auto try_display = [&](void* native_display, const EGLint* attribs) {
    display_ = eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE,
                                        native_display, attribs);
    if (display_ != EGL_NO_DISPLAY &&
        eglInitialize(display_, 0, 0) != EGL_FALSE) {
      return true;
    }
    if (display_ != EGL_NO_DISPLAY) {
      eglTerminate(display_);
    }
    display_ = EGL_NO_DISPLAY;
    return false;
  };

  // Prefer wrapping the existing D3D device so CopyResource is same-device
  // and does not need a CPU stall.
  auto eglCreateDeviceANGLE =
      reinterpret_cast<PFNEGLCREATEDEVICEANGLEPROC>(
          eglGetProcAddress("eglCreateDeviceANGLE"));
  auto eglReleaseDeviceANGLE =
      reinterpret_cast<PFNEGLRELEASEDEVICEANGLEPROC>(
          eglGetProcAddress("eglReleaseDeviceANGLE"));
  if (eglCreateDeviceANGLE && d3d_11_device_ != nullptr) {
    EGLDeviceEXT device = eglCreateDeviceANGLE(
        EGL_D3D11_DEVICE_ANGLE, d3d_11_device_, nullptr);
    if (device != EGL_NO_DEVICE_EXT) {
      auto try_device_display = [&](const EGLint* attribs) {
        display_ = eglGetPlatformDisplayEXT(EGL_PLATFORM_DEVICE_EXT, device,
                                            attribs);
        if (display_ != EGL_NO_DISPLAY &&
            eglInitialize(display_, 0, 0) != EGL_FALSE) {
          return true;
        }
        if (display_ != EGL_NO_DISPLAY) {
          eglTerminate(display_);
        }
        display_ = EGL_NO_DISPLAY;
        return false;
      };
      if (try_device_display(kD3D11DisplayAttributes) ||
          try_device_display(nullptr)) {
        angle_shares_d3d_device_ = true;
        std::cout
            << "media_kit: ANGLESurfaceManager: ANGLE shares the D3D11 device."
            << std::endl;
        return true;
      }
      if (eglReleaseDeviceANGLE) {
        eglReleaseDeviceANGLE(device);
      }
    }
  }

  angle_shares_d3d_device_ = false;
  if (try_display(EGL_DEFAULT_DISPLAY, kD3D11DisplayAttributes) ||
      try_display(EGL_DEFAULT_DISPLAY, kD3D11_9_3DisplayAttributes) ||
      try_display(EGL_DEFAULT_DISPLAY, kD3D9DisplayAttributes) ||
      try_display(EGL_DEFAULT_DISPLAY, kWrapDisplayAttributes)) {
    return true;
  }
  FAIL("eglGetPlatformDisplayEXT");
}

bool ANGLESurfaceManager::CreateAndBindEGLSurface() {
  // Do not create |context_| again, likely due to |Resize|.
  if (context_ == EGL_NO_CONTEXT) {
    // First time from the constructor itself.
    auto count = 0;
    auto result = eglChooseConfig(display_, kEGLConfigurationAttributes,
                                  &config_, 1, &count);
    if (result == EGL_FALSE || count == 0) {
      FAIL("eglChooseConfig");
    }
    context_ = eglCreateContext(display_, config_, EGL_NO_CONTEXT,
                                kEGLContextAttributes);
    if (context_ == EGL_NO_CONTEXT) {
      FAIL("eglCreateContext");
    }
  }
  EGLint buffer_attributes[] = {
      EGL_WIDTH,          width_,         EGL_HEIGHT,         height_,
      EGL_TEXTURE_TARGET, EGL_TEXTURE_2D, EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
      EGL_NONE,
  };
  surface_ = eglCreatePbufferFromClientBuffer(
      display_, EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE, internal_handle_,
      config_, buffer_attributes);
  if (surface_ == EGL_NO_SURFACE) {
    FAIL("eglCreatePbufferFromClientBuffer");
  }
  glGenTextures(1, &tex_id_);
  glBindTexture(GL_TEXTURE_2D, tex_id_);
  eglBindTexImage(display_, surface_, EGL_BACK_BUFFER);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  return true;
}
