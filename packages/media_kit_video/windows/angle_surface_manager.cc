// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.
#include "angle_surface_manager.h"

#include <EGL/eglext_angle.h>
#include <dxgi1_6.h>

#include <chrono>
#include <cstdlib>
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

static bool IsRingPoolEnabled() {
  wchar_t buf[16]{};
  const DWORD len =
      ::GetEnvironmentVariableW(L"MPVSON_GPU_RING_POOL", buf, 16);
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

static std::string Utf8FromWide(const wchar_t* wide) {
  if (!wide || wide[0] == L'\0') return {};
  const int needed =
      ::WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr, nullptr);
  if (needed <= 1) return {};
  std::string out(static_cast<size_t>(needed - 1), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide, -1, out.data(), needed, nullptr,
                        nullptr);
  return out;
}

static bool TryFlutterCompositorAdapter(
    Microsoft::WRL::ComPtr<IDXGIAdapter>& adapter) {
  wchar_t buffer[64]{};
  const DWORD len =
      ::GetEnvironmentVariableW(L"MPVSON_FLUTTER_ADAPTER_LUID", buffer, 64);
  if (len == 0 || len >= 64) {
    return false;
  }
  wchar_t* end = nullptr;
  const int64_t raw = _wcstoi64(buffer, &end, 10);
  if (end == buffer || raw == 0) {
    return false;
  }
  Microsoft::WRL::ComPtr<IDXGIFactory1> factory1;
  if (FAILED(::CreateDXGIFactory1(IID_PPV_ARGS(factory1.GetAddressOf()))) ||
      !factory1) {
    return false;
  }
  Microsoft::WRL::ComPtr<IDXGIFactory4> factory4;
  if (FAILED(factory1.As(&factory4)) || !factory4) {
    return false;
  }
  LUID luid{};
  const uint64_t uval = static_cast<uint64_t>(raw);
  luid.LowPart = static_cast<DWORD>(uval & 0xFFFFFFFFu);
  luid.HighPart = static_cast<LONG>(uval >> 32);
  Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter1;
  if (FAILED(factory4->EnumAdapterByLuid(luid,
                                         IID_PPV_ARGS(adapter1.GetAddressOf()))) ||
      !adapter1) {
    return false;
  }
  DXGI_ADAPTER_DESC1 desc{};
  if (SUCCEEDED(adapter1->GetDesc1(&desc))) {
    if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) {
      return false;
    }
    std::wcout << L"media_kit: ANGLESurfaceManager: Matched Flutter GPU: "
               << desc.Description << std::endl;
  }
  adapter = adapter1;
  return true;
}

static bool TryHighPerformanceAdapter(
    Microsoft::WRL::ComPtr<IDXGIAdapter>& adapter) {
  Microsoft::WRL::ComPtr<IDXGIFactory1> factory;
  if (FAILED(::CreateDXGIFactory1(IID_PPV_ARGS(factory.GetAddressOf()))) ||
      !factory) {
    return false;
  }
  Microsoft::WRL::ComPtr<IDXGIFactory6> factory6;
  if (FAILED(factory.As(&factory6)) || !factory6) {
    return false;
  }
  Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter1;
  if (FAILED(factory6->EnumAdapterByGpuPreference(
          0, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
          IID_PPV_ARGS(adapter1.GetAddressOf()))) ||
      !adapter1) {
    return false;
  }
  DXGI_ADAPTER_DESC1 desc{};
  if (SUCCEEDED(adapter1->GetDesc1(&desc))) {
    if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) {
      return false;
    }
    std::wcout << L"media_kit: ANGLESurfaceManager: GPU: " << desc.Description
               << std::endl;
  }
  adapter = adapter1;
  return true;
}

ANGLESurfaceManager::ANGLESurfaceManager(int32_t width, int32_t height)
    : width_(width), height_(height) {
  try {
    Create();
    instance_count_++;
  } catch (...) {
    CleanUp(true);
    throw;
  }
}

ANGLESurfaceManager::~ANGLESurfaceManager() {
  std::lock_guard<std::mutex> lock(mutex_);
  CleanUp(true);
  instance_count_--;
}

bool ANGLESurfaceManager::SetSize(int32_t width, int32_t height) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (width < 1 || height < 1) {
    return false;
  }
  if (width == width_ && height == height_ && active_backing_ != nullptr) {
    return true;
  }
  return RecreateSurface(width, height);
}

