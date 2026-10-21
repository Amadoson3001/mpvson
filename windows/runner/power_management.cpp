#include "power_management.h"

#include <flutter/standard_method_codec.h>

PowerManagement::PowerManagement() {
  REASON_CONTEXT context = {};
  context.Version = POWER_REQUEST_CONTEXT_VERSION;
  context.Flags = POWER_REQUEST_CONTEXT_SIMPLE_STRING;
  context.Reason.SimpleReasonString = const_cast<wchar_t*>(L"Mpvson Media Playback");
  request_handle_ = ::PowerCreateRequest(&context);
}

PowerManagement::~PowerManagement() {
  CleanUp();
}

void PowerManagement::Initialize(flutter::BinaryMessenger* messenger) {
  power_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "mpvson/power",
      &flutter::StandardMethodCodec::GetInstance());
  power_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    OnMethodCall(call, std::move(result));
  });

  management_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "mpvson/power_management",
      &flutter::StandardMethodCodec::GetInstance());
  management_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    OnMethodCall(call, std::move(result));
  });
}

void PowerManagement::CleanUp() {
  Reset();
  if (request_handle_ != INVALID_HANDLE_VALUE && request_handle_ != nullptr) {
    ::CloseHandle(request_handle_);
    request_handle_ = INVALID_HANDLE_VALUE;
  }
  power_channel_ = nullptr;
  management_channel_ = nullptr;
}

void PowerManagement::SetSystemKeepAwake(bool enable) {
  if (request_handle_ == INVALID_HANDLE_VALUE || request_handle_ == nullptr) {
    return;
  }

  if (enable && !system_awake_) {
    if (::PowerSetRequest(request_handle_, PowerRequestSystemRequired)) {
      system_awake_ = true;
    }
  } else if (!enable && system_awake_) {
    if (::PowerClearRequest(request_handle_, PowerRequestSystemRequired)) {
      system_awake_ = false;
    }
  }
}

void PowerManagement::SetDisplayKeepAwake(bool enable) {
  if (request_handle_ == INVALID_HANDLE_VALUE || request_handle_ == nullptr) {
    return;
  }

  if (enable && !display_awake_) {
    if (::PowerSetRequest(request_handle_, PowerRequestDisplayRequired)) {
      display_awake_ = true;
    }
  } else if (!enable && display_awake_) {
    if (::PowerClearRequest(request_handle_, PowerRequestDisplayRequired)) {
      display_awake_ = false;
    }
  }
}

void PowerManagement::Reset() {
  SetSystemKeepAwake(false);
  SetDisplayKeepAwake(false);
}

void PowerManagement::OnMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* arguments = call.arguments();

  if (method == "setSystemKeepAwake" || method == "setAudioKeepAwake") {
    if (arguments != nullptr) {
      if (const auto* b = std::get_if<bool>(arguments)) {
        SetSystemKeepAwake(*b);
      }
    }
    result->Success();
  } else if (method == "setDisplayKeepAwake" || method == "setVideoKeepAwake") {
    if (arguments != nullptr) {
      if (const auto* b = std::get_if<bool>(arguments)) {
        SetDisplayKeepAwake(*b);
      }
    }
    result->Success();
  } else if (method == "setKeepAwake") {
    if (arguments != nullptr) {
      if (const auto* b = std::get_if<bool>(arguments)) {
        if (*b) {
          SetDisplayKeepAwake(true);
        } else {
          Reset();
        }
      } else if (const auto* map = std::get_if<flutter::EncodableMap>(arguments)) {
        bool enable = true;
        auto it_enable = map->find(flutter::EncodableValue("enable"));
        if (it_enable != map->end()) {
          if (const auto* val = std::get_if<bool>(&it_enable->second)) {
            enable = *val;
          }
        }

        if (!enable) {
          Reset();
        } else {
          bool is_video = true;
          auto it_video = map->find(flutter::EncodableValue("isVideoPlaying"));
          if (it_video != map->end()) {
            if (const auto* val = std::get_if<bool>(&it_video->second)) {
              is_video = *val;
            }
          }

          std::string assertion_type;
          auto it_type = map->find(flutter::EncodableValue("assertionType"));
          if (it_type != map->end()) {
            if (const auto* val = std::get_if<std::string>(&it_type->second)) {
              assertion_type = *val;
            }
          }

          if (assertion_type == "display" || (assertion_type.empty() && is_video)) {
            SetDisplayKeepAwake(true);
            SetSystemKeepAwake(false);
          } else if (assertion_type == "system" || (assertion_type.empty() && !is_video)) {
            SetSystemKeepAwake(true);
            SetDisplayKeepAwake(false);
          } else if (assertion_type == "none") {
            Reset();
          } else {
            SetDisplayKeepAwake(true);
          }
        }
      }
    }
    result->Success();
  } else if (method == "reset") {
    Reset();
    result->Success();
  } else {
    result->NotImplemented();
  }
}
