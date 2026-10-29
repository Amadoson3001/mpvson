#include "system_media_transport.h"

#include <flutter/standard_method_codec.h>

#include <chrono>

namespace {

// Reads |key| from |map| as a string. Returns true when the key was present and
// held a string, in which case |out| is assigned.
bool ReadString(const flutter::EncodableMap& map, const char* key,
                std::string& out) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return false;
  }
  const auto* value = std::get_if<std::string>(&it->second);
  if (value == nullptr) {
    return false;
  }
  out = *value;
  return true;
}

// Reads |key| from |map| as a boolean, falling back to |default_value| when the
// key is missing or holds another type.
bool ReadBool(const flutter::EncodableMap& map, const char* key,
              bool default_value) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return default_value;
  }
  const auto* value = std::get_if<bool>(&it->second);
  return value == nullptr ? default_value : *value;
}

// Reads |key| from |map| as a millisecond count, falling back to
// |default_value| when the key is missing or holds another type. The 32-bit and
// the floating point representations are accepted as well, because the standard
// method codec narrows integers on 32-bit hosts and Dart may send either.
int64_t ReadMilliseconds(const flutter::EncodableMap& map, const char* key,
                         int64_t default_value) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return default_value;
  }
  if (const auto* value = std::get_if<int32_t>(&it->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<double>(&it->second)) {
    return static_cast<int64_t>(*value);
  }
  return default_value;
}

}  // namespace

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
    // The updater is kept as a member so that an artwork thumbnail which is
    // resolved asynchronously can still be applied to the same updater, and
    // therefore keeps the metadata written below.
    updater_ = smtc_.DisplayUpdater();
    updater_.Type(winrt::Windows::Media::MediaPlaybackType::Music);
    auto music = updater_.MusicProperties();
    music.Title(winrt::to_hstring(title));
    music.Artist(winrt::to_hstring(artist));
    music.AlbumTitle(winrt::to_hstring(album));
    music.AlbumArtist(winrt::to_hstring(album_artist));

    // Any thumbnail still in flight belongs to an older set of metadata.
    const uint64_t sequence = ++metadata_sequence_;

    if (artwork.empty()) {
      updater_.Thumbnail(nullptr);
      updater_.Update();
      return;
    }

    if (artwork.rfind("http://", 0) == 0 ||
        artwork.rfind("https://", 0) == 0 ||
        artwork.rfind("ms-appx://", 0) == 0) {
      // Remote (or packaged) artwork is referenced by URI, which does not
      // require waiting on an asynchronous operation.
      winrt::Windows::Foundation::Uri uri(winrt::to_hstring(artwork));
      updater_.Thumbnail(
          winrt::Windows::Storage::Streams::RandomAccessStreamReference::CreateFromUri(uri));
      updater_.Update();
      return;
    }

    std::string path = artwork;
    if (path.rfind("file:///", 0) == 0) {
      path = path.substr(8);
    } else if (path.rfind("file://", 0) == 0) {
      path = path.substr(7);
    }

    // Publish the metadata right away; the thumbnail follows once the file has
    // been resolved.
    updater_.Update();

    // Resolving the artwork file is asynchronous. This runs on the UI thread,
    // which is initialized as a single-threaded apartment (see the
    // CoInitializeEx call in main.cpp). Waiting for the operation to complete
    // from there trips cppwinrt's check_sta_blocking_wait() assertion in
    // Windows.Foundation.h, and can deadlock for real, because the completion
    // itself has to be marshalled back to the very thread that is blocked. So
    // the completion handler is used instead, and the resulting reference is
    // handed over to the UI thread through WM_SMTC_THUMBNAIL.
    auto operation = winrt::Windows::Storage::StorageFile::GetFileFromPathAsync(
        winrt::to_hstring(path));
    operation.Completed(
        [sequence, window_handle = window_handle_](
            winrt::Windows::Foundation::IAsyncOperation<
                winrt::Windows::Storage::StorageFile> const& operation,
            winrt::Windows::Foundation::AsyncStatus status) {
          winrt::Windows::Storage::Streams::RandomAccessStreamReference thumbnail{nullptr};
          if (status == winrt::Windows::Foundation::AsyncStatus::Completed) {
            try {
              thumbnail = winrt::Windows::Storage::Streams::RandomAccessStreamReference::
                  CreateFromFile(operation.GetResults());
            } catch (...) {
              thumbnail = nullptr;
            }
          }
          if (window_handle == nullptr) {
            return;
          }
          void* abi = winrt::detach_abi(thumbnail);
          if (::PostMessageW(window_handle, WM_SMTC_THUMBNAIL,
                             static_cast<WPARAM>(sequence),
                             reinterpret_cast<LPARAM>(abi)) == 0) {
            // The message was not queued, so nobody will take ownership of the
            // reference.
            ReleaseThumbnail(abi);
          }
        });
  } catch (...) {
    try {
      if (updater_) {
        updater_.Thumbnail(nullptr);
        updater_.Update();
      }
    } catch (...) {
    }
  }
}

