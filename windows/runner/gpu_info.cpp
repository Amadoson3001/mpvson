#include "gpu_info.h"

#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <d3d11.h>
#include <dxgi1_6.h>
#include <wrl/client.h>

#include <cstdint>
#include <optional>
#include <string>
#include <unordered_set>
#include <wchar.h>
#include <utility>
#include <vector>

#include "utils.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

constexpr wchar_t kGpuPreferencesKey[] =
    L"Software\\Microsoft\\DirectX\\UserGpuPreferences";
constexpr wchar_t kGpuPreferenceToken[] = L"GpuPreference=";
constexpr size_t kGpuPreferencePrefixLength =
    (sizeof(kGpuPreferenceToken) / sizeof(wchar_t)) - 1;
constexpr SIZE_T kIntegratedMemoryThreshold = 512ull * 1024 * 1024;

int64_t LuidToInt64(const LUID& luid) {
  const uint64_t high =
      static_cast<uint64_t>(static_cast<uint32_t>(luid.HighPart));
  const uint64_t low = static_cast<uint64_t>(luid.LowPart);
  return static_cast<int64_t>((high << 32) | low);
}

int64_t BytesToInt64(SIZE_T value) {
  return static_cast<int64_t>(value);
}

std::wstring ExecutablePath() {
  std::wstring buffer(MAX_PATH, L'\0');
  for (;;) {
    const DWORD length = ::GetModuleFileNameW(
        nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0) return {};
    if (static_cast<size_t>(length) < buffer.size()) {
      buffer.resize(length);
      return buffer;
    }
    buffer.resize(buffer.size() * 2);
  }
}

bool ReadPreferenceValue(std::wstring* value) {
  const std::wstring name = ExecutablePath();
  if (name.empty()) return false;

  HKEY key = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, kGpuPreferencesKey, 0, KEY_QUERY_VALUE,
                      &key) != ERROR_SUCCESS) {
    return false;
  }

  DWORD type = 0;
  DWORD size = 0;
  LSTATUS status =
      ::RegQueryValueExW(key, name.c_str(), nullptr, &type, nullptr, &size);
  if (status != ERROR_SUCCESS ||
      (type != REG_SZ && type != REG_EXPAND_SZ) ||
      size < sizeof(wchar_t)) {
    ::RegCloseKey(key);
    return false;
  }

  std::wstring buffer(size / sizeof(wchar_t), L'\0');
  DWORD bytes = static_cast<DWORD>(buffer.size() * sizeof(wchar_t));
  status = ::RegQueryValueExW(key, name.c_str(), nullptr, &type,
                              reinterpret_cast<LPBYTE>(buffer.data()), &bytes);
  ::RegCloseKey(key);
  if (status != ERROR_SUCCESS) return false;

  buffer.resize(bytes / sizeof(wchar_t));
  const size_t terminator = buffer.find(L'\0');
  if (terminator != std::wstring::npos) buffer.resize(terminator);
  *value = std::move(buffer);
  return true;
}

bool WritePreferenceValue(const std::wstring& value) {
  const std::wstring name = ExecutablePath();
  if (name.empty()) return false;

  HKEY key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, kGpuPreferencesKey, 0, nullptr, 0,
                        KEY_SET_VALUE, nullptr, &key,
                        nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const DWORD bytes = static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
  const LSTATUS status =
      ::RegSetValueExW(key, name.c_str(), 0, REG_SZ,
                       reinterpret_cast<const BYTE*>(value.c_str()), bytes);
  ::RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

bool DeletePreferenceValue() {
  const std::wstring name = ExecutablePath();
  if (name.empty()) return false;

  HKEY key = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, kGpuPreferencesKey, 0, KEY_SET_VALUE,
                      &key) != ERROR_SUCCESS) {
    return true;
  }
  const LSTATUS status = ::RegDeleteValueW(key, name.c_str());
  ::RegCloseKey(key);
  return status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND;
}

