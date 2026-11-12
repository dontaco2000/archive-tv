import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// One search hit.
class ItemSummary {
  final String identifier;
  final String? title;
  final String? date;
  final int downloads;

  const ItemSummary(this.identifier, {this.title, this.date, this.downloads = 0});
}

/// One file inside an item, from the metadata API.
class ArchiveFile {
  final String name;
  final String? format;
  final int? size;
  final double? length;
  final String? title;

  /// Archive marks files of access-restricted items (e.g. TV News) private: downloads get 401/403.
  final bool private;

  const ArchiveFile(this.name, {this.format, this.size, this.length, this.title, this.private = false});
}

/// An item's metadata: its title, media type and files.
class ItemMeta {
  final String identifier;
  final String? title;
  final String mediatype;
  final List<ArchiveFile> files;

  /// The `language` metadata (several values joined with "; "), null if untagged.
  final String? language;

  /// `sound` metadata says silent.
  final bool silent;

  const ItemMeta(this.identifier,
      {this.title, this.mediatype = 'movies', this.files = const [], this.language, this.silent = false});
}

/// What the pool builder needs from Archive. Tests use a fake.
abstract interface class ArchiveApi {
  /// Items matching [query], most downloaded first.
  Future<List<ItemSummary>> search(String query, {int rows = 100, int page = 1});

  /// The item's metadata, or null if the item doesn't exist.
  Future<ItemMeta?> metadata(String identifier);
}

class ArchiveException implements Exception {
  final String message;
  ArchiveException(this.message);

  @override
  String toString() => 'ArchiveException: $message';
}

/// Talks to archive.org over HTTP (no API key needed).
class ArchiveClient implements ArchiveApi {
  final http.Client _http;
  final String host;
  final String userAgent;
  final int maxAttempts;
  final Duration retryDelay;
  final Duration requestTimeout;

  ArchiveClient({
    http.Client? client,
    this.host = 'archive.org',
    this.userAgent = 'ArchiveTV/0.1 (personal retro TV app)',
    this.maxAttempts = 3,
    this.retryDelay = const Duration(seconds: 2),
    this.requestTimeout = const Duration(seconds: 30),
  }) : _http = client ?? http.Client();

  @override
  Future<List<ItemSummary>> search(String query, {int rows = 100, int page = 1}) async {
    final uri = Uri.https(host, '/advancedsearch.php', {
      'q': query,
      'fl[]': ['identifier', 'title', 'date', 'downloads'],
      'sort[]': 'downloads desc',
      'rows': '$rows',
      'page': '$page',
      'output': 'json',
    });
    final body = await _get(uri);
    final docs = ((jsonDecode(body) as Map)['response'] as Map)['docs'] as List;
    return [
      for (final d in docs.cast<Map<String, dynamic>>())
        ItemSummary(
          d['identifier'] as String,
          title: _firstString(d['title']),
          date: _firstString(d['date']),
          downloads: (d['downloads'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  @override
  Future<ItemMeta?> metadata(String identifier) async {
    final body = await _get(Uri.https(host, '/metadata/$identifier'));
    final json = jsonDecode(body) as Map<String, dynamic>;
    final meta = json['metadata'];
    if (meta is! Map<String, dynamic>) return null; // unknown item: Archive returns {}
    return ItemMeta(
      identifier,
      title: _firstString(meta['title']),
      mediatype: (meta['mediatype'] as String?) ?? 'movies',
      language: switch (meta['language']) {
        final String l => l,
        final List l when l.isNotEmpty => l.join('; '),
        _ => null,
      },
      silent: '${meta['sound']}'.toLowerCase().contains('silent'),
      files: [
        for (final f in (json['files'] as List? ?? const []).cast<Map<String, dynamic>>())
          ArchiveFile(
            f['name'] as String,
            format: f['format'] as String?,
            size: int.tryParse('${f['size'] ?? ''}'),
            length: parseLength(f['length']),
            title: f['title'] as String?,
            private: '${f['private']}' == 'true',
          ),
      ],
    );
  }

  /// GET with a timeout, retrying on 429, 5xx, timeouts and connection errors.
  Future<String> _get(Uri uri) async {
    for (var attempt = 1;; attempt++) {
      String? failure;
      try {
        final res = await _http
            .get(uri, headers: {'User-Agent': userAgent})
            .timeout(requestTimeout);
        if (res.statusCode == 200) return utf8.decode(res.bodyBytes);
        failure = 'HTTP ${res.statusCode}';
        if (res.statusCode != 429 && res.statusCode < 500) {
          throw ArchiveException('GET $uri failed with $failure');
        }
      } on TimeoutException {
        failure = 'a timeout';
      } on http.ClientException catch (e) {
        failure = 'a connection error (${e.message})';
      }
      if (attempt >= maxAttempts) throw ArchiveException('GET $uri failed with $failure');
      await Future<void>.delayed(retryDelay * attempt);
    }
  }

  void close() => _http.close();
}

String? _firstString(Object? v) {
  if (v is String) return v;
  if (v is List && v.isNotEmpty) return v.first.toString();
  return null;
}

/// Archive reports file length as seconds ("1763.3") or as "HH:MM:SS" / "MM:SS".
double? parseLength(Object? raw) {
  if (raw == null) return null;
  final text = raw.toString().trim();
  if (text.isEmpty) return null;
  if (!text.contains(':')) return double.tryParse(text);
  final parts = text.split(':').map(double.tryParse).toList();
  if (parts.any((p) => p == null) || parts.length > 3) return null;
  var seconds = 0.0;
  for (final p in parts) {
    seconds = seconds * 60 + p!;
  }
  return seconds;
}
