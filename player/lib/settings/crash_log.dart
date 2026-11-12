import 'dart:io';

import 'package:path/path.dart' as p;

/// Crash bookkeeping next to archive_tv.log: an "app is running" marker (a run that ends without removing
/// it ended unexpectedly) and the last uncaught error (shown and copied from the menu).
///
/// ponytail: Dart errors only. A native crash (libmpv, the engine) just leaves the marker behind; a Windows
/// minidump (WER LocalDumps or a native handler) is the upgrade if that ever needs debugging.
class CrashLog {
  final Directory dir;
  final void Function(String) log;
  CrashLog(this.dir, this.log);

  File get _marker => File(p.join(dir.path, 'running.marker'));
  File get _lastError => File(p.join(dir.path, 'last_error.txt'));

  /// The previous run's last log lines, kept when it ended unexpectedly.
  File get tailFile => File(p.join(dir.path, 'previous_run_tail.log'));

  /// Call once at start, before this run writes to [logFile]. If the previous run left its marker, logs
  /// that it ended unexpectedly and keeps the last [tailBytes] of the log; then sets the marker again.
  /// Returns whether the previous run ended unexpectedly.
  bool start(File logFile, {int tailBytes = 64 * 1024}) {
    final crashed = _marker.existsSync();
    if (crashed) {
      try {
        final bytes = logFile.readAsBytesSync();
        tailFile.writeAsBytesSync(bytes.length > tailBytes ? bytes.sublist(bytes.length - tailBytes) : bytes);
      } on FileSystemException {
        // no log yet, or locked: nothing to keep
      }
      log('previous run ended unexpectedly (no clean shutdown); its last log lines: ${tailFile.path}');
    }
    running(true);
    return crashed;
  }

  /// Sets ([on]) or clears the marker: cleared on a clean exit (window closed, app sent to the background).
  void running(bool on) {
    try {
      if (on) {
        _marker.writeAsStringSync('${DateTime.now().toIso8601String()} pid $pid');
      } else if (_marker.existsSync()) {
        _marker.deleteSync();
      }
    } on FileSystemException {
      // bookkeeping must never take the app down
    }
  }

  /// Logs an uncaught error with its stack trace and keeps it as the last error.
  void error(String where, Object e, StackTrace? st) {
    final text = 'uncaught ($where): $e\n${st ?? ''}'.trimRight();
    log(text);
    try {
      _lastError.writeAsStringSync('${DateTime.now().toIso8601String()} $text');
    } on FileSystemException {
      // already in the log
    }
  }

  /// The last uncaught error (this run or an earlier one), or null.
  String? get lastError {
    try {
      return _lastError.existsSync() ? _lastError.readAsStringSync() : null;
    } on FileSystemException {
      return null;
    }
  }
}
