import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/order_service.dart';
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

void main() {
  final nowUtc = DateTime.utc(2026, 11, 8, 3);

  test('today is decided in Phnom Penh time, not UTC', () {
    expect(
      phnomPenhToday(nowUtc: DateTime.utc(2026, 11, 8, 20)),
      DateTime.utc(2026, 11, 9),
    );

    expect(
      phnomPenhToday(nowUtc: DateTime.utc(2026, 11, 9, 1)),
      DateTime.utc(2026, 11, 9),
    );
  });

  test('tomorrow is accepted', () {
    expect(
      cleanDeliveryDate('2026-11-09', nowUtc: nowUtc),
      '2026-11-09',
    );
  });

  test('seven days ahead is accepted, eight is not', () {
    expect(cleanDeliveryDate('2026-11-15', nowUtc: nowUtc), '2026-11-15');
    final error = _apiError(
      () => cleanDeliveryDate('2026-11-16', nowUtc: nowUtc),
    );
    expect(error.statusCode, 400);
    expect(error.message, contains('tomorrow and 7 days'));
  });

  test('today and yesterday are refused', () {
    final today = _apiError(
      () => cleanDeliveryDate('2026-11-08', nowUtc: nowUtc),
    );
    expect(today.statusCode, 400);
    final yesterday = _apiError(
      () => cleanDeliveryDate('2026-11-01', nowUtc: nowUtc),
    );
    expect(yesterday.statusCode, 400);
  });

  test('a date in the wrong shape is refused', () {
    expect(
      _apiError(() => cleanDeliveryDate('10/11/2026', nowUtc: nowUtc)).message,
      'deliveryDate must look like 2026-11-10',
    );
    expect(
      _apiError(() => cleanDeliveryDate(20261110, nowUtc: nowUtc)).statusCode,
      400,
    );
  });

  test('a date that does not exist is refused', () {
    final error = _apiError(
      () => cleanDeliveryDate('2026-02-30', nowUtc: nowUtc),
    );
    expect(error.message, 'deliveryDate is not a real date');
  });

  test('the delivery window is stored lowercase', () {
    expect(cleanDeliveryWindow('morning'), 'morning');
    expect(cleanDeliveryWindow(' Afternoon '), 'afternoon');
    expect(
      _apiError(() => cleanDeliveryWindow('evening')).message,
      'deliveryWindow must be morning or afternoon',
    );
    expect(_apiError(() => cleanDeliveryWindow(null)).statusCode, 400);
  });

  test('the payment method is stored lowercase', () {
    expect(cleanPaymentMethod('stripe'), 'stripe');
    expect(cleanPaymentMethod('COD'), 'cod');
    expect(
      _apiError(() => cleanPaymentMethod('card')).message,
      'paymentMethod must be stripe or cod',
    );
  });

  test('order numbers start at FH-1001', () {
    expect(firstOrderNumber, 1001);
    expect(orderNumberFor(firstOrderNumber), 'FH-1001');
    expect(orderNumberFor(1042), 'FH-1042');
  });

  test('only pending and processing orders can be cancelled', () {
    expect(canCancel('pending'), isTrue);
    expect(canCancel('processing'), isTrue);
    expect(canCancel('on_the_way'), isFalse);
    expect(canCancel('delivered'), isFalse);
    expect(canCancel('cancelled'), isFalse);
  });

  test('status changes follow the map and never skip a step', () {
    expect(canChangeStatus('pending', 'processing'), isTrue);
    expect(canChangeStatus('pending', 'cancelled'), isTrue);
    expect(canChangeStatus('processing', 'on_the_way'), isTrue);
    expect(canChangeStatus('on_the_way', 'delivered'), isTrue);
    expect(canChangeStatus('pending', 'delivered'), isFalse);
    expect(canChangeStatus('delivered', 'cancelled'), isFalse);
    expect(canChangeStatus('cancelled', 'pending'), isFalse);
    expect(canChangeStatus('on_the_way', 'processing'), isFalse);
  });

  test('kg text has no trailing .0', () {
    expect(kgText(150), '150');
    expect(kgText(2.5), '2.5');
    expect(kgText(null), '0');
  });

  test('a malformed order id answers 404', () {
    final error = _apiError(() => parseOrderId('nope'));
    expect(error.statusCode, 404);
    expect(error.message, 'Order not found');
  });

  test('an addressId that is not hex is a 400 that names the field', () {
    final error = _apiError(() => cleanObjectId('not-hex', 'addressId'));
    expect(error.statusCode, 400);
    expect(error.message, 'addressId is not valid');
  });

  test('a cancel reason code is turned into the text the screens show', () {
    final reason = cleanCancelReason(<String, dynamic>{
      'reasonCode': 'ordered_by_mistake',
    });
    expect(reason.code, 'ordered_by_mistake');
    expect(reason.note, isNull);
    expect(reason.text, 'I ordered by mistake');
  });

  test('the optional note is added after the label', () {
    final reason = cleanCancelReason(<String, dynamic>{
      'reasonCode': 'found_better_price',
      'note': '  Cheaper at the market  ',
    });
    expect(reason.code, 'found_better_price');
    expect(reason.note, 'Cheaper at the market');
    expect(reason.text, 'I found a better price - Cheaper at the market');
  });

  test('all four reasons from screen 28 are accepted', () {
    for (final code in cancelReasons.keys) {
      expect(cleanCancelReason({'reasonCode': code}).code, code);
    }
    expect(cancelReasons, hasLength(4));
  });

  test('an unknown reason code is refused', () {
    final error = _apiError(
      () => cleanCancelReason(
        <String, dynamic>{'reasonCode': 'too_expensive'},
      ),
    );
    expect(error.statusCode, 400);
    expect(error.message, contains('reasonCode must be one of'));
  });

  test('a body with no reason at all is refused', () {
    final error = _apiError(() => cleanCancelReason(<String, dynamic>{}));
    expect(error.message, 'reasonCode is required');
  });

  test('a plain reason string is still accepted', () {
    final reason = cleanCancelReason(
      <String, dynamic>{'reason': 'Moved house'},
    );
    expect(reason.code, isNull);
    expect(reason.text, 'Moved house');
  });

  test('a note longer than 200 characters is refused', () {
    final error = _apiError(
      () => cleanCancelReason(<String, dynamic>{
        'reasonCode': 'other',
        'note': 'x' * 201,
      }),
    );
    expect(error.message, 'note must be 200 characters or less');
  });

  test('the order view returns dollars and keeps the status history', () {
    final id = ObjectId();
    final view = orderView(<String, dynamic>{
      '_id': id,
      'orderNumber': 'FH-1001',
      'orderNumberValue': 1001,
      'items': [
        {
          'productId': ObjectId(),
          'name': 'Jasmine rice premium',
          'image': 'jasmine.jpg',
          'quantityKg': 150,
          'pricePerKgCents': 120,
          'lineTotalCents': 18000,
        },
      ],
      'totalWeightKg': 150,
      'subtotalCents': 18000,
      'discountCents': 1800,
      'deliveryFeeCents': 300,
      'totalCents': 16200,
      'grandTotalCents': 16500,
      'address': {'label': 'home', 'street': 'House 14'},
      'deliveryDate': '2026-11-09',
      'deliveryWindow': 'morning',
      'paymentMethod': 'cod',
      'paymentStatus': 'unpaid',
      'status': 'pending',
      'statusHistory': [
        {'status': 'pending', 'at': '2026-11-08T03:00:00.000Z'},
      ],
      'createdAt': DateTime.utc(2026, 11, 8, 3),
    });
    expect(view['id'], id.oid);
    expect(view['subtotal'], 180.0);
    expect(view['discount'], 18.0);
    expect(view['total'], 162.0);
    expect(view['deliveryFee'], 3.0);
    expect(view['grandTotal'], 165.0);
    final line = (view['items'] as List).first as Map<String, dynamic>;
    expect(line['pricePerKg'], 1.2);
    expect(line['lineTotal'], 180.0);
    expect(view['statusHistory'], hasLength(1));
    expect(view['createdAt'], '2026-11-08T03:00:00.000Z');
    expect(view.toString().contains('Cents'), isFalse);
  });
}
