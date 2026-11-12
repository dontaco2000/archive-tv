import 'dart:convert';
import 'dart:math';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:crypto/crypto.dart';

/// Parental controls state, saved in settings.json under "parental".
///
/// A FAMILY CONVENIENCE LOCK, not a security product: anyone who can edit the data folder can reset it
/// (archive_tv_settings.txt, reset_parental_controls=true). The PIN is stored only as a salted hash and never logged.
///
/// Model (user decision 2026-11-12): one persistent master lock. While [lockOn] (and a PIN exists) the
/// channels in [locked] need the PIN; entering it turns the master lock OFF for good (all channels open,
/// survives restarts) until someone picks "Turn lock ON" again (no PIN needed to re-lock).
class Parental {
  static const maxTries = 3;
  static const lockout = Duration(seconds: 30);
  static const _rounds = 10000;

  String? pinHash, pinSalt;
  bool lockOn = false;
  Set<int> locked = {};

  /// Wrong PINs in a row, and the end of the 30 s lockout after [maxTries] of them (saved, so a restart can't skip it).
  int wrongTries = 0;
  DateTime? lockoutUntil;

  Parental();

  bool get hasPin => pinHash != null && pinSalt != null;

  /// Channel [number] needs the PIN right now.
  bool isLocked(int number) => hasPin && lockOn && locked.contains(number);

  /// [channels] without the locked ones: Channel Up/Down and On Demand only see these.
  List<Channel> openChannels(Iterable<Channel> channels) => [for (final c in channels) if (!isLocked(c.number)) c];

  static bool validPin(String pin) => RegExp(r'^\d{4}$').hasMatch(pin);

  static String hashPin(String pin, String salt) {
    List<int> d = utf8.encode('$salt:$pin');
    for (var i = 0; i < _rounds; i++) {
      d = sha256.convert(d).bytes;
    }
    return base64Url.encode(d);
  }

  /// Sets a new PIN (fresh salt). The lock list and lock state stay as they are.
  void setPin(String pin, {Random? random}) {
    if (!validPin(pin)) throw ArgumentError('PIN must be 4 digits');
    final r = random ?? Random.secure();
    pinSalt = base64Url.encode([for (var i = 0; i < 16; i++) r.nextInt(256)]);
    pinHash = hashPin(pin, pinSalt!);
    wrongTries = 0;
    lockoutUntil = null;
  }

  Duration lockoutLeft(DateTime now) {
    final u = lockoutUntil;
    return u == null || !now.isBefore(u) ? Duration.zero : u.difference(now);
  }

  /// Checks [pin]; [maxTries] wrong ones in a row lock PIN entry for [lockout]. The caller saves afterwards.
  PinCheck check(String pin, DateTime now) {
    if (lockoutLeft(now) > Duration.zero) return PinCheck.lockedOut;
    if (hasPin && hashPin(pin, pinSalt!) == pinHash) {
      wrongTries = 0;
      lockoutUntil = null;
      return PinCheck.ok;
    }
    if (++wrongTries >= maxTries) {
      wrongTries = 0;
      lockoutUntil = now.add(lockout);
      return PinCheck.lockedOut;
    }
    return PinCheck.wrong;
  }

  /// "Lock mature channels": adds every channel flagged "mature" in channels.json; returns how many were new.
  int lockMature(Iterable<Channel> channels) {
    var added = 0;
    for (final c in channels) {
      if (c.mature && locked.add(c.number)) added++;
    }
    return added;
  }

  /// Returns true if [number] is now on the lock list.
  bool toggle(int number) => locked.remove(number) ? false : locked.add(number);

  /// Wipes everything (the reset file and "Remove PIN").
  void clear() {
    pinHash = pinSalt = lockoutUntil = null;
    lockOn = false;
    locked = {};
    wrongTries = 0;
  }

  Map<String, dynamic> toJson() => {
        'pinHash': pinHash,
        'pinSalt': pinSalt,
        'lockOn': lockOn,
        'locked': locked.toList()..sort(),
        'wrongTries': wrongTries,
        'lockoutUntil': lockoutUntil?.toIso8601String(),
      };

  factory Parental.fromJson(Map<String, dynamic> j) {
    final p = Parental();
    if (j['pinHash'] is String && j['pinSalt'] is String) {
      p.pinHash = j['pinHash'] as String;
      p.pinSalt = j['pinSalt'] as String;
    }
    p.lockOn = j['lockOn'] == true;
    if (j['locked'] is List) p.locked = (j['locked'] as List).whereType<int>().toSet();
    if (j['wrongTries'] is int) p.wrongTries = (j['wrongTries'] as int).clamp(0, maxTries - 1);
    if (j['lockoutUntil'] is String) p.lockoutUntil = DateTime.tryParse(j['lockoutUntil'] as String);
    return p;
  }
}

enum PinCheck { ok, wrong, lockedOut }