std::vector<std::wstring> SplitTokens(const std::wstring& value) {
  std::vector<std::wstring> tokens;
  size_t start = 0;
  while (start <= value.size()) {
    const size_t separator = value.find(L';', start);
    std::wstring token = value.substr(
        start, separator == std::wstring::npos ? std::wstring::npos
                                               : separator - start);
    const size_t first = token.find_first_not_of(L" \t\r\n");
    if (first != std::wstring::npos) {
      const size_t last = token.find_last_not_of(L" \t\r\n");
      tokens.push_back(token.substr(first, last - first + 1));
    }
    if (separator == std::wstring::npos) break;
    start = separator + 1;
  }
  return tokens;
}

bool IsGpuPreferenceKey(const std::wstring& token) {
  return token.size() > kGpuPreferencePrefixLength &&
         ::_wcsnicmp(token.c_str(), kGpuPreferenceToken,
                     kGpuPreferencePrefixLength) == 0;
}

bool IsGpuPreferenceToken(const std::wstring& token, int* level) {
  if (!IsGpuPreferenceKey(token)) return false;
  const std::wstring number = token.substr(kGpuPreferencePrefixLength);
  if (number.size() != 1 || number[0] < L'0' || number[0] > L'2') {
    return false;
  }
  *level = static_cast<int>(number[0] - L'0');
  return true;
}

std::optional<int> ReadPreferenceLevel() {
  std::wstring raw;
  if (!ReadPreferenceValue(&raw)) return std::nullopt;
  for (const auto& token : SplitTokens(raw)) {
    int level = 0;
    if (IsGpuPreferenceToken(token, &level)) return level;
  }
  return std::nullopt;
}

bool WritePreferenceLevel(int level) {
  if (level < 0 || level > 2) return false;

  std::wstring raw;
  ReadPreferenceValue(&raw);
  std::wstring updated;
  bool replaced = false;
  for (const auto& token : SplitTokens(raw)) {
    if (IsGpuPreferenceKey(token)) {
      if (!replaced) {
        updated += kGpuPreferenceToken;
        updated += std::to_wstring(level);
        updated += L';';
        replaced = true;
      }
      continue;
    }
    updated += token;
    updated += L';';
  }
  if (!replaced) {
    updated += kGpuPreferenceToken;
    updated += std::to_wstring(level);
    updated += L';';
  }
  return WritePreferenceValue(updated);
}

bool ClearPreferenceLevel() {
  std::wstring raw;
  if (!ReadPreferenceValue(&raw)) return true;

  std::wstring updated;
  for (const auto& token : SplitTokens(raw)) {
    if (IsGpuPreferenceKey(token)) continue;
    updated += token;
    updated += L';';
  }
  if (updated.empty()) return DeletePreferenceValue();
  return WritePreferenceValue(updated);
}

bool HasAttachedDisplay(IDXGIAdapter* adapter, int* output_count) {
  bool attached = false;
  int count = 0;
  for (UINT index = 0;; ++index) {
    ComPtr<IDXGIOutput> output;
    const HRESULT hr = adapter->EnumOutputs(index, output.GetAddressOf());
    if (hr == DXGI_ERROR_NOT_FOUND) break;
    if (FAILED(hr)) break;
    ++count;
    DXGI_OUTPUT_DESC desc{};
    if (SUCCEEDED(output->GetDesc(&desc)) && desc.AttachedToDesktop) {
      attached = true;
    }
  }
  *output_count = count;
  return attached;
}

EncodableValue BuildMemoryInfo(IDXGIAdapter* adapter) {
  ComPtr<IDXGIAdapter3> adapter3;
  if (FAILED(adapter->QueryInterface(IID_PPV_ARGS(adapter3.GetAddressOf())))) {
    return EncodableValue();
  }

  EncodableMap info;
  auto add_segment = [&](DXGI_MEMORY_SEGMENT_GROUP group, const char* key) {
    DXGI_QUERY_VIDEO_MEMORY_INFO segment{};
    if (FAILED(adapter3->QueryVideoMemoryInfo(0, group, &segment))) return;
    EncodableMap values;
    values[EncodableValue("usage")] =
        EncodableValue(static_cast<int64_t>(segment.CurrentUsage));
    values[EncodableValue("budget")] =
        EncodableValue(static_cast<int64_t>(segment.Budget));
    values[EncodableValue("reservation")] =
        EncodableValue(static_cast<int64_t>(segment.CurrentReservation));
    values[EncodableValue("availableForReservation")] = EncodableValue(
        static_cast<int64_t>(segment.AvailableForReservation));
    info[EncodableValue(key)] = EncodableValue(values);
  };
  add_segment(DXGI_MEMORY_SEGMENT_GROUP_LOCAL, "local");
  add_segment(DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL, "nonLocal");
  if (info.empty()) return EncodableValue();
  return EncodableValue(info);
}

