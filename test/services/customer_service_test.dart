import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/customer_service.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:test/test.dart';

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
  String createdAt = '2026-11-05T03:00:00.000Z',
}) =>
    <String, dynamic>{
      '_id': ObjectId(),
      'orderNumber': 'FH-1036',
      'status': status,
      'grandTotalCents': cents,
      'createdAt': DateTime.parse(createdAt),
    };

Map<String, dynamic> _user({
  String name = 'Chenda Lim',
  String type = 'business',
}) =>
    <String, dynamic>{
      '_id': ObjectId(),
      'name': name,
      'phone': '+855 10 664 219',
      'email': null,
      'customerType': type,
      'createdAt': DateTime.utc(2026, 8, 4),
    };

void main() {
  group('the numbers on screens 45 and 46', () {
    test('a customer with no orders is all zeroes', () {
      final totals = customerTotals(const []);
      expect(totals.orders, 0);
      expect(totals.totalSpentCents, 0);
      expect(totals.averageOrderCents, 0);
      expect(totals.firstOrderAt, isNull);
      expect(totals.lastOrderAt, isNull);
    });

    test('a cancelled order is not a purchase', () {
      final totals = customerTotals([
        _order(cents: 12300),
        _order(status: 'cancelled', cents: 99999),
      ]);
      expect(totals.orders, 1);
      expect(totals.totalSpentCents, 12300);
    });

    test('the mock on screen 46 adds up: 11 orders, 5126.80, 466.07', () {
      final orders = <Map<String, dynamic>>[
        for (var i = 0; i < 10; i++) _order(cents: 46600),
        _order(cents: 46680),
      ];
      final totals = customerTotals(orders);
      expect(totals.orders, 11);
      expect(totals.totalSpentCents / 100, 5126.8);
      expect(totals.averageOrderCents / 100, 466.07);
    });

    test('the first and last order dates are the real ends', () {
      final totals = customerTotals([
        _order(),
        _order(createdAt: '2026-08-20T03:00:00.000Z'),
        _order(createdAt: '2026-10-02T03:00:00.000Z'),
      ]);
      expect(totals.firstOrderAt, DateTime.utc(2026, 8, 20, 3));
      expect(totals.lastOrderAt, DateTime.utc(2026, 11, 5, 3));
    });
  });

  group('the town under a customer name', () {
    test('the default address wins', () {
      final town = townOf([
        <String, dynamic>{'town': 'Kampot town', 'isDefault': false},
        <String, dynamic>{'town': 'Takeo', 'isDefault': true},
      ]);
      expect(town, 'Takeo');
    });

    test('with no default the newest one is used', () {
      final town = townOf([
        <String, dynamic>{'town': 'Kampot town', 'isDefault': false},
        <String, dynamic>{'town': 'Kep', 'isDefault': false},
      ]);
      expect(town, 'Kep');
    });

    test('a customer with no address has no town', () {
      expect(townOf(const []), isNull);
    });
  });

  group('one row of screen 45', () {
    test('it carries the counts, the money in dollars and a hex id', () {
      final user = _user();
      final row = adminCustomerRow(
        user,
        totals: customerTotals([_order(cents: 512680)]),
        town: 'Kampot town',
      );
      expect((row['id']! as String).length, 24);
      expect(row['name'], 'Chenda Lim');
      expect(row['customerType'], 'business');
      expect(row['town'], 'Kampot town');
      expect(row['orders'], 1);
      expect(row['totalSpent'], 5126.8);
      expect(row['joinedAt'], '2026-08-04T00:00:00.000Z');
    });

    test('a customer with no type yet is a household', () {
      final user = _user()..remove('customerType');
      final row = adminCustomerRow(
        user,
        totals: customerTotals(const []),
        town: null,
      );
      expect(row['customerType'], 'household');
      expect(row['lastOrderAt'], isNull);
    });
  });

  group('the dropdown on screen 45', () {
    test('all means no filter', () {
      expect(cleanCustomerType(<String, String>{}), isNull);
      final all = cleanCustomerType(<String, String>{'customerType': 'all'});
      expect(all, isNull);
    });

    test('business narrows it down', () {
      expect(
        cleanCustomerType(<String, String>{'customerType': 'business'}),
        'business',
      );
    });

    test('a made up type is refused', () {
      final error = _apiError(
        () => cleanCustomerType(<String, String>{'customerType': 'vip'}),
      );
      expect(error.statusCode, 400);
      expect(error.message, 'customerType must be all, business or household');
    });
  });

  group('who counts as a customer', () {
    test('the shop owner is not one of the shop customers', () {
      final selector = buildCustomerQuery(<String, String>{});
      expect(selector.map.toString(), contains('admin'));
    });

    test('the type filter is added on top', () {
      final selector = buildCustomerQuery(
        <String, String>{'customerType': 'household'},
      );
      expect(selector.map.toString(), contains('household'));
    });
  });
}