bool ANGLESurfaceManager::Draw(const std::function<bool()>& callback,
                               bool present) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (surface_ == EGL_NO_SURFACE || active_backing_ == nullptr) {
    return false;
  }
  if (!MakeCurrent(true)) {
    return false;
  }
  const bool ok = callback();
  if (!ok || !present) {
    MakeCurrent(false);
    return ok;
  }
  const auto copy_start = std::chrono::steady_clock::now();
  SwapBuffers();
  int slot = active_backing_->next_slot;
  if (active_backing_->slot_count > 1 && d3d_11_device_context_ != nullptr) {
    int chosen = -1;
    for (int offset = 0; offset < active_backing_->slot_count; ++offset) {
      const int candidate =
          (active_backing_->next_slot + offset) % active_backing_->slot_count;
      if (candidate == active_backing_->published_slot) {
        continue;
      }
      if (!active_backing_->query_issued[candidate] ||
          !active_backing_->copy_queries[candidate] ||
          d3d_11_device_context_->GetData(
              active_backing_->copy_queries[candidate].Get(), nullptr, 0,
              D3D11_ASYNC_GETDATA_DONOTFLUSH) == S_OK) {
        chosen = candidate;
        break;
      }
    }
    if (chosen < 0) {
      gpu_missed_publishes_.fetch_add(1, std::memory_order_relaxed);
      MakeCurrent(false);
      return true;
    }
    slot = chosen;
  }
  if (d3d_11_device_context_ != nullptr &&
      active_backing_->internal_texture &&
      active_backing_->public_textures[slot]) {
    d3d_11_device_context_->CopyResource(
        active_backing_->public_textures[slot].Get(),
        active_backing_->internal_texture.Get());
    d3d_11_device_context_->Flush();
    if (active_backing_->copy_queries[slot]) {
      d3d_11_device_context_->End(active_backing_->copy_queries[slot].Get());
      active_backing_->query_issued[slot] = true;
    }
    const auto copy_end = std::chrono::steady_clock::now();
    last_copy_submit_us_.store(
        std::chrono::duration_cast<std::chrono::microseconds>(copy_end -
                                                              copy_start)
            .count(),
        std::memory_order_relaxed);
    active_backing_->published_slot = slot;
    Publish(active_backing_, slot);
    active_backing_->next_slot = (slot + 1) % active_backing_->slot_count;
  }
  MakeCurrent(false);
  return true;
}

void ANGLESurfaceManager::Publish(
    const std::shared_ptr<SurfaceBacking>& backing,
    int slot) {
  if (!backing) return;
  const uint64_t next_publish =
      publish_count_.fetch_add(1, std::memory_order_relaxed) + 1;
  {
    std::lock_guard<std::mutex> lock(publish_mutex_);
    published_.backing = backing;
    published_.handle = backing->public_handles[slot];
    published_.width = backing->width;
    published_.height = backing->height;
    published_.generation = backing->generation;
    published_.publish_count = next_publish;
  }
}

void ANGLESurfaceManager::Read() {
  // Snapshot is copied atomically in |CopyPublishedSnapshot| under
  // |publish_mutex_|, which is never held across GPU/GL work.
}

void ANGLESurfaceManager::DestroyEGLSurface(EGLSurface* surface,
                                            GLuint* tex_id) {
  if (display_ != EGL_NO_DISPLAY && *surface != EGL_NO_SURFACE &&
      *tex_id != 0) {
    if (eglMakeCurrent(display_, *surface, *surface, context_) != EGL_FALSE) {
      eglReleaseTexImage(display_, *surface, EGL_BACK_BUFFER);
      glDeleteTextures(1, tex_id);
      *tex_id = 0;
    }
  }
  if (display_ != EGL_NO_DISPLAY) {
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, context_);
  }
  if (display_ != EGL_NO_DISPLAY && *surface != EGL_NO_SURFACE) {
    eglDestroySurface(display_, *surface);
  }
  *surface = EGL_NO_SURFACE;
}