EncodableValue BuildAdapterInfo(IDXGIAdapter1* adapter, bool* display_attached) {
  DXGI_ADAPTER_DESC1 desc{};
  if (FAILED(adapter->GetDesc1(&desc))) return EncodableValue();

  int output_count = 0;
  const bool attached = HasAttachedDisplay(adapter, &output_count);
  *display_attached = attached;

  const bool software =
      (desc.Flags & static_cast<UINT>(DXGI_ADAPTER_FLAG_SOFTWARE)) != 0;
  const char* kind = "discrete";
  if (software) {
    kind = "software";
  } else if (desc.DedicatedVideoMemory < kIntegratedMemoryThreshold) {
    kind = "integrated";
  }

  EncodableMap item;
  item[EncodableValue("name")] =
      EncodableValue(Utf8FromUtf16(desc.Description));
  item[EncodableValue("vendorId")] =
      EncodableValue(static_cast<int32_t>(desc.VendorId));
  item[EncodableValue("deviceId")] =
      EncodableValue(static_cast<int32_t>(desc.DeviceId));
  item[EncodableValue("luid")] =
      EncodableValue(LuidToInt64(desc.AdapterLuid));
  item[EncodableValue("dedicatedVideoMemory")] =
      EncodableValue(BytesToInt64(desc.DedicatedVideoMemory));
  item[EncodableValue("dedicatedSystemMemory")] =
      EncodableValue(BytesToInt64(desc.DedicatedSystemMemory));
  item[EncodableValue("sharedSystemMemory")] =
      EncodableValue(BytesToInt64(desc.SharedSystemMemory));
  item[EncodableValue("flags")] =
      EncodableValue(static_cast<int32_t>(desc.Flags));
  item[EncodableValue("kind")] = EncodableValue(kind);
  item[EncodableValue("displayAttached")] = EncodableValue(attached);
  item[EncodableValue("outputCount")] =
      EncodableValue(static_cast<int32_t>(output_count));
  item[EncodableValue("memory")] = BuildMemoryInfo(adapter);
  return EncodableValue(item);
}

EncodableValue BuildSnapshot() {
  EncodableMap root;
  EncodableList adapters;
  std::unordered_set<int64_t> seen;
  std::optional<int64_t> display_luid;

  ComPtr<IDXGIFactory1> factory;
  if (FAILED(::CreateDXGIFactory1(IID_PPV_ARGS(factory.GetAddressOf()))) ||
      !factory) {
    root[EncodableValue("adapters")] = EncodableValue(adapters);
    return EncodableValue(root);
  }

  auto add_adapter = [&](IDXGIAdapter1* adapter) {
    DXGI_ADAPTER_DESC1 desc{};
    if (FAILED(adapter->GetDesc1(&desc))) return;
    const int64_t luid = LuidToInt64(desc.AdapterLuid);
    if (!seen.insert(luid).second) return;

    bool attached = false;
    const EncodableValue info = BuildAdapterInfo(adapter, &attached);
    if (info.IsNull()) return;
    if (attached && !display_luid.has_value()) display_luid = luid;
    adapters.push_back(info);
  };

  ComPtr<IDXGIFactory6> factory6;
  if (SUCCEEDED(factory.As(&factory6)) && factory6) {
    const DXGI_GPU_PREFERENCE preferences[] = {
        DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
        DXGI_GPU_PREFERENCE_MINIMUM_POWER,
    };
    for (const auto preference : preferences) {
      for (UINT index = 0;; ++index) {
        ComPtr<IDXGIAdapter1> adapter;
        const HRESULT hr = factory6->EnumAdapterByGpuPreference(
            index, preference, IID_PPV_ARGS(adapter.GetAddressOf()));
        if (hr == DXGI_ERROR_NOT_FOUND) break;
        if (FAILED(hr)) break;
        add_adapter(adapter.Get());
      }
    }
  }

  for (UINT index = 0;; ++index) {
    ComPtr<IDXGIAdapter1> adapter;
    const HRESULT hr = factory->EnumAdapters1(index, adapter.GetAddressOf());
    if (hr == DXGI_ERROR_NOT_FOUND) break;
    if (FAILED(hr)) break;
    add_adapter(adapter.Get());
  }

  root[EncodableValue("adapters")] = EncodableValue(adapters);
  if (display_luid.has_value()) {
    root[EncodableValue("displayAdapterLuid")] = EncodableValue(*display_luid);
  }
  const auto preference = ReadPreferenceLevel();
  if (preference.has_value()) {
    root[EncodableValue("preference")] = EncodableValue(*preference);
  }
  MEMORYSTATUSEX mem_status = {};
  mem_status.dwLength = sizeof(mem_status);
  if (::GlobalMemoryStatusEx(&mem_status)) {
    root[EncodableValue("totalPhysicalMemory")] = EncodableValue(
        static_cast<int64_t>(mem_status.ullTotalPhys));
  }
  return EncodableValue(root);
}

