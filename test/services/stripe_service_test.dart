// Stripe: the arithmetic, the verification rule, and the two provider calls
// against a fake HTTP client.
import 'dart:convert';

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/stripe_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

ApiError? _error(void Function() body) {
  try {
    body();
    return null;
  } on ApiError catch (error) {
    return error;
  }
}

Map<String, dynamic> _intent({
  String status = 'succeeded',
  int amount = 1500,
  String currency = 'usd',
  String orderId = 'abc123',
}) =>
    <String, dynamic>{
      'id': 'pi_test_1',
      'status': status,
      'amount': amount,
      'amount_received': status == 'succeeded' ? amount : 0,
      'currency': currency,
      'metadata': <String, dynamic>{'orderId': orderId},
    };

void main() {
  group('stripeAmountCents', () {
    test('charges the grand total, fee included', () {
      expect(stripeAmountCents({'grandTotalCents': 6040}), 6040);
      expect(stripeAmountCents({'grandTotalCents': 15150.4}), 15150);
      expect(stripeAmountCents(<String, dynamic>{}), 0);
    });
  });

  group('verifyStripeIntent', () {
    test('accepts a succeeded payment for the right amount and order', () {
      final error = _error(
        () => verifyStripeIntent(
          _intent(),
          amountCents: 1500,
          orderId: 'abc123',
        ),
      );
      expect(error, isNull);
    });

    test('refuses anything that is not succeeded', () {
      final error = _error(
        () => verifyStripeIntent(
          _intent(status: 'requires_payment_method'),
          amountCents: 1500,
          orderId: 'abc123',
        ),
      );
      expect(error?.statusCode, 402);
      expect(error?.message, contains('requires_payment_method'));
    });

    test('refuses when Stripe received a different amount', () {
      final error = _error(
        () => verifyStripeIntent(
          _intent(amount: 100),
          amountCents: 1500,
          orderId: 'abc123',
        ),
      );
      expect(error?.statusCode, 409);
      expect(error?.message, contains('100'));
    });

    test('refuses a payment in another currency', () {
      final error = _error(
        () => verifyStripeIntent(
          _intent(currency: 'eur'),
          amountCents: 1500,
          orderId: 'abc123',
        ),
      );
      expect(error?.statusCode, 409);
      expect(error?.message, contains('eur'));
    });

    test('refuses a payment stamped with another order', () {
      final error = _error(
        () => verifyStripeIntent(
          _intent(orderId: 'someone-else'),
          amountCents: 1500,
          orderId: 'abc123',
        ),
      );
      expect(error?.statusCode, 409);
      expect(error?.message, 'This payment belongs to another order');
    });
  });

  group('createStripeIntent', () {
    late http.Request seen;

    setUp(() {
      stripeHttpClient = MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'id': 'pi_test_1',
            'status': 'succeeded',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
    });

    test('sends the amount, the currency and the order id', () async {
      final intent = await createStripeIntent(
        amountCents: 1500,
        orderId: 'abc123',
        description: 'Faheng Rice FH-1001',
      );

      expect(intent['id'], 'pi_test_1');
      expect(seen.method, 'POST');
      expect(seen.url.toString(), '$stripeApiBase/payment_intents');
      expect(seen.headers['Authorization'], startsWith('Bearer '));
      expect(seen.body, contains('amount=1500'));
      expect(seen.body, contains('currency=usd'));
      expect(seen.body, contains('metadata%5BorderId%5D=abc123'));
      expect(seen.body, contains('confirm=true'));
    });

    test('turns a Stripe refusal into a 502 with the reason', () async {
      stripeHttpClient = MockClient(
        (request) async => http.Response(
          jsonEncode(<String, dynamic>{
            'error': <String, dynamic>{'message': 'Your card was declined.'},
          }),
          402,
        ),
      );

      try {
        await createStripeIntent(
          amountCents: 1500,
          orderId: 'abc123',
          description: 'Faheng Rice FH-1001',
        );
        fail('should have thrown');
      } on ApiError catch (error) {
        expect(error.statusCode, 502);
        expect(error.message, contains('Your card was declined.'));
      }
    });
  });

  group('cleanTestCard', () {
    test('no body means the configured default card', () {
      expect(cleanTestCard(null), isNull);
      expect(cleanTestCard(<String, dynamic>{}), isNull);
    });

    test('accepts a documented Stripe decline card', () {
      expect(
        cleanTestCard(<String, dynamic>{
          'testPaymentMethod': 'pm_card_visa_chargeDeclined',
        }),
        'pm_card_visa_chargeDeclined',
      );
    });

    test('refuses a card Stripe does not document', () {
      final error = _error(
        () => cleanTestCard(<String, dynamic>{
          'testPaymentMethod': 'pm_card_free_money',
        }),
      );
      expect(error?.statusCode, 400);
      expect(error?.message, contains('pm_card_visa'));
    });

    test('refuses a value that is not text', () {
      final error = _error(
        () => cleanTestCard(<String, dynamic>{'testPaymentMethod': 42}),
      );
      expect(error?.statusCode, 400);
    });
  });

  group('cleanConfirmInput', () {
    test('requires a payment intent id', () {
      final missing = _error(() => cleanConfirmInput(<String, dynamic>{}));
      expect(missing?.statusCode, 400);
      expect(missing?.message, 'paymentIntentId is required');
      expect(
        cleanConfirmInput(<String, dynamic>{'paymentIntentId': ' pi_1 '}),
        'pi_1',
      );
      expect(_error(() => cleanConfirmInput('nope'))?.statusCode, 400);
    });
  });
}
