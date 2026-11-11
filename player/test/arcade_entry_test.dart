import 'package:archive_tv_player/ui/arcade_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('up and down cycle the letter under the cursor, wrapping through blank', () {
    final a = ArcadeEntry(3);
    expect(a.text, '');
    a.up();
    expect(a.text, 'A');
    a.down();
    a.down();
    expect(a.text, '9');
    a.up();
    a.up();
    a.up();
    expect(a.text, 'B');
  });

  test('right moves on to the next slot, left goes back; trailing blanks are dropped', () {
    final a = ArcadeEntry(3)..up(); // A
    a.right();
    a.up();
    a.up(); // B
    expect(a.text, 'AB');
    expect(a.cursor, 1);
    a.right();
    a.right(); // stays on the last slot
    expect(a.cursor, 2);
    a.left();
    a.left();
    a.left();
    expect(a.cursor, 0);
  });

  test('typing sets the slot and advances; backspace clears the previous slot', () {
    final a = ArcadeEntry(5);
    for (final c in '3940'.split('')) {
      a.type(c);
    }
    expect(a.text, '3940');
    a.backspace();
    expect(a.text, '394');
    expect(a.cursor, 3);
    a.type('q'); // lower case is taken as upper
    expect(a.text, '394Q');
    a.type('!'); // not in the alphabet: ignored
    expect(a.text, '394Q');
  });
}
