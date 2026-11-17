import 'package:faheng_api/services/json_safe.dart';
import 'package:test/test.dart';

void main() {
  group('jsonSafe', () {
    test('turns a top-level DateTime into an ISO string', () {
      final doc = {
        'createdAt': DateTime.utc(
          2026,
          11,
          17,
          5,
        ),
      };
      expect(jsonSafe(doc)['createdAt'], '2026-11-17T05:00:00.000Z');
    });

    test('turns a DateTime inside a list of maps into an ISO string', () {
      final at = DateTime.utc(2026, 11, 17, 9, 30);
      final doc = {
        'restockHistory': [
          {'stock': 250, 'at': at},
          {'stock': 2000, 'at': at},
        ],
      };
      final history = jsonSafe(doc)['restockHistory'] as List;
      expect((history.first as Map)['at'], '2026-11-17T09:30:00.000Z');
      expect((history.first as Map)['stock'], 250);
      expect(history, hasLength(2));
    });

    test('walks a map inside a map', () {
      final doc = {
        'meta': {'savedAt': DateTime.utc(2026, 1, 2)},
      };
      expect(
        (jsonSafe(doc)['meta'] as Map)['savedAt'],
        '2026-01-02T00:00:00.000Z',
      );
    });

    test('leaves numbers, strings, null and booleans alone', () {
      final doc = {'stock': 250, 'name': 'Rice', 'note': null, 'live': true};
      expect(jsonSafe(doc), doc);
    });
  });
}
