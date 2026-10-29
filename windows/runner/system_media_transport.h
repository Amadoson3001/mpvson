#ifndef RUNNER_SYSTEM_MEDIA_TRANSPORT_H_
#define RUNNER_SYSTEM_MEDIA_TRANSPORT_H_

#include <windows.h>
#include <systemmediatransportcontrolsinterop.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <cstdint>
#include <memory>
#include <string>

#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Storage.h>

constexpr UINT WM_SMTC_BUTTON_PRESS = WM_USER + 102;
constexpr UINT WM_SMTC_THUMBNAIL = WM_USER + 103;

class SystemMediaTransport {
 public:
  SystemMediaTransport();
  ~SystemMediaTransport();

  SystemMediaTransport(const SystemMediaTransport&) = delete;
  SystemMediaTransport& operator=(const SystemMediaTransport&) = delete;

  // Initializes SMTC for the top-level Flutter window and registers method channel.
  void Initialize(HWND window_handle, flutter::BinaryMessenger* messenger);

  // Handles a button press routed from the background thread via the window message loop.
  void HandleButtonPress(int button_id);

  // Applies an artwork thumbnail that was resolved off the UI thread. Ownership
  // of |thumbnail_abi| (which may be nullptr) is transferred to this call.
  void ApplyThumbnail(uint64_t sequence, void* thumbnail_abi);

  // Releases a thumbnail reference passed as a raw ABI pointer.
  static void ReleaseThumbnail(void* thumbnail_abi);

  // Playback control
  void SetPlaybackStatus(const std::string& status);
  void SetTimeline(int64_t position_ms, int64_t duration_ms, int64_t start_ms = 0);
  void SetMetadata(const std::string& title, const std::string& artist,
                   const std::string& album, const std::string& album_artist,
                   const std::string& artwork);
  void ClearMetadata();
  void SetEnabled(bool enabled);

  // Unsubscribes and cleans up SMTC.
  void CleanUp();

 private:
  void OnMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  HWND window_handle_ = nullptr;
  winrt::Windows::Media::SystemMediaTransportControls smtc_{nullptr};
  winrt::event_token button_token_{0};

  // Incremented for every setMetadata / clearMetadata / CleanUp call so that a
  // thumbnail which is still being resolved can be discarded when it is no
  // longer the artwork that should be displayed.
  uint64_t metadata_sequence_ = 0;

  // Kept alive between setMetadata and the thumbnail arriving asynchronously, so
  // that the artwork can be applied to the same updater (and therefore keep the
  // metadata that was written to it).
  winrt::Windows::Media::SystemMediaTransportControlsDisplayUpdater updater_{nullptr};

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_SYSTEM_MEDIA_TRANSPORT_H_
