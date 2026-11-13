import 'dart:io';

/// Hardware constraint detection for native desktop/mobile platforms.
bool detectConstrainedHardware() {
  try {
    return Platform.numberOfProcessors <= 4;
  } on Object {
    return false;
  }
}

/// Returns the logical processor count on native platforms.
int detectProcessorCount() {
  try {
    return Platform.numberOfProcessors;
  } on Object {
    return 4;
  }
}
