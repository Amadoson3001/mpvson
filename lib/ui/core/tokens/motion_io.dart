import 'dart:io';

/// Hardware constraint detection for native desktop/mobile platforms.
bool detectConstrainedHardware() {
  try {
    return Platform.numberOfProcessors <= 4;
  } on Object {
    return false;
  }
}
