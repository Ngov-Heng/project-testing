import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/product_service.dart';
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
  group('the 100 kg reorder level from screen 43', () {
    test('under 100 kg is low stock', () {
      expect(stockStatus(99), 'low');
      expect(stockStatus(1), 'low');
    });

    test('exactly 100 kg is in stock, not low', () {
      expect(stockStatus(100), 'in_stock');
      expect(stockStatus(1240), 'in_stock');
    });

    test('zero is out of stock', () {
      expect(stockStatus(0), 'out');
    });

    test('a negative number is still out, never low', () {
      expect(stockStatus(-5), 'out');
    });
  });

  group('screen 42 fields', () {
    test('the name is trimmed', () {
      expect(cleanProductName('  Jasmine rice '), 'Jasmine rice');
    });

    test('a missing name is refused', () {
      expect(
        _apiError(() => cleanProductName(null)).message,
        'name is required',
      );
    });

    test('an 81 character name is refused', () {
      expect(
        _apiError(() => cleanProductName('a' * 81)).message,
        'name must be 80 characters or less',
      );
    });

    test('the price is kept to two decimals', () {
      expect(cleanPricePerKg(1.999), 2.0);
      expect(cleanPricePerKg(1.4), 1.4);
    });

    test('a free product is refused', () {
      expect(
        _apiError(() => cleanPricePerKg(0)).message,
        'pricePerKg must be more than 0',
      );
    });

    test('a negative price is refused', () {
      expect(_apiError(() => cleanPricePerKg(-2)).statusCode, 400);
    });

    test('stock is a whole number of kg', () {
      expect(cleanStockKg(120), 120);
      expect(cleanStockKg(0), 0);
    });

    test('half a kilogram of stock is refused', () {
      expect(
        _apiError(() => cleanStockKg(1.5)).message,
        'stock must be whole kilograms',
      );
    });

    test('negative stock is refused', () {
      expect(
        _apiError(() => cleanStockKg(-1)).message,
        'stock cannot be negative',
      );
    });

    test('a 160 character description is allowed', () {
      expect(cleanDescription('a' * 160)?.length, 160);
    });

    test('161 characters is not', () {
      expect(
        _apiError(() => cleanDescription('a' * 161)).message,
        'description must be 160 characters or less',
      );
    });

    test('an empty description is stored as nothing', () {
      expect(cleanDescription('   '), isNull);
    });

    test('the Active switch is on when it is missing', () {
      expect(cleanIsActive(null), isTrue);
      expect(cleanIsActive(false), isFalse);
    });

    test('featured is off unless the shop asks for it', () {
      expect(cleanIsFeatured(null), isFalse);
      expect(cleanIsFeatured(true), isTrue);
    });
  });

  group('screen 41 filters', () {
    test('the defaults show everything, newest page first', () {
      final filters = adminProductFilters(<String, String>{});
      expect(filters.page, 1);
      expect(filters.limit, 20);
      expect(filters.stockLevel, 'all');
      expect(filters.search, isNull);
      expect(filters.category, isNull);
    });

    test('a stock level that is not one of the four is refused', () {
      expect(
        _apiError(
          () => adminProductFilters(<String, String>{'stockLevel': 'empty'}),
        ).message,
        'stockLevel must be all, in_stock, low or out',
      );
    });

    test('a limit over 100 is refused', () {
      expect(
        _apiError(
          () => adminProductFilters(<String, String>{'limit': '101'}),
        ).statusCode,
        400,
      );
    });

    test('an empty search box means no search', () {
      final filters = adminProductFilters(<String, String>{'q': '   '});
      expect(filters.search, isNull);
    });

    test('the low filter only asks for stock between 1 and 99', () {
      final selector = buildProductQuery(
        adminProductFilters(<String, String>{'stockLevel': 'low'}),
      );
      final stock =
          conditionsOf(
                selector,
              ).firstWhere((c) => c.containsKey('stock'))['stock']!
              as Map;
      final both = conditionsOf(selector).toString();
      expect(both, contains(r'$gt: 0'));
      expect(both, contains(r'$lt: 100'));
      expect(stock, isNotNull);
    });

    test('the in stock filter starts at 100 kg', () {
      final selector = buildProductQuery(
        adminProductFilters(<String, String>{'stockLevel': 'in_stock'}),
      );
      final stock =
          conditionsOf(
                selector,
              ).firstWhere((c) => c.containsKey('stock'))['stock']!
              as Map;
      expect(stock[r'$gte'], 100);
    });

    test('the out filter asks for zero or less', () {
      final selector = buildProductQuery(
        adminProductFilters(<String, String>{'stockLevel': 'out'}),
      );
      final stock =
          conditionsOf(
                selector,
              ).firstWhere((c) => c.containsKey('stock'))['stock']!
              as Map;
      expect(stock[r'$lte'], 0);
    });

    test('no filter means an empty query', () {
      final filters = adminProductFilters(<String, String>{});
      final selector = buildProductQuery(filters);
      expect(conditionsOf(selector).first, isEmpty);
    });

    test('the category filter is an exact match', () {
      final selector = buildProductQuery(
        adminProductFilters(<String, String>{'category': 'Jasmine'}),
      );
      expect(conditionsOf(selector).first['category'], 'Jasmine');
    });
  });

  group('the admin view of a product', () {
    test('carries an id, the status and no _id', () {
      final view = adminProductView(<String, dynamic>{
        '_id': ObjectId(),
        'name': 'Jasmine rice',
        'category': 'Jasmine',
        'pricePerKg': 1.48,
        'stock': 48,
        'isActive': true,
      });
      expect(view['id'], matches(RegExp(r'^[0-9a-f]{24}$')));
      expect(view.containsKey('_id'), isFalse);
      expect(view['stockStatus'], 'low');
      expect(view['isFeatured'], isFalse);
    });

    test('a product with no stock field counts as sold out', () {
      final view = adminProductView(<String, dynamic>{
        '_id': ObjectId(),
        'name': 'Old rice',
        'category': 'Jasmine',
        'pricePerKg': 1.5,
      });
      expect(view['stock'], 0);
      expect(view['stockStatus'], 'out');
    });
  });

  group('the product id in the URL', () {
    test('a hex id is parsed', () {
      final id = ObjectId();
      expect(parseProductId(id.oid).oid, id.oid);
    });

    test('a broken id answers 404, not a crash', () {
      expect(
        _apiError(() => parseProductId('not-an-id')).statusCode,
        404,
      );
    });
  });
}
