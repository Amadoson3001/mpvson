#include "system_media_transport.h"

#include <flutter/standard_method_codec.h>

#include <chrono>

SystemMediaTransport::SystemMediaTransport() = default;

SystemMediaTransport::~SystemMediaTransport() {
  CleanUp();
}

void SystemMediaTransport::Initialize(HWND window_handle,
                                      flutter::BinaryMessenger* messenger) {
  window_handle_ = window_handle;

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "mpvson/media_controls",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    OnMethodCall(call, std::move(result));
  });

  try {
    auto interop = winrt::get_activation_factory<
        winrt::Windows::Media::SystemMediaTransportControls,
        ISystemMediaTransportControlsInterop>();
    winrt::check_hresult(interop->GetForWindow(
        window_handle_,
        winrt::guid_of<winrt::Windows::Media::ISystemMediaTransportControls>(),
        winrt::put_abi(smtc_)));

    if (smtc_) {
      smtc_.IsEnabled(true);
      smtc_.IsPlayEnabled(true);
      smtc_.IsPauseEnabled(true);
      smtc_.IsNextEnabled(true);
      smtc_.IsPreviousEnabled(true);
      smtc_.IsStopEnabled(true);
      smtc_.PlaybackStatus(winrt::Windows::Media::MediaPlaybackStatus::Closed);

      button_token_ = smtc_.ButtonPressed(
          [this](const winrt::Windows::Media::SystemMediaTransportControls&,
                 const winrt::Windows::Media::SystemMediaTransportControlsButtonPressedEventArgs& args) {
            int button_id = static_cast<int>(args.Button());
            if (window_handle_ != nullptr) {
              ::PostMessageW(window_handle_, WM_SMTC_BUTTON_PRESS,
                             static_cast<WPARAM>(button_id), 0);
            }
          });
    }
  } catch (...) {
    smtc_ = nullptr;
  }
}

void SystemMediaTransport::HandleButtonPress(int button_id) {
  std::string button_name;
  switch (static_cast<winrt::Windows::Media::SystemMediaTransportControlsButton>(button_id)) {
    case winrt::Windows::Media::SystemMediaTransportControlsButton::Play:
      button_name = "play";
      break;
    case winrt::Windows::Media::SystemMediaTransportControlsButton::Pause:
      button_name = "pause";
      break;
    case winrt::Windows::Media::SystemMediaTransportControlsButton::Next:
      button_name = "next";
      break;
    case winrt::Windows::Media::SystemMediaTransportControlsButton::Previous:
      button_name = "previous";
      break;
    case winrt::Windows::Media::SystemMediaTransportControlsButton::Stop:
      button_name = "stop";
      break;
    default:
      return;
  }

  if (channel_ != nullptr) {
    channel_->InvokeMethod(
        button_name, std::make_unique<flutter::EncodableValue>(button_name));

    flutter::EncodableMap args;
    args[flutter::EncodableValue("button")] = flutter::EncodableValue(button_name);
    channel_->InvokeMethod("onButtonPressed",
                           std::make_unique<flutter::EncodableValue>(args));
  }
}

void SystemMediaTransport::SetPlaybackStatus(const std::string& status) {
  if (!smtc_) return;
  try {
    if (status == "playing" || status == "Playing") {
      smtc_.PlaybackStatus(winrt::Windows::Media::MediaPlaybackStatus::Playing);
    } else if (status == "paused" || status == "Paused") {
      smtc_.PlaybackStatus(winrt::Windows::Media::MediaPlaybackStatus::Paused);
    } else if (status == "stopped" || status == "Stopped") {
      smtc_.PlaybackStatus(winrt::Windows::Media::MediaPlaybackStatus::Stopped);
    } else if (status == "closed" || status == "Closed") {
      smtc_.PlaybackStatus(winrt::Windows::Media::MediaPlaybackStatus::Closed);
    } else if (status == "changing" || status == "Changing") {
      smtc_.PlaybackStatus(winrt::Windows::Media::MediaPlaybackStatus::Changing);
    }
  } catch (...) {
  }
}

