import 'dart:io';

/// Append-only log file capped at [maxBytes]: when full it becomes `<name>.1`
/// (older ones shift up to `<name>.<keep>`, the oldest is dropped).
class RotatingLog {
  final File file;
  final int maxBytes;
  final int keep;
  int _size;

  RotatingLog(this.file, {this.maxBytes = 2 * 1024 * 1024, this.keep = 2}) : _size = file.existsSync() ? file.lengthSync() : 0;

  void write(String line) {
    final bytes = line.length + 1; // close enough for the cap (mostly ASCII)
    if (_size + bytes > maxBytes && _size > 0) _roll();
    file.writeAsStringSync('$line\n', mode: FileMode.append);
    _size += bytes;
  }

  void _roll() {
    try {
      for (var i = keep; i >= 1; i--) {
        final from = i == 1 ? file : File('${file.path}.${i - 1}');
        if (from.existsSync()) from.renameSync('${file.path}.$i'); // renaming onto .keep replaces the oldest
      }
    } on FileSystemException {
      // A locked old file must not stop logging; worst case the log grows a little.
    }
    _size = file.existsSync() ? file.lengthSync() : 0;
  }
}
