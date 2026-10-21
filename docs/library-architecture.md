# Local Media Library Architecture

Mpvson includes an integrated local media library designed for fast indexing, rich music browsing, unified search, favorites curation, and custom playlists. The library subsystem operates independently of the active playback engine, maintaining responsiveness even during 4K video playback or large directory indexing operations.

---

## Architecture Overview

The library architecture follows a strict decoupled design pattern:

```
┌─────────────────────────────────────────────────────────────┐
│                       UI Presentation Layer                  │
│   (Player Screen, Library Views, Music Browser, Playlists)  │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│                    Open Request Coordinator                 │
│         (Opening preferences, conflict resolution, IPC)      │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│                  Media Library Repository                    │
│   (lib/data/repositories/media_library_repository.dart)     │
└───────────────┬─────────────────────────────┬───────────────┘
                │                             │
┌───────────────▼───────────────┐ ┌───────────▼───────────────┐
│     Media Probe Service       │ │     SQLite Storage Engine  │
│(Header & tag extraction, art) │ │ (media_library.db indexed)│
└───────────────────────────────┘ └───────────────────────────┘
```

### Key Principles

1. **Non-Destructive Storage**: Source files on disk are never altered, moved, or deleted by library operations.
2. **Offline-First & Detachable Drive Resilience**: When a tracked drive or folder is disconnected, tracks are marked unavailable (`isAvailable = false`) rather than pruned from the database. User favorites, playlists, and play counts remain intact.
3. **Two-Stage Scanning**: Discovery is separated into a fast filesystem scan followed by asynchronous, throttled metadata enrichment.
4. **Isolated Application State**: The database and cached artwork are stored inside the platform application-support directory (`%APPDATA%\dev.mpvson.mpvson` on Windows, `~/.local/share/mpvson` on Linux), completely isolated from system mpv profiles.

---

## Domain Models