void SystemMediaTransport::ApplyThumbnail(uint64_t sequence,
                                          void* thumbnail_abi) {
  if (sequence != metadata_sequence_) {
    // A newer setMetadata, clearMetadata or CleanUp call superseded this
    // artwork.
    ReleaseThumbnail(thumbnail_abi);
    return;
  }
  if (!smtc_ || !updater_) {
    ReleaseThumbnail(thumbnail_abi);
    return;
  }
  try {
    winrt::Windows::Storage::Streams::RandomAccessStreamReference thumbnail{nullptr};
    if (thumbnail_abi != nullptr) {
      // Takes ownership of the reference transferred through the message.
      thumbnail = winrt::Windows::Storage::Streams::RandomAccessStreamReference{
          thumbnail_abi, winrt::take_ownership_from_abi};
    }
    updater_.Thumbnail(thumbnail);
    updater_.Update();
  } catch (...) {
  }
}

void SystemMediaTransport::ReleaseThumbnail(void* thumbnail_abi) {
  if (thumbnail_abi == nullptr) {
    return;
  }
  // Takes ownership of the reference and releases it at the end of the
  // full-expression.
  winrt::Windows::Storage::Streams::RandomAccessStreamReference{
      thumbnail_abi, winrt::take_ownership_from_abi};
}

void SystemMediaTransport::ClearMetadata() {
  if (!smtc_) return;
  // Discard any thumbnail that is still being resolved.
  ++metadata_sequence_;
  updater_ = nullptr;
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
  // Discard any thumbnail that is still being resolved.
  ++metadata_sequence_;
  updater_ = nullptr;
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
      if (const auto* status_string = std::get_if<std::string>(arguments)) {
        SetPlaybackStatus(*status_string);
      } else if (const auto* map = std::get_if<flutter::EncodableMap>(arguments)) {
        std::string status;
        if (ReadString(*map, "status", status)) {
          SetPlaybackStatus(status);
        }
        int64_t position_ms = ReadMilliseconds(*map, "position", 0);
        position_ms = ReadMilliseconds(*map, "positionMs", position_ms);
        int64_t duration_ms = ReadMilliseconds(*map, "duration", 0);
        duration_ms = ReadMilliseconds(*map, "durationMs", duration_ms);
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

        ReadString(*map, "title", title);
        ReadString(*map, "artist", artist);
        ReadString(*map, "album", album);
        ReadString(*map, "albumArtist", album_artist);
        ReadString(*map, "album_artist", album_artist);
        // The artwork aliases are tried in order, so the last one that is
        // present wins.
        ReadString(*map, "artwork", artwork);
        ReadString(*map, "thumbnail", artwork);
        ReadString(*map, "artworkUri", artwork);
        ReadString(*map, "artworkPath", artwork);

        SetMetadata(title, artist, album, album_artist, artwork);
      }
    }
    result->Success();
  } else if (method == "updateCapabilities") {
    if (arguments != nullptr) {
      if (const auto* map = std::get_if<flutter::EncodableMap>(arguments)) {
        if (smtc_) {
          try {
            smtc_.IsPlayEnabled(ReadBool(*map, "canPlay", true));
            smtc_.IsPauseEnabled(ReadBool(*map, "canPause", true));
            smtc_.IsNextEnabled(ReadBool(*map, "canGoNext", true));
            smtc_.IsPreviousEnabled(ReadBool(*map, "canGoPrevious", true));
          } catch (...) {
          }
        }
      }
    }
    result->Success();
  } else if (method == "setTimeline" || method == "updateTimeline") {
    if (arguments != nullptr) {
      if (const auto* map = std::get_if<flutter::EncodableMap>(arguments)) {
        int64_t position_ms = ReadMilliseconds(*map, "position", 0);
        position_ms = ReadMilliseconds(*map, "positionMs", position_ms);
        int64_t duration_ms = ReadMilliseconds(*map, "duration", 0);
        duration_ms = ReadMilliseconds(*map, "durationMs", duration_ms);
        int64_t start_ms = ReadMilliseconds(*map, "start", 0);
        start_ms = ReadMilliseconds(*map, "startMs", start_ms);

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
