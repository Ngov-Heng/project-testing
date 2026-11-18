// Cart rules: stock checks, kg rounding, one line per product.
// Collections: carts, products

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/pricing_service.dart';
import 'package:faheng_api/services/settings_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

const minQuantityKg = 0.01;
double roundKg(num kg) => (kg * 100).round() / 100;

String kgLabel(num kg) {
  final rounded = roundKg(kg);
  if (rounded == rounded.roundToDouble()) return rounded.round().toString();
  return rounded.toString();
}

double checkedQuantityKg(num quantityKg) {
  final kg = roundKg(quantityKg);
  if (kg < minQuantityKg) {
    throw const ApiError(400, 'quantityKg must be greater than 0');
  }
  return kg;
}

Future<List<Map<String, dynamic>>> _readItems(
  Db db,
  ObjectId userId,
) async {
  final cart = await db.collection('carts').findOne(where.id(userId));
  final saved = (cart?['items'] as List?) ?? const [];
  return [
    for (final item in saved) Map<String, dynamic>.from(item as Map),
  ];
}

Future<void> _saveItems(
  Db db,
  ObjectId userId,
  List<Map<String, dynamic>> items,
) async {
  await db
      .collection('carts')
      .updateOne(where.id(userId), modify.set('items', items), upsert: true);
}

Future<Map<String, dynamic>> _activeProduct(
  Db db,
  ObjectId productId,
) async {
  final product = await db
      .collection('products')
      .findOne(where.id(productId).eq('isActive', true));
  if (product == null) throw const ApiError(404, 'Product not found');
  return product;
}

// We only check stock here. Nothing is held for the buyer until an
// order actually exists.
void ensureStockKg(num? stockKg, String? name, double wantedKg) {
  if (stockKg is! num) return;
  if (wantedKg > stockKg) {
    throw ApiError(
      409,
      'Not enough stock of $name: ${kgLabel(stockKg)} kg left',
    );
  }
}

int _indexOf(List<Map<String, dynamic>> items, ObjectId productId) {
  return items.indexWhere(
    (item) => (item['productId'] as ObjectId).oid == productId.oid,
  );
}

List<Map<String, dynamic>> _copy(List<Map<String, dynamic>> items) => [
  for (final item in items) Map<String, dynamic>.from(item),
];

List<Map<String, dynamic>> withQuantityAdded(
  List<Map<String, dynamic>> items,
  ObjectId productId,
  double kg,
) {
  final next = _copy(items);
  final index = _indexOf(next, productId);
  if (index == -1) {
    // Adding the same product again raises the kg on the line it is
    // already on instead of making a second one.
    next.add(<String, dynamic>{'productId': productId, 'quantityKg': kg});
    return next;
  }
  final current = (next[index]['quantityKg'] as num).toDouble();
  next[index]['quantityKg'] = roundKg(current + kg);
  return next;
}

List<Map<String, dynamic>> withQuantitySet(
  List<Map<String, dynamic>> items,
  ObjectId productId,
  double kg,
) {
  final next = _copy(items);
  final index = _indexOf(next, productId);
  if (index == -1) throw const ApiError(404, 'Item is not in the cart');
  next[index]['quantityKg'] = kg;
  return next;
}

List<Map<String, dynamic>> withoutLine(
  List<Map<String, dynamic>> items,
  ObjectId productId,
) {
  final next = _copy(items)
    ..removeWhere(
      (item) => (item['productId'] as ObjectId).oid == productId.oid,
    );
  if (next.length == items.length) {
    throw const ApiError(404, 'Item is not in the cart');
  }
  return next;
}

Future<Map<String, dynamic>> buildCartView(Db db, ObjectId userId) async {
  final saved = await _readItems(db, userId);
  final ids = [for (final item in saved) item['productId'] as ObjectId];
  final products = ids.isEmpty
      ? <Map<String, dynamic>>[]
      : await db
            .collection('products')
            .find(where.oneFrom('_id', ids).eq('isActive', true))
            .toList();
  final byId = {for (final p in products) (p['_id'] as ObjectId).oid: p};
  final items = <Map<String, dynamic>>[];
  final lineCents = <int>[];
  var totalKg = 0.0;

  for (final item in saved) {
    final productId = item['productId'] as ObjectId;
    final product = byId[productId.oid];
    if (product == null) continue;
    final kg = (item['quantityKg'] as num).toDouble();
    final unitCents = toCents(product['pricePerKg'] as num);
    final line = (unitCents * kg).round();
    lineCents.add(line);
    totalKg += kg;
    items.add({
      'productId': productId.oid,
      'name': product['name'],
      'image': product['image'],
      'pricePerKg': toDollars(unitCents),
      'quantityKg': kg,
      'lineTotal': toDollars(line),
    });
  }

  final rules = await loadPricingRules(db);
  final totals = calculateTotals(
    lineCents: lineCents,
    totalKg: totalKg,
    thresholdKg: rules.thresholdKg,
    discountPercent: rules.percent,
    flatFeeCents: rules.deliveryFeeCents,
    discountEnabled: rules.discountEnabled,
  );
  return {
    'items': items,
    'totalKg': totalKg,
    'subtotal': toDollars(totals.subtotalCents),
    'discount': toDollars(totals.discountCents),
    'deliveryFee': toDollars(totals.deliveryFeeCents),
    'total': toDollars(totals.totalCents),
    'grandTotal': toDollars(totals.grandTotalCents),
  };
}

Future<Map<String, dynamic>> addCartItem(
  Db db,
  ObjectId userId,
  ObjectId productId,
  num quantityKg,
) async {
  final kg = checkedQuantityKg(quantityKg);
  final product = await _activeProduct(db, productId);
  final items = await _readItems(db, userId);
  final next = withQuantityAdded(items, productId, kg);
  final index = _indexOf(next, productId);
  ensureStockKg(
    product['stock'] as num?,
    product['name'] as String?,
    (next[index]['quantityKg'] as num).toDouble(),
  );
  await _saveItems(db, userId, next);
  return buildCartView(db, userId);
}

Future<Map<String, dynamic>> changeCartItemKg(
  Db db,
  ObjectId userId,
  ObjectId productId,
  num quantityKg,
) async {
  final kg = checkedQuantityKg(quantityKg);
  final items = await _readItems(db, userId);
  final next = withQuantitySet(items, productId, kg);
  final product = await _activeProduct(db, productId);
  ensureStockKg(product['stock'] as num?, product['name'] as String?, kg);
  await _saveItems(db, userId, next);
  return buildCartView(db, userId);
}

Future<Map<String, dynamic>> removeCartItem(
  Db db,
  ObjectId userId,
  ObjectId productId,
) async {
  final items = await _readItems(db, userId);
  final next = withoutLine(items, productId);
  await _saveItems(db, userId, next);
  return buildCartView(db, userId);
}

Future<Map<String, dynamic>> clearCart(Db db, ObjectId userId) async {
  await _saveItems(db, userId, <Map<String, dynamic>>[]);
  return buildCartView(db, userId);
}