EncodableValue ResolveDefaultAdapter() {
  const D3D_FEATURE_LEVEL levels[] = {
      D3D_FEATURE_LEVEL_11_0,
      D3D_FEATURE_LEVEL_10_1,
      D3D_FEATURE_LEVEL_10_0,
      D3D_FEATURE_LEVEL_9_3,
  };

  ComPtr<ID3D11Device> device;
  HRESULT hr = ::D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, levels,
      static_cast<UINT>(sizeof(levels) / sizeof(levels[0])),
      D3D11_SDK_VERSION, device.GetAddressOf(), nullptr, nullptr);
  if (FAILED(hr) || !device) return EncodableValue();

  ComPtr<IDXGIDevice> dxgi_device;
  hr = device.As(&dxgi_device);
  if (FAILED(hr) || !dxgi_device) return EncodableValue();

  ComPtr<IDXGIAdapter> adapter;
  hr = dxgi_device->GetAdapter(adapter.GetAddressOf());
  if (FAILED(hr) || !adapter) return EncodableValue();

  ComPtr<IDXGIAdapter1> adapter1;
  hr = adapter.As(&adapter1);
  if (FAILED(hr) || !adapter1) return EncodableValue();

  DXGI_ADAPTER_DESC1 desc{};
  if (FAILED(adapter1->GetDesc1(&desc))) return EncodableValue();

  EncodableMap result;
  result[EncodableValue("luid")] =
      EncodableValue(LuidToInt64(desc.AdapterLuid));
  result[EncodableValue("name")] =
      EncodableValue(Utf8FromUtf16(desc.Description));
  result[EncodableValue("vendorId")] =
      EncodableValue(static_cast<int32_t>(desc.VendorId));
  result[EncodableValue("deviceId")] =
      EncodableValue(static_cast<int32_t>(desc.DeviceId));
  return EncodableValue(result);
}

}  // namespace

GpuInfo::~GpuInfo() {
  CleanUp();
}

void GpuInfo::Initialize(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "mpvson/gpu", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    OnMethodCall(call, std::move(result));
  });
}

void GpuInfo::CleanUp() {
  channel_ = nullptr;
}

void GpuInfo::OnMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

  if (method == "snapshot") {
    result->Success(BuildSnapshot());
  } else if (method == "resolveDefault") {
    result->Success(ResolveDefaultAdapter());
  } else if (method == "readPreference") {
    const auto level = ReadPreferenceLevel();
    result->Success(level.has_value() ? EncodableValue(*level)
                                      : EncodableValue());
  } else if (method == "setPreference") {
    int level = -1;
    const auto* arguments = call.arguments();
    if (arguments != nullptr) {
      if (const auto* value = std::get_if<int32_t>(arguments)) {
        level = *value;
      } else if (const auto* value64 = std::get_if<int64_t>(arguments)) {
        level = static_cast<int>(*value64);
      }
    }
    if (level < 0 || level > 2) {
      result->Error("invalid_preference",
                    "GPU preference must be 0, 1, or 2.");
      return;
    }
    result->Success(EncodableValue(WritePreferenceLevel(level)));
  } else if (method == "clearPreference") {
    result->Success(EncodableValue(ClearPreferenceLevel()));
  } else {
    result->NotImplemented();
  }
}
