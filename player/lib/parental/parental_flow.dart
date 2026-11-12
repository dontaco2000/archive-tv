import 'parental.dart';

/// One on-screen PIN question. The TV's [PinPrompt] and the remote page's PIN dialog both answer it.
class PinRequest {
  static int _ids = 0;
  final int id = ++_ids;
  final String title;
  final String? hint;
  final void Function(String pin) onPin;
  PinRequest(this.title, this.onPin, {this.hint});
}

/// The parental PIN dialogs, as plain logic (no widgets): the TV screen shows whatever [ask] gets
/// (null = close the prompt), saves on [save] and shows [flash] messages.
class ParentalFlow {
  final Parental p;
  final void Function() save;
  final void Function(String) flash;
  final void Function(PinRequest?) ask;
  final void Function(String) log;
  final DateTime Function() now;

  /// Runs after the lock is turned ON (the TV leaves a channel that just became locked).
  void Function() afterLockOn = () {};

  /// Runs after "Late night adult mode" changed (the engine follows it).
  void Function() afterAdultMode = () {};

  ParentalFlow(this.p, {required this.save, required this.flash, required this.ask, void Function(String)? log, DateTime Function()? now})
      : log = log ?? ((_) {}),
        now = now ?? DateTime.now;

  String _wait() => 'Too many wrong PINs: wait ${(p.lockoutLeft(now()).inMilliseconds / 1000).ceil()} s';

  /// Asks for the current PIN, then runs [then]. Wrong: asks again (tries left shown); 3 wrong: 30 s lockout.
  void verify(String title, void Function() then) {
    if (p.lockoutLeft(now()) > Duration.zero) {
      ask(null);
      return flash(_wait());
    }
    void again(String? hint) => ask(PinRequest(title, (pin) {
          final r = p.check(pin, now());
          save(); // wrong-try counter and lockout survive a restart
          switch (r) {
            case PinCheck.ok:
              ask(null);
              then();
            case PinCheck.wrong:
              log('parental: wrong PIN');
              again('Wrong PIN (${Parental.maxTries - p.wrongTries} left)');
            case PinCheck.lockedOut:
              log('parental: PIN entry locked for ${Parental.lockout.inSeconds} s');
              ask(null);
              flash(_wait());
          }
        }, hint: hint));
    again(null);
  }

  /// Tuning a locked channel: the PIN turns the master lock OFF (persistently), then [tune] runs.
  void unlockFor(String channelLabel, void Function() tune) => verify('$channelLabel is locked', () {
        _setLock(false);
        tune();
      });

  /// "Turn lock OFF" needs the PIN; "Turn lock ON" doesn't.
  void deactivate() => verify('Turn lock OFF', () => _setLock(false));

  void activate() {
    if (!p.hasPin) return flash('Set a PIN first');
    _setLock(true);
  }

  void _setLock(bool on) {
    p.lockOn = on;
    save();
    log('parental: lock ${on ? 'ON' : 'OFF'}');
    flash(on ? 'Parental lock ON' : 'Parental lock OFF');
    if (on) afterLockOn();
  }

  /// "Late night adult mode" ON/OFF: always needs the PIN (also with the lock OFF).
  void toggleAdultMode() {
    if (!p.hasPin) return flash('Set a PIN first');
    final on = !p.adultMode;
    verify('PIN: late night adult mode ${on ? 'ON' : 'OFF'}', () {
      p.adultMode = on;
      save();
      log('parental: late night adult mode ${on ? 'ON' : 'OFF'}');
      flash('Late night adult mode ${on ? 'ON' : 'OFF'}');
      afterAdultMode();
    });
  }

  /// New PIN twice. [title] says why (set or change).
  void _newPin(String title) => ask(PinRequest(title, (first) {
        ask(PinRequest('Enter the new PIN again', (second) {
          ask(null);
          if (first != second) return flash('PINs did not match: nothing changed');
          p.setPin(first);
          save();
          log('parental: PIN set');
          flash('PIN saved');
        }));
      }, hint: '4 digits'));

  void setPin() => p.hasPin ? changePin() : _newPin('Choose a 4-digit PIN');

  void changePin() => verify('Current PIN', () => _newPin('New PIN'));

  /// Removing the PIN turns parental controls off entirely (lock list cleared too).
  void removePin() => verify('PIN to remove parental controls', () {
        p.clear();
        save();
        afterAdultMode(); // back to ON
        log('parental: PIN removed, parental controls off');
        flash('Parental controls removed');
      });
}
