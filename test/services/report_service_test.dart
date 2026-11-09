import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/report_service.dart';
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

Map<String, dynamic> _order({
  String status = 'delivered',
  int cents = 10000,
  num kg = 10,
  String createdAt = '2026-11-05T03:00:00.000Z',
  ObjectId? userId,
  List<Map<String, dynamic>> items = const [],
}) =>
    <String, dynamic>{
      '_id': ObjectId(),
      'userId': userId ?? ObjectId(),
      'orderNumber': 'FH-1036',
      'status': status,
      'grandTotalCents': cents,
      'totalWeightKg': kg,
      'createdAt': DateTime.parse(createdAt),
      'items': items,
    };

Map<String, dynamic> _item(ObjectId productId, String name, num kg,
        int cents) =>
    <String, dynamic>{
      'productId': productId,
      'name': name,
      'quantityKg': kg,
      'lineTotalCents': cents,
    };

void main() {
  // 7 Nov 2026 is a Saturday; the report "today" in these tests is 7 Nov.
  final nowUtc = DateTime.utc(2026, 11, 7, 5);

  group('the range picker on screen 49', () {
    test('no range means the last seven days, today included', () {
      final range = reportRange(<String, String>{}, nowUtc: nowUtc);
      expect(range.from, DateTime.utc(2026, 11));
      expect(range.to, DateTime.utc(2026, 11, 7));
      expect(range.days.length, 7);
      expect(range.days.first, '2026-11-01');
      expect(range.days.last, '2026-11-07');
    });

    test('an explicit range is used as given', () {
      final range = reportRange(
        <String, String>{'from': '2026-11-01', 'to': '2026-11-07'},
        nowUtc: nowUtc,
      );
      expect(range.days.length, 7);
    });

    test('one day is a range of one', () {
      final range = reportRange(
        <String, String>{'from': '2026-11-07', 'to': '2026-11-07'},
        nowUtc: nowUtc,
      );
      expect(range.days, ['2026-11-07']);
    });

    test('a range that runs backwards is refused', () {
      final error = _apiError(
        () => reportRange(
          <String, String>{'from': '2026-11-07', 'to': '2026-11-01'},
          nowUtc: nowUtc,
        ),
      );
      expect(error.statusCode, 400);
      expect(error.message, 'from cannot be after to');
    });

    test('a date that is not a date is refused', () {
      final error = _apiError(
        () => reportRange(
          <String, String>{'from': '2026-13-01'},
          nowUtc: nowUtc,
        ),
      );
      expect(error.message, 'from is not a real date');
    });

    test('a range longer than a year is refused', () {
      final error = _apiError(
        () => reportRange(
          <String, String>{'from': '2024-01-01', 'to': '2026-11-07'},
          nowUtc: nowUtc,
        ),
      );
      expect(error.message, 'the range cannot be longer than a year');
    });

    test('the range is a Phnom Penh day, not a UTC one', () {
      // 20:00 UTC on 6 Nov is already 7 Nov in Cambodia.
      final range = reportRange(
        <String, String>{},
        nowUtc: DateTime.utc(2026, 11, 6, 20),
      );
      expect(range.to, DateTime.utc(2026, 11, 7));
    });
  });

  group('the three cards on screen 49', () {
    test('revenue, orders and the average come out of the same orders', () {
      final summary = reportSummary([
        _order(cents: 100000),
        _order(cents: 80000, kg: 30),
      ]);
      expect(summary['revenue'], 1800.0);
      expect(summary['orders'], 2);
      expect(summary['averageOrder'], 900.0);
      expect(summary['totalKg'], 40.0);
    });

    test('cancelled orders are counted separately, not as sales', () {
      final summary = reportSummary([
        _order(cents: 100000),
        _order(status: 'cancelled', cents: 50000),
      ]);
      expect(summary['revenue'], 1000.0);
      expect(summary['orders'], 1);
      expect(summary['cancelled'], 1);
      expect(summary['cancelledValue'], 500.0);
    });

    test('a day with no orders divides by nothing and says zero', () {
      expect(reportSummary(const [])['averageOrder'], 0.0);
    });
  });

  group('the line chart', () {
    final range = reportRange(
      <String, String>{'from': '2026-11-01', 'to': '2026-11-07'},
      nowUtc: nowUtc,
    );

    test('every day of the range gets a point, empty days included', () {
      final daily = dailyRevenue([], range);
      expect(daily.length, 7);
      expect(daily.every((row) => row['revenue'] == 0.0), isTrue);
      expect(daily.first['date'], '2026-11-01');
    });

    test('an order lands on its Phnom Penh day, not its UTC day', () {
      // 20:00 UTC on 6 Nov is 03:00 on 7 Nov in Cambodia.
      final daily = dailyRevenue(
        [_order(cents: 50000, createdAt: '2026-11-06T20:00:00.000Z')],
        range,
      );
      final seventh = daily[6];
      expect(seventh['date'], '2026-11-07');
      expect(seventh['revenue'], 500.0);
      expect(seventh['orders'], 1);
    });

    test('a cancelled order is not a point on the chart', () {
      final daily = dailyRevenue(
        [_order(status: 'cancelled', cents: 50000)],
        range,
      );
      expect(daily.every((row) => row['revenue'] == 0.0), isTrue);
    });

    test('two orders on one day add up', () {
      final daily = dailyRevenue(
        [
          _order(createdAt: '2026-11-02T03:00:00.000Z'),
          _order(cents: 25000, createdAt: '2026-11-02T09:00:00.000Z'),
        ],
        range,
      );
      expect(daily[1]['revenue'], 350.0);
      expect(daily[1]['orders'], 2);
    });
  });

  group('top selling products', () {
    test('they are sorted by kg sold, biggest first', () {
      final jasmine = ObjectId();
      final sticky = ObjectId();
      final rows = topSellingProducts([
        _order(items: [_item(jasmine, 'Jasmine rice', 20, 2400)]),
        _order(items: [_item(sticky, 'Sticky rice', 60, 8400)]),
        _order(items: [_item(jasmine, 'Jasmine rice', 30, 3600)]),
      ]);
      expect(rows.first['name'], 'Sticky rice');
      expect(rows.first['kgSold'], 60.0);
      expect(rows.last['name'], 'Jasmine rice');
      expect(rows.last['kgSold'], 50.0);
      expect(rows.last['revenue'], 60.0);
    });

    test('a cancelled order sold nothing', () {
      final product = ObjectId();
      final rows = topSellingProducts([
        _order(status: 'cancelled', items: [_item(product, 'Rice', 90, 9000)]),
      ]);
      expect(rows, isEmpty);
    });

    test('only the top five are returned', () {
      final rows = topSellingProducts([
        for (var i = 0; i < 8; i++)
          _order(items: [_item(ObjectId(), 'Rice $i', 10 + i, 1000)]),
      ]);
      expect(rows.length, 5);
      expect(rows.first['name'], 'Rice 7');
    });
  });

  group('best customers', () {
    test('they are sorted by spend, and the name comes from users', () {
      final chenda = ObjectId();
      final nita = ObjectId();
      final users = <String, Map<String, dynamic>>{
        chenda.oid: <String, dynamic>{
          'name': 'Chenda Lim',
          'customerType': 'business',
          'town': 'Kampot town',
        },
        nita.oid: <String, dynamic>{
          'name': 'Nita Sovann',
          'customerType': 'business',
          'town': 'Takeo',
        },
      };
      final rows = bestCustomers(
        [
          _order(userId: chenda, cents: 40000),
          _order(userId: nita, cents: 53880),
          _order(userId: nita, cents: 1000),
        ],
        users,
      );
      expect(rows.first['name'], 'Nita Sovann');
      expect(rows.first['spent'], 548.8);
      expect(rows.first['orders'], 2);
      expect(rows.last['name'], 'Chenda Lim');
      expect(rows.last['town'], 'Kampot town');
    });

    test('a cancelled order is not spend', () {
      final user = ObjectId();
      final rows = bestCustomers(
        [_order(userId: user, status: 'cancelled', cents: 90000)],
        {user.oid: <String, dynamic>{'name': 'Chenda Lim'}},
      );
      expect(rows, isEmpty);
    });

    test('a customer missing from users still gets a row', () {
      final user = ObjectId();
      final rows = bestCustomers([_order(userId: user, cents: 5000)], const {});
      expect(rows.single['name'], 'Customer');
      expect(rows.single['customerType'], 'household');
    });
  });
}