void SystemMediaTransport::SetTimeline(int64_t position_ms,
                                       int64_t duration_ms,
                                       int64_t start_ms) {
  if (!smtc_) return;
  try {
    winrt::Windows::Media::SystemMediaTransportControlsTimelineProperties props;
    props.StartTime(std::chrono::milliseconds(start_ms));
    props.Position(std::chrono::milliseconds(position_ms));
    props.EndTime(std::chrono::milliseconds(duration_ms > 0 ? duration_ms : position_ms));
    props.MinSeekTime(std::chrono::milliseconds(start_ms));
    props.MaxSeekTime(std::chrono::milliseconds(duration_ms > 0 ? duration_ms : position_ms));
    smtc_.UpdateTimelineProperties(props);
  } catch (...) {
  }
}

void SystemMediaTransport::SetMetadata(const std::string& title,
                                       const std::string& artist,
                                       const std::string& album,
                                       const std::string& album_artist,
                                       const std::string& artwork) {
  if (!smtc_) return;
  try {
    auto updater = smtc_.DisplayUpdater();
    updater.Type(winrt::Windows::Media::MediaPlaybackType::Music);
    auto music = updater.MusicProperties();
    music.Title(winrt::to_hstring(title));
    music.Artist(winrt::to_hstring(artist));
    music.AlbumTitle(winrt::to_hstring(album));
    music.AlbumArtist(winrt::to_hstring(album_artist));

    if (!artwork.empty()) {
      try {
        if (artwork.rfind("http://", 0) == 0 ||
            artwork.rfind("https://", 0) == 0 ||
            artwork.rfind("ms-appx://", 0) == 0) {
          winrt::Windows::Foundation::Uri uri(winrt::to_hstring(artwork));
          updater.Thumbnail(
              winrt::Windows::Storage::Streams::RandomAccessStreamReference::CreateFromUri(uri));
        } else {
          std::string path = artwork;
          if (path.rfind("file:///", 0) == 0) {
            path = path.substr(8);
          } else if (path.rfind("file://", 0) == 0) {
            path = path.substr(7);
          }
          auto file = winrt::Windows::Storage::StorageFile::GetFileFromPathAsync(
              winrt::to_hstring(path)).get();
          updater.Thumbnail(
              winrt::Windows::Storage::Streams::RandomAccessStreamReference::CreateFromFile(file));
        }
      } catch (...) {
        updater.Thumbnail(nullptr);
      }
    } else {
      updater.Thumbnail(nullptr);
    }

    updater.Update();
  } catch (...) {
  }
}

void SystemMediaTransport::ClearMetadata() {
  if (!smtc_) return;
  try {
    auto updater = smtc_.DisplayUpdater();
    updater.ClearAll();
    updater.Update();
  } catch (...) {
  }
}

void SystemMediaTransport::SetEnabled(bool enabled) {
  if (!smtc_) return;
  try {
    smtc_.IsEnabled(enabled);
  } catch (...) {
  }
}

void SystemMediaTransport::CleanUp() {
  if (smtc_ != nullptr) {
    try {
      if (button_token_.value != 0) {
        smtc_.ButtonPressed(button_token_);
        button_token_.value = 0;
      }
      auto updater = smtc_.DisplayUpdater();
      updater.ClearAll();
      updater.Update();
      smtc_.PlaybackStatus(winrt::Windows::Media::MediaPlaybackStatus::Closed);
      smtc_.IsEnabled(false);
    } catch (...) {
    }
    smtc_ = nullptr;
  }
  channel_ = nullptr;
  window_handle_ = nullptr;
}

