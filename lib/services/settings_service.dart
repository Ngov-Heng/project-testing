// Global shop settings: discount, delivery fee, which payment methods are
// on.
// Collections: settings

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/pricing_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

const settingsId = 'shop';
const defaultThresholdKg = 150;
const defaultDiscountPercent = 10;
const defaultDeliveryFeeCents = 300;
const defaultShopName = 'FAHENG Rice Shop';

class PricingRules {
  const PricingRules({
    required this.discountEnabled,
    required this.thresholdKg,
    required this.percent,
    required this.deliveryFeeCents,
  });
  final bool discountEnabled;
  final int thresholdKg;
  final int percent;
  final int deliveryFeeCents;
}

Map<String, dynamic> defaultSettings() => <String, dynamic>{
  '_id': settingsId,
  'bulkDiscount': <String, dynamic>{
    'enabled': true,
    'thresholdKg': defaultThresholdKg,
    'percent': defaultDiscountPercent,
  },
  'deliveryFeeCents': defaultDeliveryFeeCents,
  'shop': <String, dynamic>{
    'name': defaultShopName,
    'phone': '',
    'address': '',
  },
  'paymentMethods': <String, dynamic>{'paypal': true, 'cod': true},
};

Map<String, dynamic> withDefaults(Map<String, dynamic> stored) {
  final defaults = defaultSettings();
  final bulk =
      (stored['bulkDiscount'] as Map?)?.cast<String, dynamic>() ??
      <String, dynamic>{};
  final shop =
      (stored['shop'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
  final methods =
      (stored['paymentMethods'] as Map?)?.cast<String, dynamic>() ??
      <String, dynamic>{};
  final defaultBulk = defaults['bulkDiscount'] as Map<String, dynamic>;
  final defaultShop = defaults['shop'] as Map<String, dynamic>;
  final defaultMethods = defaults['paymentMethods'] as Map<String, dynamic>;

  return <String, dynamic>{
    '_id': settingsId,
    'bulkDiscount': <String, dynamic>{
      'enabled': bulk['enabled'] ?? defaultBulk['enabled'],
      'thresholdKg': bulk['thresholdKg'] ?? defaultBulk['thresholdKg'],
      'percent': bulk['percent'] ?? defaultBulk['percent'],
    },
    'deliveryFeeCents':
        stored['deliveryFeeCents'] ?? defaults['deliveryFeeCents'],
    'shop': <String, dynamic>{
      'name': shop['name'] ?? defaultShop['name'],
      'phone': shop['phone'] ?? defaultShop['phone'],
      'address': shop['address'] ?? defaultShop['address'],
    },
    'paymentMethods': <String, dynamic>{
      'paypal': methods['paypal'] ?? defaultMethods['paypal'],
      'cod': methods['cod'] ?? defaultMethods['cod'],
    },
  };
}

PricingRules rulesFrom(Map<String, dynamic> settings) {
  final full = withDefaults(settings);
  final bulk = full['bulkDiscount'] as Map<String, dynamic>;
  return PricingRules(
    discountEnabled: bulk['enabled'] == true,
    thresholdKg: (bulk['thresholdKg'] as num).round(),
    percent: (bulk['percent'] as num).round(),
    deliveryFeeCents: (full['deliveryFeeCents'] as num).round(),
  );
}

Future<Map<String, dynamic>> loadSettings(Db db) async {
  final collection = db.collection('settings');
  final stored = await collection.findOne(where.eq('_id', settingsId));
  if (stored == null) {
    final fresh = defaultSettings();
    await collection.insertOne(fresh);
    return fresh;
  }
  return withDefaults(stored);
}

Future<PricingRules> loadPricingRules(Db db) async {
  return rulesFrom(await loadSettings(db));
}

Map<String, dynamic> cleanSettingsUpdate(Object? body) {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }

  final bulk = body['bulkDiscount'];
  if (bulk is! Map) throw const ApiError(400, 'bulkDiscount is required');
  final enabled = bulk['enabled'];
  if (enabled is! bool) {
    throw const ApiError(400, 'bulkDiscount.enabled must be true or false');
  }
  final thresholdKg = bulk['thresholdKg'];
  if (thresholdKg is! num || thresholdKg <= 0) {
    throw const ApiError(
      400,
      'bulkDiscount.thresholdKg must be a number greater than 0',
    );
  }
  final percent = bulk['percent'];
  if (percent is! num || percent < 0 || percent > 100) {
    throw const ApiError(400, 'bulkDiscount.percent must be between 0 and 100');
  }

  final deliveryFee = body['deliveryFee'];
  if (deliveryFee is! num || deliveryFee < 0) {
    throw const ApiError(400, 'deliveryFee must be a number, 0 or more');
  }

  final shop = body['shop'];
  if (shop is! Map) throw const ApiError(400, 'shop is required');
  final name = shop['name'];
  if (name is! String || name.trim().isEmpty) {
    throw const ApiError(400, 'shop.name is required');
  }
  final phone = shop['phone'] ?? '';
  final address = shop['address'] ?? '';
  if (phone is! String) {
    throw const ApiError(400, 'shop.phone must be a string');
  }
  if (address is! String) {
    throw const ApiError(400, 'shop.address must be a string');
  }

  final methods = body['paymentMethods'];
  if (methods is! Map) throw const ApiError(400, 'paymentMethods is required');
  final paypal = methods['paypal'];
  final cod = methods['cod'];
  if (paypal is! bool) {
    throw const ApiError(400, 'paymentMethods.paypal must be true or false');
  }
  if (cod is! bool) {
    throw const ApiError(400, 'paymentMethods.cod must be true or false');
  }
  if (!paypal && !cod) {
    throw const ApiError(400, 'at least one payment method must stay enabled');
  }

  return <String, dynamic>{
    '_id': settingsId,
    'bulkDiscount': <String, dynamic>{
      'enabled': enabled,
      'thresholdKg': thresholdKg,
      'percent': percent,
    },
    'deliveryFeeCents': toCents(deliveryFee),
    'shop': <String, dynamic>{
      'name': name.trim(),
      'phone': phone.trim(),
      'address': address.trim(),
    },
    'paymentMethods': <String, dynamic>{'paypal': paypal, 'cod': cod},
  };
}

Future<Map<String, dynamic>> saveSettings(Db db, Object? body) async {
  final clean = cleanSettingsUpdate(body);
  await db
      .collection('settings')
      .replaceOne(where.eq('_id', settingsId), clean, upsert: true);
  return clean;
}

Map<String, dynamic> publicSettingsView(Map<String, dynamic> settings) {
  final full = withDefaults(settings);
  final rules = rulesFrom(full);
  final shop = full['shop'] as Map<String, dynamic>;
  final methods = full['paymentMethods'] as Map<String, dynamic>;
  return <String, dynamic>{
    'shop': <String, dynamic>{
      'name': shop['name'],
      'phone': shop['phone'],
      'address': shop['address'],
    },
    'paymentMethods': <String, dynamic>{
      'paypal': methods['paypal'],
      'cod': methods['cod'],
    },
    'deliveryFee': toDollars(rules.deliveryFeeCents),
    'bulkDiscount': <String, dynamic>{
      'enabled': rules.discountEnabled,
      'thresholdKg': rules.thresholdKg,
      'percent': rules.percent,
    },
  };
}

Map<String, dynamic> adminSettingsView(Map<String, dynamic> settings) {
  final full = withDefaults(settings);
  final shop = full['shop'] as Map<String, dynamic>;
  final methods = full['paymentMethods'] as Map<String, dynamic>;
  return <String, dynamic>{
    'bulkDiscount': full['bulkDiscount'],
    'deliveryFee': toDollars((full['deliveryFeeCents'] as num).round()),
    'shop': <String, dynamic>{
      'name': shop['name'],
      'phone': shop['phone'],
      'address': shop['address'],
    },
    'paymentMethods': <String, dynamic>{
      'paypal': methods['paypal'],
      'cod': methods['cod'],
    },
  };
}
