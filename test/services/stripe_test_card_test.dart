// The test-card knob: only documented Stripe cards, never with a live key.
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/stripe_service.dart';
import 'package:test/test.dart';

ApiError? errorFrom(Map<String, dynamic>? body) {
  try {
    cleanTestCard(body);
    return null;
  } on ApiError catch (error) {
    return error;
  }
}

void main() {
  test('no body means the card from .env is used', () {
    expect(cleanTestCard(null), isNull);
    expect(cleanTestCard(<String, dynamic>{}), isNull);
  });

  test('accepts the documented decline card', () {
    expect(
      cleanTestCard(<String, dynamic>{
        'testPaymentMethod': 'pm_card_visa_chargeDeclined',
      }),
      'pm_card_visa_chargeDeclined',
    );
  });

  test('accepts the plain success card', () {
    expect(
      cleanTestCard(<String, dynamic>{'testPaymentMethod': 'pm_card_visa'}),
      'pm_card_visa',
    );
  });

  test('refuses a card Stripe does not document', () {
    final error = errorFrom(<String, dynamic>{
      'testPaymentMethod': 'pm_card_free_money',
    });
    expect(error?.statusCode, 400);
    expect(error?.message, contains('pm_card_visa'));
  });

  test('refuses a value that is not text', () {
    expect(
      errorFrom(<String, dynamic>{'testPaymentMethod': 42})?.statusCode,
      400,
    );
  });

  test('test cards are allowed unless a live key is in use', () {
    expect(stripeAllowsTestCards, isTrue);
  });
}
