import '../media/media_library.dart';

typedef LibraryServerGroups = ({List<String> serverOrder, Map<String, List<MediaLibrary>> byServer});

/// Groups libraries by the server name they display under, falling back to the
/// server id when no name is set. First appearance wins, so the order of
/// [libraries] still decides header order.
///
/// Keying on the *displayed* name rather than the raw connection id is what
/// stops one connection's addon catalogs from swallowing a second surface that
/// rides on the same connection. The Stremio account pseudo-libraries (Library,
/// Continue Watching) carry `serverName: 'Stremio'` while the addon's own
/// catalogs carry the addon's manifest name ("Formulio"), yet both are served
/// by the single debrid connection. Grouping by id put them in one bucket whose
/// header came from whichever happened to sort first, so Continue Watching read
/// as part of Formulio even though it never comes from Formulio. Libraries with
/// no name keep id keying, so unrelated unnamed servers still never merge.
LibraryServerGroups groupLibrariesByFirstAppearance(List<MediaLibrary> libraries) {
  final order = <String>[];
  final byServer = <String, List<MediaLibrary>>{};
  for (final lib in libraries) {
    final key = lib.serverName ?? lib.serverId ?? '';
    if (!byServer.containsKey(key)) {
      order.add(key);
      byServer[key] = [];
    }
    byServer[key]!.add(lib);
  }
  return (serverOrder: order, byServer: byServer);
}
