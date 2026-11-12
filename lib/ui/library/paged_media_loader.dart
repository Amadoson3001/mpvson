import '../../data/repositories/media_library_repository.dart';
import '../../domain/models/library_models.dart';
import 'library_browse_constants.dart';

/// Result of one paged [MediaLibraryRepository.queryMedia] call.
final class PagedMediaBatch {
  const PagedMediaBatch({required this.items, required this.hasMore});

  final List<MediaItemRecord> items;
  final bool hasMore;
}

Future<PagedMediaBatch> fetchMediaPage(
  MediaLibraryRepository repository, {
  required int offset,
  int pageSize = kLibraryBrowsePageSize,
  MediaKind? kind,
  String? searchQuery,
  String? artist,
  String? album,
  bool? onlyFavorites,
  String? sortBy,
  bool ascending = true,
}) async {
  final raw = await repository.queryMedia(
    kind: kind,
    searchQuery: searchQuery,
    artist: artist,
    album: album,
    onlyFavorites: onlyFavorites,
    sortBy: sortBy,
    ascending: ascending,
    limit: pageSize + 1,
    offset: offset,
  );
  final hasMore = raw.length > pageSize;
  return PagedMediaBatch(
    items: hasMore ? raw.sublist(0, pageSize) : raw,
    hasMore: hasMore,
  );
}
