/*
Manages everything in a buyer's shopping cart: adding rice in kg, changing
quantities, removing items, clearing the cart, and calculating live totals.
Each buyer has one cart document in MongoDB (using their userId as _id),
and every action checks live product stock and admin pricing rules.
*/

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/pricing_service.dart';
import 'package:faheng_api/services/settings_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Smallest quantity we accept, in kg (0.01 kg = 10 grams).
const minQuantityKg = 0.01;

/// Keeps kg to at most 2 decimals so 2.500000001 does not reach the database.
double roundKg(num kg) => (kg * 100).round() / 100;

/// "10 kg" for a whole amount, "10.5 kg" otherwise - the same wording the
/// order messages use, so a buyer never sees "10.0 kg left".
String kgLabel(num kg) {
  final rounded = roundKg(kg);
  if (rounded == rounded.roundToDouble()) return rounded.round().toString();
  return rounded.toString();
}

/// The kg typed on screens 04 (quantity chips and custom amount) and 05 (the
/// plus and minus buttons), or a 400 when it is not a quantity. Pure, so the
/// rule can be tested without a database.
double checkedQuantityKg(num quantityKg) {
  final kg = roundKg(quantityKg);
  if (kg < minQuantityKg) {
    throw const ApiError(400, 'quantityKg must be greater than 0');
  }
  return kg;
}

/// Reads the saved items as a new list we are allowed to change in Dart.
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

/// Writes the whole item list back. `upsert: true` creates the cart document
/// on the first add, with _id taken from the filter (the user id).
Future<void> _saveItems(
  Db db,
  ObjectId userId,
  List<Map<String, dynamic>> items,
) async {
  await db
      .collection('carts')
      .updateOne(where.id(userId), modify.set('items', items), upsert: true);
}

/// Loads one product that buyers are allowed to see, or fails with 404.
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

/// Refuses a quantity bigger than what the shop has.
/// The stock field is called `stock` in the products collection. Products
/// created before it existed have no field, so there is nothing to check.
/// Pure, so both the rule and the wording can be tested.
void ensureStockKg(num? stockKg, String? name, double wantedKg) {
  if (stockKg is! num) return;
  if (wantedKg > stockKg) {
    throw ApiError(
      409,
      'Not enough stock of $name: ${kgLabel(stockKg)} kg left',
    );
  }
}

/// Finds the item for [productId], or -1 when the product is not in the cart.
int _indexOf(List<Map<String, dynamic>> items, ObjectId productId) {
  return items.indexWhere(
    (item) => (item['productId'] as ObjectId).oid == productId.oid,
  );
}

/// A copy we are allowed to change, so the caller's list is never mutated.
List<Map<String, dynamic>> _copy(List<Map<String, dynamic>> items) => [
  for (final item in items) Map<String, dynamic>.from(item),
];

/// The next item list with [kg] added to the line of [productId], creating the
/// line on the first add. One product is always one line, never two. Pure.
List<Map<String, dynamic>> withQuantityAdded(
  List<Map<String, dynamic>> items,
  ObjectId productId,
  double kg,
) {
  final next = _copy(items);
  final index = _indexOf(next, productId);
  if (index == -1) {
    next.add(<String, dynamic>{'productId': productId, 'quantityKg': kg});
    return next;
  }
  final current = (next[index]['quantityKg'] as num).toDouble();
  next[index]['quantityKg'] = roundKg(current + kg);
  return next;
}

/// The item list with one line set to [kg]. 404 when the product is not in the
/// cart, because the change endpoint may only change a line that exists. Pure.
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

/// The item list without the line of [productId]; 404 when it was never there,
/// so removing twice cannot be mistaken for success. Pure.
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

/// Builds the cart screen data for [userId] with live prices and totals.
///
/// Items whose product was deleted or deactivated are skipped, so a buyer
/// never sees a price for a product that is no longer for sale.
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

  // The discount and the delivery fee come from the settings document, so
  // the admin can change them on screen 48 without a new deployment.
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

/// Adds [quantityKg] of a product. Adding a product that is already in the
/// cart adds to the quantity instead of creating a second line.
///
/// Returns the updated cart, so the app can refresh with one response.
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

/// Sets the quantity of a product that is already in the cart.
///
/// Returns the updated cart.
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

/// Removes one product line from the cart.
///
/// Returns the updated cart.
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

/// Empties the cart (used by "clear cart" and after checkout).
///
/// Returns the empty cart.
Future<Map<String, dynamic>> clearCart(Db db, ObjectId userId) async {
  await _saveItems(db, userId, <Map<String, dynamic>>[]);
  return buildCartView(db, userId);
}