Domain entities reside in [`lib/domain/models/`](file:///E:/mpvson/lib/domain/models/):

### Media Catalog (`lib/domain/models/media_catalog.dart`)

[`MediaCatalog`](file:///E:/mpvson/lib/domain/models/media_catalog.dart) serves as the single source of truth for format support and MIME classification across the player:

- **Audio Extensions**: `mp3`, `flac`, `wav`, `m4a`, `aac`, `ogg`, `oga`, `opus`, `wma`, `aiff`, `aif`, `ape`.
- **Video Extensions**: `mp4`, `mkv`, `avi`, `webm`, `mov`, `flv`, `wmv`, `m4v`, `ts`, `m2ts`, `vob`, `ogv`, `3gp`.
- **Fast Lookups**: `isSupportedFile(path)` provides $O(1)$ extension validation; `kindFromExtension(path)` provides initial [`MediaKind`](file:///E:/mpvson/lib/domain/models/media_kind.dart) hints (`audio`, `video`, `unknown`).
- **File Dialog Filters**: `filePickerExtensions` exposes an alphabetically sorted list for native open dialogs.

### Metadata & Technical Properties (`lib/domain/models/media_metadata.dart`)

- **`MediaMetadata`**: Represents immutable metadata tags extracted from media containers:
  - Identification: `title`, `artist`, `albumArtist`, `album`, `genre`, `year`.
  - Numbering: `trackNumber`, `discNumber`.
  - Playback: `duration`, `artworkUri`.
  - Normalization getters: `effectiveArtist` and `effectiveAlbumArtist` gracefully fallback to `Unknown Artist` or album artist equivalents for consistent grouping.
- **`AudioTechnicalInfo`**: Contains stream-level technical properties:
  - Codec name (`codec`), sample rate in Hz (`sampleRate`), channel count (`channels`), bitrate in bits/sec (`bitrate`), and bit depth (`bitsPerSample`).

### Library Entities (`lib/domain/models/library_models.dart`)

- **`LibraryFolderRecord`**: Represents an indexed root directory with properties:
  - `path`: Normalized absolute folder path.
  - `addedAt` / `lastScannedAt`: Timestamps tracking scan recency.
  - `isAvailable`: Availability flag (false if unmounted or missing).
  - `fileCount`: Discovered file count.
- **`MediaItemRecord`**: The central record representing an indexed file:
  - `id`: Unique identifier (UUID).
  - `canonicalSource`: Normalized URI/path key used for deduplication across the player.
  - `path`: Absolute filesystem path.
  - `kind`: Classified [`MediaKind`](file:///E:/mpvson/lib/domain/models/media_kind.dart).
  - `metadata`: Embedded [`MediaMetadata`](file:///E:/mpvson/lib/domain/models/media_metadata.dart).
  - `fileSize` and `modifiedAt`: Filesystem attributes for change detection.
  - `isFavorite`: User favorite toggle.
  - `playCount` and `lastPlayedAt`: Usage analytics updated on playback.
- **`PlaylistRecord` & `PlaylistEntryRecord`**:
  - `PlaylistRecord`: Manages playlist metadata (`id`, `title`, `createdAt`, `updatedAt`, `entryCount`).
  - `PlaylistEntryRecord`: Represents an item within a playlist with a 0-based `position` integer, facilitating ordered playback and drag-and-drop reordering.
- **`LibraryScanStatus` & `ScanPhase`**:
  - `ScanPhase`: Enum tracking scan lifecycle: `idle`, `discovering`, `enriching`, `reconciling`, `error`.
  - Reports `discoveredCount`, `enrichedCount`, and `totalToEnrich` to display progress indicators in the UI.

---

## Data Layer & Persistence

### SQLite Database (`media_library.db`)

The library uses SQLite (via the `sqlite3` package) with write-ahead logging (WAL) enabled for concurrent read performance during background indexing:

```sql
-- Tracked Library Folders
CREATE TABLE library_folders (
    path TEXT PRIMARY KEY NOT NULL,
    added_at INTEGER NOT NULL,
    last_scanned_at INTEGER,
    is_available INTEGER NOT NULL DEFAULT 1,
    file_count INTEGER NOT NULL DEFAULT 0
);

-- Indexed Media Items
CREATE TABLE media_items (
    id TEXT PRIMARY KEY NOT NULL,
    canonical_source TEXT UNIQUE NOT NULL,
    path TEXT NOT NULL,
    kind TEXT NOT NULL,
    title TEXT,
    artist TEXT,
    album_artist TEXT,
    album TEXT,
    genre TEXT,
    year INTEGER,
    track_number INTEGER,
    disc_number INTEGER,
    duration_ms INTEGER NOT NULL DEFAULT 0,
    artwork_uri TEXT,
    codec TEXT,
    sample_rate INTEGER,
    channels INTEGER,
    bitrate INTEGER,
    bits_per_sample INTEGER,
    file_size INTEGER NOT NULL DEFAULT 0,
    modified_at INTEGER,
    is_available INTEGER NOT NULL DEFAULT 1,
    is_favorite INTEGER NOT NULL DEFAULT 0,
    added_at INTEGER NOT NULL,
    last_played_at INTEGER,
    play_count INTEGER NOT NULL DEFAULT 0
);

-- Performance Indexes
CREATE INDEX idx_media_kind ON media_items(kind);
CREATE INDEX idx_media_artist ON media_items(artist);
CREATE INDEX idx_media_album ON media_items(album);
CREATE INDEX idx_media_favorite ON media_items(is_favorite);
CREATE INDEX idx_media_available ON media_items(is_available);
CREATE INDEX idx_media_last_played ON media_items(last_played_at);

-- Playlists
CREATE TABLE playlists (
    id TEXT PRIMARY KEY NOT NULL,
    title TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

-- Playlist Entries with Explicit Positioning
CREATE TABLE playlist_entries (
    id TEXT PRIMARY KEY NOT NULL,
    playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    media_id TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    added_at INTEGER NOT NULL
);

CREATE INDEX idx_playlist_position ON playlist_entries(playlist_id, position);
```

---

## Scanning Pipeline

The library uses a staged pipeline to ensure the UI remains interactive:

```
[User Adds Folder]
       │
       ▼
┌─────────────────────────────┐
│   Phase 1: Discovering      │ ── Fast filesystem walk matching MediaCatalog.isSupportedFile()
│                             │ ── Emits discovered file count; creates placeholder records
└──────────────┬──────────────┘
               │
               ▼
┌─────────────────────────────┐
│    Phase 2: Enriching       │ ── Batched worker extracts ID3, Vorbis, MP4 tags & artwork
│                             │ ── Updates media_items with metadata, duration, technical info
└──────────────┬──────────────┘
               │
               ▼
┌─────────────────────────────┐
│   Phase 3: Reconciling      │ ── Compares filesystem snapshot with database
│                             │ ── Flags missing files as isAvailable=0 without deleting records
└──────────────┬──────────────┘
               │
               ▼
      [Phase: Idle]
```

### Metadata Probing & Artwork Extraction

The [`MediaProbeService`](file:///E:/mpvson/lib/data/services/media_probe_service.dart) performs tag extraction:
1. **Container Headers**: Parses tag containers (ID3v1, ID3v2.3/v2.4, Vorbis comments, MP4 atoms) for title, artist, album, track number, and year.
2. **Audio Stream Attributes**: Reads stream headers to extract codec, sample rate, bit depth, and bitrate.
3. **Artwork Hierarchy**:
   - Priority 1: Sidecar image in the same directory matching standard names (`cover.jpg`, `cover.png`, `folder.jpg`, `albumart.jpg`).
   - Priority 2: Embedded picture frame (ID3 `APIC`, Vorbis `METADATA_BLOCK_PICTURE`, MP4 `covr`). Extracted images are written to the application thumbnail cache.
   - Priority 3: Fallback generic artwork based on media kind.

---

## Music Browsing and Querying

[`MediaLibraryRepository`](file:///E:/mpvson/lib/data/repositories/media_library_repository.dart) exposes clean asynchronous query methods:

### Hierarchical Music Navigation

- **Artists**: `getDistinctArtists({MediaKind? kind})` retrieves all unique artists sorted alphabetically, ignoring leading articles ("The").
- **Albums**: `getDistinctAlbums({String? artist})` retrieves albums filtered by artist, ordered chronologically by release year or alphabetically.
- **Tracks**: `queryMedia(artist: ..., album: ...)` retrieves tracks ordered by `discNumber ASC, trackNumber ASC`.

### Search

The `queryMedia(searchQuery: ...)` method performs case-insensitive substring matching against:
- Track title (`title LIKE %query%`)
- Artist name (`artist LIKE %query%`)
- Album title (`album LIKE %query%`)
- File path (`path LIKE %query%`)

Results support offset/limit pagination and sorting across multiple columns (`title`, `addedAt`, `artist`, `album`, `lastPlayed`, `playCount`, `duration`).

### Favorites

- `toggleFavorite(mediaId, isFavorite)` toggles the favorite state.
- `queryMedia(onlyFavorites: true)` filters the entire library or specific subsets (e.g. favorite songs by an artist).

### Playlists

- **Creation & Management**: `createPlaylist(title)`, `renamePlaylist(id, title)`, `deletePlaylist(id)`.
- **Entries**: `addToPlaylist(playlistId, mediaIds)` appends items with automatically assigned incrementing positions.
- **Reordering**: `reorderPlaylist(playlistId, oldIndex, newIndex)` shifts entry positions in an atomic SQLite transaction.

---

## Playback Integration

When opening items from the library:
1. Selected `MediaItemRecord` entries are converted into [`MediaEntry`](file:///E:/mpvson/lib/domain/models/media_entry.dart) instances containing pre-populated metadata, duration, and artwork URIs.
2. The opening request is processed through [`OpenRequestCoordinator`](file:///E:/mpvson/lib/data/services/open_request_coordinator.dart) respecting the user's opening behavior preference.
3. Upon playback completion or after playing past the threshold, [`recordPlayback(canonicalSource)`](file:///E:/mpvson/lib/data/repositories/media_library_repository.dart) increments `play_count` and updates `last_played_at`.
