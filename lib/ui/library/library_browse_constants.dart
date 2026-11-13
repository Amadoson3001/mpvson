/// Default page size for library song/video browse lists.
///
/// Kept small enough that isolate round-trips stay off the interaction path
/// while still filling several screens before the next prefetch.
const int kLibraryBrowsePageSize = 80;

/// How far from the scroll end (in pixels) before the next page loads.
const double kLibraryBrowseScrollPrefetch = 320;

/// Typing delay before library search queries the database.
const Duration kLibrarySearchDebounce = Duration(milliseconds: 180);

/// How often browse views refresh while a folder scan is still running.
const Duration kLibraryScanReloadThrottle = Duration(seconds: 2);