void SystemMediaTransport::OnMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* arguments = call.arguments();

  if (method == "setPlaybackStatus" || method == "updatePlaybackStatus" ||
      method == "updatePlaybackState") {
    if (arguments != nullptr) {
      if (const auto* str = std::get_if<std::string>(arguments)) {
        SetPlaybackStatus(*str);
      } else if (const auto* map = std::get_if<flutter::EncodableMap>(arguments)) {
        auto it = map->find(flutter::EncodableValue("status"));
        if (it != map->end()) {
          if (const auto* s = std::get_if<std::string>(&it->second)) {
            SetPlaybackStatus(*s);
          }
        }
        int64_t position_ms = 0;
        int64_t duration_ms = 0;
        auto it_pos = map->find(flutter::EncodableValue("positionMs"));
        if (it_pos == map->end()) it_pos = map->find(flutter::EncodableValue("position"));
        if (it_pos != map->end()) {
          if (const auto* val_i32 = std::get_if<int32_t>(&it_pos->second)) position_ms = *val_i32;
          else if (const auto* val_i64 = std::get_if<int64_t>(&it_pos->second)) position_ms = *val_i64;
          else if (const auto* val_dbl = std::get_if<double>(&it_pos->second)) position_ms = static_cast<int64_t>(*val_dbl);
        }
        auto it_dur = map->find(flutter::EncodableValue("durationMs"));
        if (it_dur == map->end()) it_dur = map->find(flutter::EncodableValue("duration"));
        if (it_dur != map->end()) {
          if (const auto* val_i32 = std::get_if<int32_t>(&it_dur->second)) duration_ms = *val_i32;
          else if (const auto* val_i64 = std::get_if<int64_t>(&it_dur->second)) duration_ms = *val_i64;
          else if (const auto* val_dbl = std::get_if<double>(&it_dur->second)) duration_ms = static_cast<int64_t>(*val_dbl);
        }
        if (duration_ms > 0 || position_ms > 0) {
          SetTimeline(position_ms, duration_ms);
        }
      }
    }
    result->Success();
  } else if (method == "setMetadata" || method == "updateMetadata") {
    if (arguments != nullptr) {
      if (const auto* map = std::get_if<flutter::EncodableMap>(arguments)) {
        std::string title;
        std::string artist;
        std::string album;
        std::string album_artist;
        std::string artwork;

        auto get_str = [&](const char* key, std::string& target) {
          auto it = map->find(flutter::EncodableValue(key));
          if (it != map->end()) {
            if (const auto* val = std::get_if<std::string>(&it->second)) {
              target = *val;
            }
          }
        };

        get_str("title", title);
        get_str("artist", artist);
        get_str("album", album);
        get_str("albumArtist", album_artist);
        get_str("album_artist", album_artist);
        get_str("artwork", artwork);
        get_str("thumbnail", artwork);
        get_str("artworkUri", artwork);
        get_str("artworkPath", artwork);

        SetMetadata(title, artist, album, album_artist, artwork);
      }
    }
    result->Success();
  } else if (method == "updateCapabilities") {
    if (arguments != nullptr) {
      if (const auto* map = std::get_if<flutter::EncodableMap>(arguments)) {
        if (smtc_) {
          auto check_bool = [&](const char* key, bool default_val) -> bool {
            auto it = map->find(flutter::EncodableValue(key));
            if (it != map->end()) {
              if (const auto* val = std::get_if<bool>(&it->second)) {
                return *val;
              }
            }
            return default_val;
          };
          try {
            smtc_.IsPlayEnabled(check_bool("canPlay", true));
            smtc_.IsPauseEnabled(check_bool("canPause", true));
            smtc_.IsNextEnabled(check_bool("canGoNext", true));
            smtc_.IsPreviousEnabled(check_bool("canGoPrevious", true));
          } catch (...) {
          }
        }
      }
    }
    result->Success();
  } else if (method == "setTimeline" || method == "updateTimeline") {
    if (arguments != nullptr) {
      if (const auto* map = std::get_if<flutter::EncodableMap>(arguments)) {
        int64_t position_ms = 0;
        int64_t duration_ms = 0;
        int64_t start_ms = 0;

        auto get_int64 = [&](const char* key, int64_t& target) {
          auto it = map->find(flutter::EncodableValue(key));
          if (it != map->end()) {
            if (const auto* val_int = std::get_if<int32_t>(&it->second)) {
              target = *val_int;
            } else if (const auto* val_int64 = std::get_if<int64_t>(&it->second)) {
              target = *val_int64;
            } else if (const auto* val_double = std::get_if<double>(&it->second)) {
              target = static_cast<int64_t>(*val_double);
            }
          }
        };

        get_int64("position", position_ms);
        get_int64("positionMs", position_ms);
        get_int64("duration", duration_ms);
        get_int64("durationMs", duration_ms);
        get_int64("start", start_ms);
        get_int64("startMs", start_ms);

        SetTimeline(position_ms, duration_ms, start_ms);
      }
    }
    result->Success();
  } else if (method == "clearMetadata" || method == "clear") {
    ClearMetadata();
    result->Success();
  } else if (method == "setEnabled") {
    if (arguments != nullptr) {
      if (const auto* b = std::get_if<bool>(arguments)) {
        SetEnabled(*b);
      }
    }
    result->Success();
  } else {
    result->NotImplemented();
  }
}