bool ANGLESurfaceManager::RecreateSurface(int32_t width, int32_t height) {
  const uint64_t next_gen = generation_ + 1;
  std::shared_ptr<SurfaceBacking> next_backing;
  if (!CreateBacking(width, height, next_gen, &next_backing)) {
    return false;
  }
  EGLSurface next_surface = EGL_NO_SURFACE;
  GLuint next_tex_id = 0;
  if (!CreateAndBindEGLSurface(next_backing->internal_handle, width, height,
                               &next_surface, &next_tex_id)) {
    DestroyEGLSurface(&next_surface, &next_tex_id);
    return false;
  }
  // Commit transactionally: release the previous EGL surface/texture and
  // install the new backing. |published_| continues to hold the previous
  // backing until the next successful |Draw| publishes the new frame.
  DestroyEGLSurface(&surface_, &tex_id_);
  surface_ = next_surface;
  tex_id_ = next_tex_id;
  active_backing_ = std::move(next_backing);
  width_ = width;
  height_ = height;
  generation_ = next_gen;
  resize_allocations_.fetch_add(1, std::memory_order_relaxed);
  return true;
}

void ANGLESurfaceManager::Trim() {
  std::lock_guard<std::mutex> lock(mutex_);
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

bool ANGLESurfaceManager::MakeCurrent(bool value) {
  if (display_ == EGL_NO_DISPLAY) return !value;
  if (value) {
    if (eglGetCurrentDisplay() == display_ &&
        eglGetCurrentContext() == context_ &&
        eglGetCurrentSurface(EGL_DRAW) == surface_ &&
        eglGetCurrentSurface(EGL_READ) == surface_) {
      return true;
    }
    return eglMakeCurrent(display_, surface_, surface_, context_) != EGL_FALSE;
  } else {
    if (eglGetCurrentContext() == EGL_NO_CONTEXT &&
        eglGetCurrentSurface(EGL_DRAW) == EGL_NO_SURFACE &&
        eglGetCurrentSurface(EGL_READ) == EGL_NO_SURFACE) {
      return true;
    }
    return eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE,
                          EGL_NO_CONTEXT) != EGL_FALSE;
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
  if (!EnsureD3DDevice()) {
    throw std::runtime_error("Unable to create Windows Direct3D device.");
  }
  if (!CreateEGLDisplay()) {
    throw std::runtime_error("Unable to create ANGLE EGL display.");
  }
  std::shared_ptr<SurfaceBacking> initial_backing;
  if (!CreateBacking(width_, height_, 1, &initial_backing)) {
    throw std::runtime_error("Unable to create Direct3D shared texture.");
  }
  if (!CreateAndBindEGLSurface(initial_backing->internal_handle, width_,
                               height_, &surface_, &tex_id_)) {
    DestroyEGLSurface(&surface_, &tex_id_);
    throw std::runtime_error("Unable to create ANGLE EGL surface.");
  }
  active_backing_ = std::move(initial_backing);
  generation_ = 1;
  Publish(active_backing_, 0);
}

void ANGLESurfaceManager::CleanUp(bool release_context) {
  {
    std::lock_guard<std::mutex> lock(publish_mutex_);
    published_ = PublishedSurface{};
  }
  DestroyEGLSurface(&surface_, &tex_id_);
  active_backing_.reset();

  if (release_context) {
    if (display_ != EGL_NO_DISPLAY && context_ != EGL_NO_CONTEXT) {
      eglDestroyContext(display_, context_);
      context_ = EGL_NO_CONTEXT;
    }
    if (display_ != EGL_NO_DISPLAY && instance_count_ == 1) {
      eglTerminate(display_);
    }
    display_ = EGL_NO_DISPLAY;
    if (d3d_11_device_context_) {
      d3d_11_device_context_->Release();
      d3d_11_device_context_ = nullptr;
    }
    if (d3d_11_device_) {
      d3d_11_device_->Release();
      d3d_11_device_ = nullptr;
    }
  }
}

bool ANGLESurfaceManager::EnsureD3DDevice() {
  if (d3d_11_device_ == nullptr) {
    const auto feature_levels = {
        D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1,
        D3D_FEATURE_LEVEL_10_0,
        D3D_FEATURE_LEVEL_9_3,
    };

    Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
    D3D_DRIVER_TYPE driver_type = D3D_DRIVER_TYPE_UNKNOWN;

    if (TryFlutterCompositorAdapter(adapter)) {
      driver_type = D3D_DRIVER_TYPE_UNKNOWN;
    } else if (TryHighPerformanceAdapter(adapter)) {
      driver_type = D3D_DRIVER_TYPE_UNKNOWN;
    } else if (Utils::IsWindows10RTMOrGreater()) {
      driver_type = D3D_DRIVER_TYPE_HARDWARE;
    } else {
      Microsoft::WRL::ComPtr<IDXGIFactory> dxgi;
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

    if (IsForcedAngleFailStage(L"device")) {
      FAIL("Forced ANGLE failure after device creation");
    }

    Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device;
    if (SUCCEEDED(d3d_11_device_->QueryInterface(
            IID_PPV_ARGS(dxgi_device.GetAddressOf()))) &&
        dxgi_device) {
      dxgi_device->SetGPUThreadPriority(5);
      Microsoft::WRL::ComPtr<IDXGIAdapter> actual_adapter;
      if (SUCCEEDED(dxgi_device->GetAdapter(actual_adapter.GetAddressOf())) &&
          actual_adapter) {
        DXGI_ADAPTER_DESC desc{};
        if (SUCCEEDED(actual_adapter->GetDesc(&desc))) {
          const uint64_t high = static_cast<uint64_t>(
              static_cast<uint32_t>(desc.AdapterLuid.HighPart));
          const uint64_t low = static_cast<uint64_t>(desc.AdapterLuid.LowPart);
          adapter_luid_ = static_cast<int64_t>((high << 32) | low);
          adapter_name_ = Utf8FromWide(desc.Description);
        }
      }
    }

    auto level = d3d_11_device_->GetFeatureLevel();
    std::cout << "media_kit: ANGLESurfaceManager: Direct3D Feature Level: "
              << (((unsigned)level) >> 12) << "_"
              << ((((unsigned)level) >> 8) & 0xf) << std::endl;
  }
  return true;
}

bool ANGLESurfaceManager::CreateBacking(
    int32_t width,
    int32_t height,
    uint64_t generation,
    std::shared_ptr<SurfaceBacking>* out_backing) {
  if (!EnsureD3DDevice()) {
    return false;
  }
  auto backing = std::make_shared<SurfaceBacking>();
  backing->width = width;
  backing->height = height;
  backing->generation = generation;

  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = width;
  desc.Height = height;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.SampleDesc.Count = 1;
  desc.SampleDesc.Quality = 0;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  desc.CPUAccessFlags = 0;
  desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;

  if (!CreateSharedTexture(backing->internal_texture, &backing->internal_handle,
                           desc)) {
    return false;
  }
  backing->slot_count =
      IsRingPoolEnabled() ? SurfaceBacking::kMaxPublicSlots : 1;
  D3D11_QUERY_DESC query_desc{};
  query_desc.Query = D3D11_QUERY_EVENT;
  for (int i = 0; i < backing->slot_count; ++i) {
    if (!CreateSharedTexture(backing->public_textures[i],
                             &backing->public_handles[i], desc)) {
      return false;
    }
    if (backing->public_handles[i] == nullptr) {
      FAIL("CreateBacking: null public shared HANDLE");
    }
    if (d3d_11_device_ != nullptr) {
      d3d_11_device_->CreateQuery(&query_desc,
                                  backing->copy_queries[i].GetAddressOf());
    }
  }
  if (backing->internal_handle == nullptr) {
    FAIL("CreateBacking: null internal shared HANDLE");
  }
  *out_backing = std::move(backing);
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

bool ANGLESurfaceManager::CreateAndBindEGLSurface(HANDLE internal_handle,
                                                  int32_t width,
                                                  int32_t height,
                                                  EGLSurface* out_surface,
                                                  GLuint* out_tex_id) {
  if (context_ == EGL_NO_CONTEXT) {
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
      EGL_WIDTH,          width,         EGL_HEIGHT,         height,
      EGL_TEXTURE_TARGET, EGL_TEXTURE_2D, EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
      EGL_NONE,
  };
  EGLSurface surface = eglCreatePbufferFromClientBuffer(
      display_, EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE, internal_handle,
      config_, buffer_attributes);
  if (surface == EGL_NO_SURFACE) {
    FAIL("eglCreatePbufferFromClientBuffer");
  }
  if (eglMakeCurrent(display_, surface, surface, context_) == EGL_FALSE) {
    eglDestroySurface(display_, surface);
    FAIL("eglMakeCurrent");
  }
  GLuint tex_id = 0;
  glGenTextures(1, &tex_id);
  glBindTexture(GL_TEXTURE_2D, tex_id);
  if (eglBindTexImage(display_, surface, EGL_BACK_BUFFER) == EGL_FALSE) {
    glDeleteTextures(1, &tex_id);
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroySurface(display_, surface);
    FAIL("eglBindTexImage");
  }
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  *out_surface = surface;
  *out_tex_id = tex_id;
  return true;
}
