import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/settings_service.dart';
import 'package:test/test.dart';

Map<String, dynamic> validBody() => <String, dynamic>{
  'bulkDiscount': <String, dynamic>{
    'enabled': true,
    'thresholdKg': 150,
    'percent': 10,
  },
  'deliveryFee': 3,
  'shop': <String, dynamic>{
    'name': 'FAHENG Rice Shop',
    'phone': '+855 77 889 900',
    'address': 'Street 33, Kampot town, Kampot',
  },
  'paymentMethods': <String, dynamic>{
    'stripe': true,
    'cod': true,
  },
};

ApiError? errorFrom(Map<String, dynamic> body) {
  try {
    cleanSettingsUpdate(body);
    return null;
  } on ApiError catch (error) {
    return error;
  }
}

void main() {
  group('cleanSettingsUpdate', () {
    test('accepts the form from screen 48 and 50', () {
      final clean = cleanSettingsUpdate(validBody());
      expect(clean['deliveryFeeCents'], 300);
      expect(
        (clean['shop'] as Map<String, dynamic>)['name'],
        'FAHENG Rice Shop',
      );
    });

    test('keeps the delivery fee in cents', () {
      final body = validBody()..['deliveryFee'] = 2.5;
      expect(cleanSettingsUpdate(body)['deliveryFeeCents'], 250);
    });

    test('trims spaces around text', () {
      final body = validBody()
        ..['shop'] = <String, dynamic>{
          'name': '  FAHENG  ',
          'phone': ' 090 111 ',
          'address': ' Street 33 ',
        };
      final shop = cleanSettingsUpdate(body)['shop'] as Map<String, dynamic>;
      expect(shop['name'], 'FAHENG');
      expect(shop['phone'], '090 111');
      expect(shop['address'], 'Street 33');
    });

    test('refuses when every payment method is off', () {
      final body = validBody()
        ..['paymentMethods'] = <String, dynamic>{
          'stripe': false,
          'cod': false,
        };
      expect(errorFrom(body)?.statusCode, 400);
      expect(
        errorFrom(body)?.message,
        'at least one payment method must stay enabled',
      );
    });

    test('refuses a shop with no name', () {
      final body = validBody()
        ..['shop'] = <String, dynamic>{
          'name': '   ',
          'phone': '',
          'address': '',
        };
      expect(errorFrom(body)?.message, 'shop.name is required');
    });

    test('refuses a discount above 100 percent', () {
      final body = validBody();
      (body['bulkDiscount'] as Map<String, dynamic>)['percent'] = 150;
      expect(
        errorFrom(body)?.message,
        'bulkDiscount.percent must be between 0 and 100',
      );
    });

    test('refuses a threshold of zero', () {
      final body = validBody();
      (body['bulkDiscount'] as Map<String, dynamic>)['thresholdKg'] = 0;
      expect(
        errorFrom(body)?.message,
        'bulkDiscount.thresholdKg must be a number greater than 0',
      );
    });

    test('refuses a negative delivery fee', () {
      final body = validBody()..['deliveryFee'] = -1;
      expect(
        errorFrom(body)?.message,
        'deliveryFee must be a number, 0 or more',
      );
    });

    test('refuses a missing paymentMethods section', () {
      final body = validBody()..remove('paymentMethods');
      expect(errorFrom(body)?.message, 'paymentMethods is required');
    });
  });

  group('rulesFrom', () {
    test('reads the rules the cart needs', () {
      final rules = rulesFrom(defaultSettings());
      expect(rules.discountEnabled, isTrue);
      expect(rules.thresholdKg, 150);
      expect(rules.percent, 10);
      expect(rules.deliveryFeeCents, 300);
    });

    test('fills in a document that is missing fields', () {
      final rules = rulesFrom(<String, dynamic>{'_id': settingsId});
      expect(rules.thresholdKg, 150);
      expect(rules.deliveryFeeCents, 300);
      expect(rules.discountEnabled, isTrue);
    });
  });

  group('publicSettingsView', () {
    test('shows the shop and the payment methods in dollars', () {
      final view = publicSettingsView(defaultSettings());
      expect(view['deliveryFee'], 3.0);
      expect(view['bulkDiscount'], <String, dynamic>{
        'enabled': true,
        'thresholdKg': 150,
        'percent': 10,
      });
      expect((view['shop'] as Map<String, dynamic>)['name'], defaultShopName);
    });

    test('never exposes the raw cents field', () {
      final view = publicSettingsView(defaultSettings());
      expect(view.containsKey('deliveryFeeCents'), isFalse);
    });
  });

  group('adminSettingsView', () {
    test('returns the same shape the PUT accepts', () {
      final view = adminSettingsView(defaultSettings());
      expect(view['deliveryFee'], 3.0);
      expect(view.keys.toSet(), validBody().keys.toSet());
    });

    test('a saved body reads back unchanged', () {
      final saved = cleanSettingsUpdate(validBody());
      expect(adminSettingsView(saved), validBody());
    });
  });
}
