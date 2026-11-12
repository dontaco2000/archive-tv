import 'dart:convert';
import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:archive_tv_player/parental/parental.dart';
import 'package:archive_tv_player/parental/parental_flow.dart';
import 'package:archive_tv_player/settings/settings_file.dart';
import 'package:archive_tv_player/settings/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Parental', () {
    test('PIN is stored salted and hashed, never in plain text', () {
      final a = Parental()..setPin('1234');
      final b = Parental()..setPin('1234');
      expect(a.pinHash, isNot(contains('1234')));
      expect(jsonEncode(a.toJson()), isNot(contains('1234')));
      expect(a.pinSalt, isNot(b.pinSalt));
      expect(a.pinHash, isNot(b.pinHash)); // same PIN, different salt
      expect(a.check('1234', DateTime(2026)), PinCheck.ok);
      expect(a.check('4321', DateTime(2026)), PinCheck.wrong);
      expect(() => a.setPin('12a4'), throwsArgumentError);
    });

    test('3 wrong tries = 30 s lockout, even for the right PIN', () {
      final p = Parental()..setPin('0000');
      final t = DateTime(2026, 1, 1, 12);
      expect(p.check('1111', t), PinCheck.wrong);
      expect(p.check('1111', t), PinCheck.wrong);
      expect(p.check('1111', t), PinCheck.lockedOut);
      expect(p.check('0000', t.add(const Duration(seconds: 29))), PinCheck.lockedOut);
      expect(p.lockoutLeft(t.add(const Duration(seconds: 20))), const Duration(seconds: 10));
      expect(p.check('0000', t.add(const Duration(seconds: 30))), PinCheck.ok);
      expect(p.wrongTries, 0);
    });

    test('a right PIN resets the wrong-try count', () {
      final p = Parental()..setPin('0000');
      final t = DateTime(2026);
      p.check('1', t);
      p.check('1', t);
      expect(p.check('0000', t), PinCheck.ok);
      expect(p.check('1', t), PinCheck.wrong); // count starts again
    });

    test('isLocked needs a PIN, the master lock ON and the channel on the list', () {
      final p = Parental()..locked = {25};
      p.lockOn = true;
      expect(p.isLocked(25), false); // no PIN
      p.setPin('1234');
      expect(p.isLocked(25), true);
      expect(p.isLocked(2), false);
      p.lockOn = false;
      expect(p.isLocked(25), false);
    });

    test('Lock mature channels adds only flagged ones', () {
      final p = Parental();
      final chans = [const Channel(number: 2, name: 'Funnies'), const Channel(number: 25, name: 'Headliner', mature: true), const Channel(number: 11, name: 'Haunt', mature: true)];
      expect(p.lockMature(chans), 2);
      expect(p.locked, {25, 11});
      expect(p.lockMature(chans), 0);
      expect(p.toggle(11), false);
      expect(p.toggle(2), true);
      expect(p.locked, {25, 2});
    });

    test('lock state, list, PIN and lockout persist through settings.json', () {
      final dir = Directory.systemTemp.createTempSync('atv_par');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = SettingsStore(File('${dir.path}/settings.json'));
      final s = Settings();
      s.parental
        ..setPin('2468')
        ..lockOn = true
        ..locked = {10, 11};
      s.parental.check('0', DateTime(2026));
      store.save(s);
      final r = store.load().parental;
      expect(r.lockOn, true);
      expect(r.locked, {10, 11});
      expect(r.wrongTries, 1);
      expect(r.isLocked(10), true);
      expect(r.check('2468', DateTime(2026)), PinCheck.ok);
    });
  });

  group('ParentalFlow', () {
    late Parental p;
    late ParentalFlow flow;
    PinRequest? shown;
    late List<String> flashes;
    var saves = 0;
    var now = DateTime(2026, 1, 1);

    setUp(() {
      p = Parental();
      shown = null;
      flashes = [];
      saves = 0;
      now = DateTime(2026, 1, 1);
      flow = ParentalFlow(p, save: () => saves++, flash: flashes.add, ask: (r) => shown = r, now: () => now);
    });

    test('set PIN asks twice; a mismatch changes nothing', () {
      flow.setPin();
      shown!.onPin('1234');
      shown!.onPin('9999');
      expect(p.hasPin, false);
      expect(flashes.last, contains('did not match'));
      flow.setPin();
      shown!.onPin('1234');
      shown!.onPin('1234');
      expect(shown, isNull);
      expect(p.check('1234', now), PinCheck.ok);
    });

    test('unlocking a channel turns the master lock OFF persistently, then tunes', () {
      p
        ..setPin('1234')
        ..lockOn = true
        ..locked = {25};
      var tuned = false;
      flow.unlockFor('25 HEADLINER', () => tuned = true);
      expect(shown!.title, contains('locked'));
      shown!.onPin('0000');
      expect(tuned, false);
      expect(shown!.hint, contains('2 left'));
      shown!.onPin('1234');
      expect(tuned, true);
      expect(p.lockOn, false);
      expect(saves, greaterThan(0));
      flow.activate(); // no PIN needed to re-lock
      expect(p.lockOn, true);
    });

    test('3 wrong PINs close the prompt and lock out for 30 s', () {
      p.setPin('1234');
      flow.deactivate();
      shown!.onPin('1');
      shown!.onPin('2');
      shown!.onPin('3');
      expect(shown, isNull);
      expect(flashes.last, contains('wait 30 s'));
      flow.deactivate();
      expect(shown, isNull); // still locked out: no prompt at all
      now = now.add(const Duration(seconds: 31));
      flow.deactivate();
      expect(shown, isNotNull);
    });

    test('change and remove PIN need the current PIN', () {
      p
        ..setPin('1234')
        ..locked = {10};
      flow.changePin();
      shown!.onPin('1234');
      shown!.onPin('5555');
      shown!.onPin('5555');
      expect(p.check('5555', now), PinCheck.ok);
      flow.removePin();
      shown!.onPin('1234'); // old PIN: wrong
      expect(p.hasPin, true);
      shown!.onPin('5555');
      expect(p.hasPin, false);
      expect(p.locked, isEmpty);
    });
  });

  group('archive_tv_settings.txt', () {
    late Directory dir;
    late File txt;
    late SettingsStore store;
    final logs = <String>[];

    setUp(() {
      dir = Directory.systemTemp.createTempSync('atv_txt');
      txt = File('${dir.path}/$settingsFileName');
      store = SettingsStore(File('${dir.path}/settings.json'))..textFile = txt;
      logs.clear();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('first save creates it with defaults and comments', () {
      store.save(Settings());
      final t = txt.readAsStringSync();
      expect(t, contains('reset_parental_controls=false'));
      expect(t, contains('picture=auto'));
      expect(t, contains('# '));
      // Its own defaults read back without complaints.
      expect(applySettingsText(t, Settings(), logs.add), false);
      expect(logs, isEmpty);
    });

    test('reset flow: PIN set -> flag true -> start -> everything cleared, flag false', () {
      final s = Settings();
      s.parental
        ..setPin('1234')
        ..lockOn = true
        ..locked = {10, 25};
      s.parental.check('0', DateTime(2026));
      store.save(s);
      txt.writeAsStringSync(txt.readAsStringSync().replaceFirst('reset_parental_controls=false', 'reset_parental_controls=true'));

      // App start (as main.dart does it).
      final loaded = store.load();
      expect(applySettingsFile(txt, loaded, logs.add), true);
      store.save(loaded);

      final after = store.load().parental;
      expect(after.hasPin, false);
      expect(after.lockOn, false);
      expect(after.locked, isEmpty);
      expect(after.wrongTries, 0);
      expect(txt.readAsStringSync(), contains('reset_parental_controls=false'));
      expect(logs.single, contains('parental controls were reset'));
      // One-shot: the next start resets nothing.
      expect(applySettingsFile(txt, store.load(), logs.add), false);
    });

    test('keys override settings.json', () {
      final s = Settings();
      applySettingsText('start_fullscreen=true\nweather_mode=native\nvolume_leveling=strong\npicture=fill\nremote_on_wifi=yes # phones\n', s, logs.add);
      expect([s.startFullscreen, s.weatherMode, s.volumeLeveling, s.picture, s.remoteLan], [true, 'native', 'strong', 'fill', true]);
      expect(logs, isEmpty);
    });

    test('invalid contents are ignored and logged, never thrown', () {
      final s = Settings()..parental.setPin('1234');
      final before = jsonEncode(s.toJson());
      final reset = applySettingsText('garbage line\n=x\npicture=sideways\nreset_parental_controls=maybe\nstart_fullscreen=2\nfoo=bar\n\u0000ÿ', s, logs.add);
      expect(reset, false);
      expect(jsonEncode(s.toJson()), before);
      expect(logs.length, 7);
      txt.writeAsBytesSync([0xff, 0xfe, 0x00, 0xd8]); // not UTF-8
      expect(applySettingsFile(txt, s, logs.add), false);
    });

    test('a menu change is written back, so the file does not undo it next start', () {
      final s = Settings();
      store.save(s);
      s.picture = 'off';
      store.save(s);
      final again = Settings();
      applySettingsFile(txt, again, logs.add);
      expect(again.picture, 'off');
    });
  });
}
