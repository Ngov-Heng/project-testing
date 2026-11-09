import 'package:faheng_api/services/admin_order_service.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/order_service.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:test/test.dart';

/// Runs [action] and returns the ApiError it throws.
ApiError _apiError(void Function() action) {
  try {
    action();
  } on ApiError catch (error) {
    return error;
  }
  fail('expected an ApiError, but nothing was thrown');
}

/// The conditions inside a selector. mongo_dart wraps them in `$query`, and
/// turns two conditions on the same field into an `$and` list, so tests read
/// them through this helper instead of guessing the shape.
List<Map<String, dynamic>> conditionsOf(SelectorBuilder selector) {
  final query = (selector.map[r'$query'] as Map?) ?? const <String, dynamic>{};
  final and = query[r'$and'];
  if (and is List) {
    return <Map<String, dynamic>>[
      for (final item in and) Map<String, dynamic>.from(item as Map),
    ];
  }
  return <Map<String, dynamic>>[Map<String, dynamic>.from(query)];
}

void main() {
  // 8 Nov 2026 is a Sunday; 9 Nov 2026 is the Monday after it.
  final sunday = DateTime.utc(2026, 11, 8);

  group('the heavy badge on screen 40', () {
    test('150 kg is heavy', () {
      expect(isHeavyOrder(150), isTrue);
    });

    test('149 kg is not', () {
      expect(isHeavyOrder(149), isFalse);
    });

    test('a 500 kg order is heavy', () {
      expect(isHeavyOrder(500), isTrue);
    });
  });

  group('the status dropdown on screen 39', () {
    test('pending may become processing or be cancelled', () {
      expect(canChangeStatus('pending', 'processing'), isTrue);
      expect(canChangeStatus('pending', 'cancelled'), isTrue);
    });

    test('pending may not jump straight to delivered', () {
      expect(canChangeStatus('pending', 'delivered'), isFalse);
    });

    test('on the way may only be delivered', () {
      expect(canChangeStatus('on_the_way', 'delivered'), isTrue);
      expect(canChangeStatus('on_the_way', 'cancelled'), isFalse);
    });

    test('a delivered order is finished', () {
      expect(orderTransitions['delivered'], isEmpty);
      expect(canChangeStatus('delivered', 'processing'), isFalse);
    });

    test('the admin and the buyer share one rulebook', () {
      // orderTransitions is the map chunk 3 wrote, not a copy.
      expect(
        orderTransitions.keys.toList(),
        containsAll(<String>['pending', 'processing', 'on_the_way']),
      );
    });
  });

  group('the date filters on screen 38', () {
    test('a plain day is read as UTC midnight', () {
      expect(cleanDay('2026-11-08', 'from'), DateTime.utc(2026, 11, 8));
    });

    test('a day that does not exist is refused', () {
      expect(
        _apiError(() => cleanDay('2026-02-30', 'from')).message,
        'from is not a real date',
      );
    });

    test('a broken format is refused with an example', () {
      expect(
        _apiError(() => cleanDay('8/11/2026', 'to')).message,
        'to must look like 2026-11-08',
      );
    });

    test('a range that runs backwards is refused', () {
      expect(
        _apiError(
          () => adminOrderFilters(<String, String>{
            'from': '2026-11-08',
            'to': '2026-11-01',
          }),
        ).message,
        'from cannot be after to',
      );
    });

    test('no dates means no range', () {
      final filters = adminOrderFilters(<String, String>{});
      expect(filters.from, isNull);
      expect(filters.to, isNull);
    });
  });

  group('reading the query string of screen 38', () {
    test('the defaults are page 1, newest first, all statuses', () {
      final filters = adminOrderFilters(<String, String>{});
      expect(filters.page, 1);
      expect(filters.limit, 20);
      expect(filters.sort, 'newest');
      expect(filters.status, isNull);
    });

    test('status all is the same as no filter', () {
      expect(
        adminOrderFilters(<String, String>{'status': 'all'}).status,
        isNull,
      );
    });

    test('a status that does not exist is refused', () {
      expect(
        _apiError(
          () => adminOrderFilters(<String, String>{'status': 'lost'}),
        ).statusCode,
        400,
      );
    });

    test('oldest reverses the sort', () {
      expect(
        adminOrderFilters(<String, String>{'sort': 'oldest'}).sort,
        'oldest',
      );
      expect(
        _apiError(
          () => adminOrderFilters(<String, String>{'sort': 'best'}),
        ).message,
        'sort must be newest or oldest',
      );
    });

    test('the date range covers the whole last day', () {
      final selector = buildOrderQuery(
        adminOrderFilters(<String, String>{
          'from': '2026-11-01',
          'to': '2026-11-07',
        }),
      );
      final conditions = conditionsOf(selector).toString();
      // From the 1st...
      expect(conditions, contains('2026-11-01'));
      // ...to midnight on the 8th, so everything on the 7th is included.
      expect(conditions, contains('2026-11-08'));
    });

    test('the search box is not part of the query builder', () {
      // It has to be resolved to ids first, so it must not sneak in as a regex
      // that Mongo would run against one field only.
      final selector = buildOrderQuery(
        adminOrderFilters(<String, String>{'q': 'FH-1042'}),
      );
      expect(selector.map.toString().contains('regex'), isFalse);
    });

    test('no filter is an empty query, not a broken one', () {
      final selector = buildOrderQuery(adminOrderFilters(<String, String>{}));
      expect(conditionsOf(selector).first, isEmpty);
    });
  });

  group('the status counts under the title', () {
    test('counts every status, including the empty ones', () {
      final counts = statusCounts(<Map<String, dynamic>>[
        {'status': 'pending'},
        {'status': 'pending'},
        {'status': 'on_the_way'},
      ]);
      expect(counts['pending'], 2);
      expect(counts['on_the_way'], 1);
      expect(counts['delivered'], 0);
      expect(counts['cancelled'], 0);
    });

    test('an unknown status is ignored, not counted', () {
      final counts = statusCounts(<Map<String, dynamic>>[
        {'status': 'refunded'},
      ]);
      expect(counts.values.every((n) => n == 0), isTrue);
    });
  });

  group('the Phnom Penh day', () {
    test('20:00 UTC is already tomorrow in Cambodia', () {
      final late = DateTime.utc(2026, 11, 8, 20);
      expect(phnomPenhDayKey(late), '2026-11-09');
    });

    test('03:00 UTC is 10:00 the same morning', () {
      final early = DateTime.utc(2026, 11, 8, 3);
      expect(phnomPenhDayKey(early), '2026-11-08');
    });

    test('the day starts at 17:00 UTC the day before', () {
      expect(
        phnomPenhDayStart(DateTime.utc(2026, 11, 8, 20)),
        DateTime.utc(2026, 11, 8, 17),
      );
    });
  });

  group('the delivery week on screen 40', () {
    test('a Sunday belongs to the week that started six days earlier', () {
      expect(weekMonday(sunday), DateTime.utc(2026, 11, 2));
    });

    test('a Monday is its own week start', () {
      expect(weekMonday(DateTime.utc(2026, 11, 9)), DateTime.utc(2026, 11, 9));
    });

    test('the week is Monday to Sunday, seven days', () {
      final days = weekDays(DateTime.utc(2026, 11, 2));
      expect(days.length, 7);
      expect(days.first, '2026-11-02');
      expect(days.last, '2026-11-08');
    });

    test('no weekStart means the current Phnom Penh week', () {
      final monday = cleanWeekStart(
        <String, String>{},
        nowUtc: DateTime.utc(2026, 11, 8, 3),
      );
      expect(monday, DateTime.utc(2026, 11, 2));
    });

    test('late evening UTC is already the new week in Cambodia', () {
      // 20:00 UTC on Sunday 8 Nov is Monday 9 Nov in Phnom Penh.
      final monday = cleanWeekStart(
        <String, String>{},
        nowUtc: DateTime.utc(2026, 11, 8, 20),
      );
      expect(monday, DateTime.utc(2026, 11, 9));
    });

    test('the Phnom Penh date is not the UTC date at night', () {
      expect(
        phnomPenhDate(DateTime.utc(2026, 11, 8, 20)),
        DateTime.utc(2026, 11, 9),
      );
    });

    test('a day inside the week picks that week', () {
      final monday = cleanWeekStart(<String, String>{
        'weekStart': '2026-11-05',
      });
      expect(monday, DateTime.utc(2026, 11, 2));
    });

    test('a broken weekStart is refused', () {
      expect(
        _apiError(
          () => cleanWeekStart(<String, String>{'weekStart': 'next-week'}),
        ).statusCode,
        400,
      );
    });
  });

  group('the arrow on the dashboard cards', () {
    test('a rise from 240 to 1240 is 416 percent', () {
      expect(percentChange(1240, 240), 416.7);
    });

    test('a fall is negative', () {
      expect(percentChange(60, 100), -40.0);
    });

    test('nothing to nothing is zero, not a division by zero', () {
      expect(percentChange(0, 0), 0);
    });

    test('a start from zero has no percentage', () {
      expect(percentChange(120, 0), isNull);
    });
  });

  group('the payment switch on screen 39', () {
    test('only paid and unpaid exist', () {
      expect(adminPaymentStatuses, <String>['unpaid', 'paid']);
    });
  });
}
