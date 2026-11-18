import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/cart_service.dart';
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

ObjectId _id(String hex) => ObjectId.fromHexString(hex);
final _jasmine = _id('65f1a0000000000000000001');
final _sticky = _id('65f1a0000000000000000002');

Map<String, dynamic> _line(ObjectId productId, num kg) => <String, dynamic>{
  'productId': productId,
  'quantityKg': kg,
};

void main() {
  group('roundKg - what reaches the database', () {
    test('two decimals is enough for a scale', () {
      expect(roundKg(2.500000001), 2.5);
      expect(roundKg(12.345), 12.35);
      expect(roundKg(149.999), 150.0);
    });

    test('a whole kg stays whole', () {
      expect(roundKg(10), 10);
      expect(roundKg(100.0), 100);
    });

    test('the classic float case does not leak', () {
      expect(roundKg(0.1 + 0.2), 0.3);
    });
  });

  group('checkedQuantityKg - the number a buyer can type', () {
    test('0 kg is refused', () {
      final error = _apiError(() => checkedQuantityKg(0));
      expect(error.statusCode, 400);
      expect(error.message, 'quantityKg must be greater than 0');
    });

    test('a negative quantity is refused with the same message', () {
      final error = _apiError(() => checkedQuantityKg(-5));
      expect(error.statusCode, 400);
      expect(error.message, 'quantityKg must be greater than 0');
    });

    test('something that rounds to zero is refused too', () {
      final error = _apiError(() => checkedQuantityKg(0.004));
      expect(error.statusCode, 400);
    });

    test('the minimum, 10 grams, is accepted', () {
      expect(checkedQuantityKg(0.01), 0.01);
    });

    test('an accepted quantity comes back rounded', () {
      expect(checkedQuantityKg(12.345), 12.35);
      expect(checkedQuantityKg(2.5), 2.5);
    });
  });

  group('kgLabel - how a quantity is printed', () {
    test('a whole amount has no decimals', () {
      expect(kgLabel(10), '10');
      expect(kgLabel(500.0), '500');
    });

    test('a fraction keeps its decimals', () {
      expect(kgLabel(10.5), '10.5');
      expect(kgLabel(10.456), '10.46');
    });
  });

  group('ensureStockKg - the stock guard', () {
    test('a product with no stock field is unlimited', () {
      ensureStockKg(null, 'Jasmine rice', 5000);
    });

    test('exactly the stock left is allowed', () {
      ensureStockKg(10, 'Jasmine rice', 10);
    });

    test('one kilo more than the shelf is refused', () {
      final error = _apiError(() => ensureStockKg(10, 'Jasmine rice', 11));
      expect(error.statusCode, 409);
      expect(error.message, 'Not enough stock of Jasmine rice: 10 kg left');
    });

    test('the message rounds the stock it reports', () {
      final error = _apiError(() => ensureStockKg(10.456, 'Sticky rice', 11));
      expect(error.message, 'Not enough stock of Sticky rice: 10.46 kg left');
    });
  });

  group('withQuantityAdded - one product is one line', () {
    test('the first add creates the line', () {
      final next = withQuantityAdded(<Map<String, dynamic>>[], _jasmine, 5);
      expect(next, hasLength(1));
      expect(next.first['productId'], _jasmine);
      expect(next.first['quantityKg'], 5);
    });

    test('adding the same product again adds to the quantity', () {
      final first = withQuantityAdded(<Map<String, dynamic>>[], _jasmine, 5);
      final second = withQuantityAdded(first, _jasmine, 2);
      expect(second, hasLength(1));
      expect(second.first['quantityKg'], 7);
    });

    test('two different products make two lines', () {
      final first = withQuantityAdded(<Map<String, dynamic>>[], _jasmine, 5);
      final second = withQuantityAdded(first, _sticky, 2);
      expect(second, hasLength(2));
      expect(second.map((item) => item['productId']), [_jasmine, _sticky]);
    });

    test('10 + 0.1 + 0.2 does not drift', () {
      var cart = withQuantityAdded(<Map<String, dynamic>>[], _jasmine, 10);
      cart = withQuantityAdded(cart, _jasmine, 0.1);
      cart = withQuantityAdded(cart, _jasmine, 0.2);
      expect(cart.first['quantityKg'], 10.3);
    });

    test('the list it was given is not changed', () {
      final before = <Map<String, dynamic>>[_line(_jasmine, 5)];
      withQuantityAdded(before, _jasmine, 5);
      expect(before.first['quantityKg'], 5);
    });
  });

  group('withQuantitySet - the change endpoint', () {
    test('sets the line it was asked for', () {
      final cart = <Map<String, dynamic>>[_line(_jasmine, 5)];
      final next = withQuantitySet(cart, _jasmine, 20);
      expect(next.first['quantityKg'], 20);
    });

    test('a product that is not in the cart is a 404', () {
      final cart = <Map<String, dynamic>>[_line(_jasmine, 5)];
      final error = _apiError(() => withQuantitySet(cart, _sticky, 20));
      expect(error.statusCode, 404);
      expect(error.message, 'Item is not in the cart');
    });

    test('the other lines are left alone', () {
      final cart = <Map<String, dynamic>>[
        _line(_jasmine, 5),
        _line(_sticky, 2),
      ];
      final next = withQuantitySet(cart, _sticky, 9);
      expect(next.first['quantityKg'], 5);
      expect(next.last['quantityKg'], 9);
    });

    test('the list it was given is not changed', () {
      final cart = <Map<String, dynamic>>[_line(_jasmine, 5)];
      withQuantitySet(cart, _jasmine, 20);
      expect(cart.first['quantityKg'], 5);
    });
  });

  group('withoutLine - removing a line', () {
    test('removes the line it was asked for', () {
      final cart = <Map<String, dynamic>>[
        _line(_jasmine, 5),
        _line(_sticky, 2),
      ];
      final next = withoutLine(cart, _jasmine);
      expect(next, hasLength(1));
      expect(next.first['productId'], _sticky);
    });

    test('removing what is not there is a 404, not a quiet success', () {
      final cart = <Map<String, dynamic>>[_line(_jasmine, 5)];
      final error = _apiError(() => withoutLine(cart, _sticky));
      expect(error.statusCode, 404);
      expect(error.message, 'Item is not in the cart');
    });

    test('removing the same product twice fails the second time', () {
      final cart = <Map<String, dynamic>>[_line(_jasmine, 5)];
      final once = withoutLine(cart, _jasmine);
      expect(once, isEmpty);
      final error = _apiError(() => withoutLine(once, _jasmine));
      expect(error.statusCode, 404);
    });

    test('the list it was given is not changed', () {
      final cart = <Map<String, dynamic>>[_line(_jasmine, 5)];
      withoutLine(cart, _jasmine);
      expect(cart, hasLength(1));
    });
  });

  group('the quantity rule and the stock rule agree', () {
    test('a valid quantity can still be refused by the stock', () {
      final kg = checkedQuantityKg(999);
      final error = _apiError(() => ensureStockKg(500, 'Jasmine rice', kg));
      expect(error.statusCode, 409);
      expect(error.message, 'Not enough stock of Jasmine rice: 500 kg left');
    });

    test('what the cart stores is what the stock guard checked', () {
      final kg = checkedQuantityKg(12.345);
      final next = withQuantityAdded(<Map<String, dynamic>>[], _jasmine, kg);
      expect(next.first['quantityKg'], 12.35);
      expect(
        () => ensureStockKg(12.35, 'Jasmine rice', 12.35),
        returnsNormally,
      );
    });
  });
}
