import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/quote_service.dart';
import 'package:faheng_api/services/settings_service.dart';
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

/// A quote document the way createQuote writes it.
Map<String, dynamic> _doc({
  String status = 'new',
  int? priceCents,
  int? totalCents,
  num quantityKg = 200,
}) =>
    <String, dynamic>{
      '_id': ObjectId(),
      'userId': ObjectId(),
      'requestNumber': 'QR-006',
      'requestNumberValue': 6,
      'productId': ObjectId(),
      'productName': 'Jasmine rice',
      'productCategory': 'Jasmine',
      'quantityKg': quantityKg,
      'addressId': ObjectId(),
      'address': <String, dynamic>{
        'label': 'home',
        'receiverName': 'Nita Sovann',
        'phone': '012345678',
        'street': 'House 14, Street 271, Tuek Thla',
        'town': 'Takeo',
      },
      'note': null,
      'status': status,
      'pricePerKgCents': priceCents,
      'quotedTotalCents': totalCents,
      'adminNote': null,
      'requestedAt': DateTime.utc(2026, 11, 7, 3),
      'createdAt': DateTime.utc(2026, 11, 7, 3),
    };

void main() {
  final productId = ObjectId();
  final addressId = ObjectId();

  Map<String, dynamic> body({num kg = 200}) => <String, dynamic>{
        'productId': productId.oid,
        'quantityKg': kg,
        'addressId': addressId.oid,
      };

  group('the form on screen 25', () {
    test('149 kg is under the minimum the screen prints', () {
      final error = _apiError(() => cleanQuoteInput(body(kg: 149)));
      expect(error.statusCode, 400);
      expect(error.message, 'A quote starts at 150 kg');
    });

    test('150 kg is accepted', () {
      expect(cleanQuoteInput(body(kg: 150)).quantityKg, 150);
    });

    test('a quantity sent as text is refused', () {
      final payload = body()..['quantityKg'] = '200';
      final error = _apiError(() => cleanQuoteInput(payload));
      expect(error.message, 'quantityKg is required');
    });

    test('the product is required', () {
      final payload = body()..remove('productId');
      final error = _apiError(() => cleanQuoteInput(payload));
      expect(error.message, 'productId is required');
    });

    test('a product id that is not an id is refused', () {
      final payload = body()..['productId'] = 'jasmine';
      final error = _apiError(() => cleanQuoteInput(payload));
      expect(error.message, 'productId is not a valid id');
    });

    test('the address is required', () {
      final payload = body()..remove('addressId');
      final error = _apiError(() => cleanQuoteInput(payload));
      expect(error.message, 'addressId is required');
    });

    test('the note is optional and trimmed', () {
      final payload = body()..['note'] = '  Please call before delivery.  ';
      expect(cleanQuoteInput(payload).note, 'Please call before delivery.');
    });

    test('an empty note is stored as nothing', () {
      final payload = body()..['note'] = '   ';
      expect(cleanQuoteInput(payload).note, isNull);
    });

    test('a note over 300 characters is refused', () {
      final payload = body()..['note'] = 'a' * 301;
      final error = _apiError(() => cleanQuoteInput(payload));
      expect(error.message, 'note is longer than 300 characters');
    });

    test('a body that is not an object is refused', () {
      final error = _apiError(() => cleanQuoteInput('200 kg please'));
      expect(error.message, 'Body must be a JSON object');
    });
  });

  group('the quantity is stored tidily', () {
    test('200 kg is stored as a whole number', () {
      expect(tidyKg(200), isA<int>());
      expect(tidyKg(200), 200);
    });

    test('150.5 kg keeps its half kilo', () {
      expect(tidyKg(150.5), 150.5);
    });
  });

  group('the request number on screen 47', () {
    test('it is padded to three digits', () {
      expect(quoteNumberFor(1), 'QR-001');
      expect(quoteNumberFor(6), 'QR-006');
    });

    test('it keeps growing past 999', () {
      expect(quoteNumberFor(1001), 'QR-1001');
    });
  });

  group('one quote as the buyer sees it', () {
    test('a new request has no price yet', () {
      final view = quoteView(_doc());
      expect((view['id']! as String).length, 24);
      expect(view['status'], 'new');
      expect(view['pricePerKg'], isNull);
      expect(view['total'], isNull);
      expect(view['requestNumber'], 'QR-006');
      expect((view['product']! as Map)['name'], 'Jasmine rice');
      expect((view['address']! as Map)['town'], 'Takeo');
    });

    test('a quoted request sends dollars, not cents', () {
      final view = quoteView(
        _doc(status: 'quoted', priceCents: 108, totalCents: 21600),
      );
      expect(view['pricePerKg'], 1.08);
      expect(view['total'], 216.0);
      expect(view['requestedAt'], '2026-11-07T03:00:00.000Z');
    });
  });

  group('the filters on screen 47', () {
    test('no filter asks for every request', () {
      final selector = buildQuoteQuery(<String, String>{});
      expect(selector.map.toString(), isNot(contains('status')));
    });

    test('a status narrows it down', () {
      final selector = buildQuoteQuery(<String, String>{'status': 'quoted'});
      expect(selector.map[r'$query'], <String, dynamic>{'status': 'quoted'});
    });

    test('a made up status is refused', () {
      final error = _apiError(
        () => buildQuoteQuery(<String, String>{'status': 'lost'}),
      );
      expect(error.statusCode, 400);
    });

    test('a search turns into a list of ids', () {
      final ids = [ObjectId(), ObjectId()];
      final selector = buildQuoteQuery(<String, String>{}, ids: ids);
      expect(selector.map.toString(), contains(r'$in'));
    });
  });

  group('the counts under the title of screen 47', () {
    test('every status gets a row, zero included', () {
      final counts = quoteStatusCounts(const []);
      expect(counts['all'], 0);
      expect(counts['new'], 0);
      expect(counts['quoted'], 0);
      expect(counts['accepted'], 0);
      expect(counts['declined'], 0);
    });

    test('the mock numbers add up', () {
      final counts = quoteStatusCounts([
        _doc(),
        _doc(),
        _doc(status: 'quoted'),
        _doc(status: 'quoted'),
        _doc(status: 'accepted'),
        _doc(status: 'declined'),
      ]);
      expect(counts['all'], 6);
      expect(counts['new'], 2);
      expect(counts['quoted'], 2);
      expect(counts['accepted'], 1);
      expect(counts['declined'], 1);
    });
  });

  group('the response panel of screen 47', () {
    final rules = rulesFrom(<String, dynamic>{
      'bulkDiscount': <String, dynamic>{
        'enabled': true,
        'thresholdKg': 100,
        'percent': 10,
      },
      'deliveryFeeCents': 300,
    });

    test('the shop price and the bulk suggestion are both there', () {
      final doc = _doc()..['shopPricePerKgCents'] = 148;
      final view = adminQuoteView(
        doc,
        <String, dynamic>{
          'name': 'Nita Sovann',
          'phone': '012345678',
          'customerType': 'household',
        },
        rules,
      );
      expect(view['shopPricePerKg'], 1.48);
      // 1.48 minus 10% is 1.332, which the panel prefills as 1.33.
      expect(view['suggestedPricePerKg'], 1.33);
      expect(view['bulkDiscountPercent'], 10);
      expect((view['customer']! as Map)['name'], 'Nita Sovann');
      expect((view['customer']! as Map)['town'], 'Takeo');
    });

    test('a quoted request shows the price and the total', () {
      final view = adminQuoteView(
        _doc(status: 'quoted', priceCents: 133, totalCents: 26600),
        null,
        rules,
      );
      expect(view['pricePerKg'], 1.33);
      expect(view['total'], 266.0);
    });
  });
}
