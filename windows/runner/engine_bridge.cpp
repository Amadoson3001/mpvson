#include "engine_bridge.h"

#include <flutter/standard_method_codec.h>

#include <windows.h>

#include <string>

#include "utils.h"

namespace {

// The exported entry points of the engine library bridge. They live in the
// native video plugin, which is the module that resolves libmpv's render API.
constexpr wchar_t kVideoPluginModule[] = L"media_kit_video_plugin.dll";
constexpr char kConfigureEngineExport[] = "MpvsonConfigureEngine";
constexpr char kEngineLibraryPathExport[] = "MpvsonEngineLibraryPath";

using ConfigureEngine = int (*)(const wchar_t*);
using EngineLibraryPath = const wchar_t* (*)();

// Returns the video plugin module, or nullptr when it is not loaded.
HMODULE GetVideoPluginModule() {
  return ::GetModuleHandleW(kVideoPluginModule);
}

template <typename T>
T ResolveExport(HMODULE module, const char* name) {
  return reinterpret_cast<T>(::GetProcAddress(module, name));
}

}  // namespace

EngineBridge::~EngineBridge() {
  CleanUp();
}

void EngineBridge::Initialize(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "mpvson/engine", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    OnMethodCall(call, std::move(result));
  });
}

void EngineBridge::CleanUp() {
  channel_ = nullptr;
}

void EngineBridge::OnMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  HMODULE module = GetVideoPluginModule();
  if (module == nullptr) {
    result->Error("engine_bridge",
                  "The native video engine bridge is unavailable.");
    return;
  }

  if (call.method_name() == "configure") {
    const auto* path = call.arguments() == nullptr
                           ? nullptr
                           : std::get_if<std::string>(call.arguments());
    if (path == nullptr || path->empty()) {
      result->Error("engine_path",
                    "An absolute engine library path is required.");
      return;
    }
    const std::wstring wide_path = Utf16FromUtf8(path->c_str());
    if (wide_path.empty()) {
      result->Error("engine_path", "The engine library path is not valid UTF-8.");
      return;
    }
    auto configure = ResolveExport<ConfigureEngine>(module,
                                                    kConfigureEngineExport);
    if (configure == nullptr) {
      result->Error("engine_bridge",
                    "The native video engine bridge is unavailable.");
      return;
    }
    const int code = configure(wide_path.c_str());
    if (code != 0) {
      result->Error("engine_load",
                    "Could not load the selected native engine. Windows error " +
                        std::to_string(code));
      return;
    }
    result->Success();
  } else if (call.method_name() == "libraryPath") {
    auto library_path = ResolveExport<EngineLibraryPath>(module,
                                                         kEngineLibraryPathExport);
    const wchar_t* path = library_path == nullptr ? nullptr : library_path();
    result->Success(flutter::EncodableValue(Utf8FromUtf16(path)));
  } else {
    result->NotImplemented();
  }
}
