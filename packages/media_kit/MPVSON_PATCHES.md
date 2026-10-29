# Mpvson media_kit changes

This repository owns its `media_kit` copy alongside `media_kit_video`.

- **Hot restart callback teardown (`real.dart`)**:
  When hot restart occurs in Flutter, the Dart isolate is destroyed and its `NativeCallable` trampolines are deleted by the Dart VM.
  On the new isolate startup, `NativeReferenceHolder` discovers references from the previous isolate and sends `quit`.
  Before issuing any command, `mpv.mpv_set_wakeup_callback(reference.cast(), nullptr, nullptr)` is called to clear the wakeup callback.
  This prevents libmpv from invoking the deleted callback pointer on worker threads during shutdown, avoiding the fatal Dart VM crash:
  `Callback invoked after it has been deleted`.

- **Corrupted reference holder recovery (`native_reference_holder.dart`)**:
  If the temporary file contains invalid or unparseable contents from an abrupt termination, allocation of a fresh buffer is safely performed instead of throwing an unhandled exception.
