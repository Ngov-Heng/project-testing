import 'dart:math';

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/notification_service.dart';
import 'package:faheng_api/services/paypal_service.dart';
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
  String method = 'paypal',
  String status = 'pending',
  String paid = 'unpaid',
  int cents = 17020,
}) =>
    <String, dynamic>{
      '_id': ObjectId(),
      'orderNumber': 'FH-1042',
      'paymentMethod': method,
      'paymentStatus': paid,
      'status': status,
      'grandTotalCents': cents,
    };

void main() {
  group('which order can be paid with PayPal', () {
    test('a cash order is not one of them', () {
      final error = _apiError(() => checkPaypalOrder(_order(method: 'cod')));
      expect(error.statusCode, 400);
      expect(error.message, 'This order is paid on delivery');
    });

    test('a cancelled order cannot be paid', () {
      final error = _apiError(
        () => checkPaypalOrder(_order(status: 'cancelled')),
      );
      expect(error.statusCode, 409);
      expect(error.message, 'A cancelled order cannot be paid');
    });

    test('an order that is already paid cannot be paid twice', () {
      final error = _apiError(() => checkPaypalOrder(_order(paid: 'paid')));
      expect(error.message, 'This order is already paid');
    });

    test('the narrow method check only looks at the method', () {
      // The capture path needs this: a payment that was already captured is
      // answered with the payment's state, not the order's.
      checkPaypalMethod(_order(paid: 'paid'));
      final error = _apiError(() => checkPaypalMethod(_order(method: 'cod')));
      expect(error.message, 'This order is paid on delivery');
    });

    test('a fresh PayPal order passes', () {
      // Nothing thrown is the whole assertion.
      checkPaypalOrder(_order());
    });
  });

  group('the amount on screen 21a', () {
    test('it is the grand total, in cents', () {
      // The mock: 148.00 + 19.20 + 3.00 delivery = 170.20.
      expect(paypalAmountCents(_order()), 17020);
    });

    test('an order with no total charges nothing, not null', () {
      expect(paypalAmountCents(<String, dynamic>{}), 0);
    });
  });

  group('the sandbox payment id', () {
    test('it is marked as a sandbox id', () {
      expect(newSandboxPaypalOrderId(Random(1)), startsWith('SBX-'));
    });

    test('two payments never share an id', () {
      final random = Random(7);
      final ids = <String>{
        for (var i = 0; i < 50; i++) newSandboxPaypalOrderId(random),
      };
      expect(ids.length, 50);
    });

    test('the approval link carries the payment id', () {
      expect(
        sandboxApprovalUrl('SBX-ABC123'),
        '/api/payments/paypal/approve?token=SBX-ABC123',
      );
    });
  });

  group('one payment as the app receives it', () {
    test('it carries a hex id, the amount in dollars and the state', () {
      final view = paymentView(<String, dynamic>{
        '_id': ObjectId(),
        'provider': 'paypal',
        'paypalOrderId': 'SBX-ABC123',
        'amountCents': 17020,
        'status': 'captured',
        'approvalUrl': '/api/payments/paypal/approve?token=SBX-ABC123',
        'createdAt': DateTime.utc(2026, 11, 7, 9),
        'capturedAt': DateTime.utc(2026, 11, 7, 9, 2),
      });
      expect((view['id']! as String).length, 24);
      expect(view['paypalOrderId'], 'SBX-ABC123');
      expect(view['amount'], 170.2);
      expect(view['status'], 'captured');
      expect(view['createdAt'], '2026-11-07T09:00:00.000Z');
      expect(view['capturedAt'], '2026-11-07T09:02:00.000Z');
      expect(view.containsKey('failedAt'), isFalse);
    });
  });

  group('the capture body', () {
    test('the payment id is required', () {
      final error = _apiError(
        () => cleanCaptureInput(<String, dynamic>{}),
      );
      expect(error.statusCode, 400);
      expect(error.message, 'paypalOrderId is required');
    });

    test('no approved flag means the buyer pressed pay', () {
      final input = cleanCaptureInput(<String, dynamic>{
        'paypalOrderId': 'SBX-ABC123',
      });
      expect(input.approved, isTrue);
    });

    test('approved false is how screen 24 is reached', () {
      final input = cleanCaptureInput(<String, dynamic>{
        'paypalOrderId': 'SBX-ABC123',
        'approved': false,
      });
      expect(input.approved, isFalse);
    });

    test('approved has to be a boolean', () {
      final error = _apiError(
        () => cleanCaptureInput(<String, dynamic>{
          'paypalOrderId': 'SBX-ABC123',
          'approved': 'yes',
        }),
      );
      expect(error.message, 'approved must be true or false');
    });

    test('a body that is not an object is refused', () {
      final error = _apiError(() => cleanCaptureInput('SBX-ABC123'));
      expect(error.message, 'Body must be a JSON object');
    });
  });

  group('the payment notification', () {
    test('there is a type for "your money arrived"', () {
      expect(notificationTypes, contains('payment_received'));
    });
  });
}
