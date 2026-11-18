/*
Manages the buyer order lifecycle: placing an order from the cart, deducting
stock safely (with automatic rollback if any item runs out or saving fails),
generating sequential FH-1001 order numbers, listing/viewing orders,
cancelling early orders, and reordering past items into the cart.
*/

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/cart_service.dart';
import 'package:faheng_api/services/notification_service.dart';
import 'package:faheng_api/services/pricing_service.dart';
import 'package:faheng_api/services/settings_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Every status an order can have, in the order they normally happen.
const orderStatuses = [
  'pending',
  'processing',
  'on_the_way',
  'delivered',
  'cancelled',
];

/// The statuses the buyer still sees under the "Active" tab (screen 07).
const activeOrderStatuses = ['pending', 'processing', 'on_the_way'];

/// The statuses shown under the "Past orders" tab.
const pastOrderStatuses = ['delivered', 'cancelled'];

/// Which status may follow which. The admin chunk reuses this map, so the
/// rules live in one place and a buyer can never invent a jump.
const orderTransitions = <String, List<String>>{
  'pending': ['processing', 'cancelled'],
  'processing': ['on_the_way', 'cancelled'],
  'on_the_way': ['delivered'],
  'delivered': <String>[],
  'cancelled': <String>[],
};

/// The two delivery windows screen 22 offers.
const deliveryWindows = ['morning', 'afternoon'];

/// The four reasons screen 28 offers, stored as codes so reports can group
/// them. The app shows the label; the database keeps the code.
const cancelReasons = <String, String>{
  'ordered_by_mistake': 'I ordered by mistake',
  'change_address_or_date': 'I want to change the address or date',
  'found_better_price': 'I found a better price',
  'other': 'Other reason',
};

/// The payment methods the settings document can switch on.
const paymentMethods = ['paypal', 'cod'];

/// Human names for the payment methods, used in error messages.
const paymentMethodLabels = {
  'paypal': 'PayPal',
  'cod': 'Cash on delivery',
};

/// The first order number: FH-1001.
const firstOrderNumber = 1001;

/// True when an order may move from [from] to [to].
bool canChangeStatus(String from, String to) =>
    orderTransitions[from]?.contains(to) ?? false;

/// Only the two early statuses may be cancelled, by the buyer or the admin.
bool canCancel(String status) => status == 'pending' || status == 'processing';

/// Turns a counter value into the order number the screens show (1001 ->
/// FH-1001).
String orderNumberFor(int value) => 'FH-$value';

/// The date in Asia/Phnom Penh (UTC+7) right now, as a UTC midnight.
/// Comparing UTC midnights is what makes "tomorrow" unambiguous.
DateTime phnomPenhToday({DateTime? nowUtc}) {
  final now = (nowUtc ?? DateTime.now().toUtc()).toUtc();
  final local = now.add(const Duration(hours: 7));
  return DateTime.utc(local.year, local.month, local.day);
}

final _datePattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// Checks the delivery date from screen 22: a real date, from tomorrow up to
/// seven days ahead in Phnom Penh time. Returns it as "YYYY-MM-DD" so the
/// stored value can never shift by a timezone.
String cleanDeliveryDate(Object? value, {DateTime? nowUtc}) {
  if (value is! String || value.trim().isEmpty) {
    throw const ApiError(400, 'deliveryDate is required as YYYY-MM-DD');
  }
  final text = value.trim();
  final match = _datePattern.firstMatch(text);
  if (match == null) {
    throw const ApiError(400, 'deliveryDate must look like 2026-11-10');
  }
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day) {
    throw const ApiError(400, 'deliveryDate is not a real date');
  }
  final days = date.difference(phnomPenhToday(nowUtc: nowUtc)).inDays;
  if (days < 1 || days > 7) {
    throw const ApiError(
      400,
      'deliveryDate must be between tomorrow and 7 days from today',
    );
  }
  return text;
}

/// Checks the delivery window from screen 22 and stores it lowercase.
String cleanDeliveryWindow(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const ApiError(400, 'deliveryWindow is required');
  }
  final window = value.trim().toLowerCase();
  if (!deliveryWindows.contains(window)) {
    throw const ApiError(400, 'deliveryWindow must be morning or afternoon');
  }
  return window;
}

/// Checks the payment method from screen 20 and stores it lowercase.
String cleanPaymentMethod(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const ApiError(400, 'paymentMethod is required');
  }
  final method = value.trim().toLowerCase();
  if (!paymentMethods.contains(method)) {
    throw const ApiError(400, 'paymentMethod must be paypal or cod');
  }
  return method;
}

/// A checked cancellation reason: the radio choice from screen 28 plus the
/// optional free text under it.
class CancelReason {
  /// Creates a checked reason.
  const CancelReason({
    required this.code,
    required this.note,
    required this.text,
  });

  /// One of the keys of [cancelReasons], or null for the older free-text form.
  final String? code;

  /// The optional "Tell us more" text.
  final String? note;

  /// What the screens show: the label, with the note after it when there is
  /// one.
  final String text;
}

/// Checks the body sent to the cancel route.
///
/// Screen 28 sends `reasonCode` (one of the four radios) and an optional
/// `note`. A plain `reason` string is still accepted, so nothing that already
/// works breaks.
CancelReason cleanCancelReason(Object? body) {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }

  final rawNote = body['note'];
  if (rawNote != null && rawNote is! String) {
    throw const ApiError(400, 'note must be a string');
  }
  final trimmedNote = rawNote is String ? rawNote.trim() : '';
  if (trimmedNote.length > 200) {
    throw const ApiError(400, 'note must be 200 characters or less');
  }
  final note = trimmedNote.isEmpty ? null : trimmedNote;

  final rawCode = body['reasonCode'];
  if (rawCode != null) {
    if (rawCode is! String) {
      throw const ApiError(400, 'reasonCode must be a string');
    }
    final code = rawCode.trim().toLowerCase();
    final label = cancelReasons[code];
    if (label == null) {
      throw ApiError(
        400,
        'reasonCode must be one of ${cancelReasons.keys.join(', ')}',
      );
    }
    return CancelReason(
      code: code,
      note: note,
      text: note == null ? label : '$label - $note',
    );
  }

  final rawReason = body['reason'];
  if (rawReason is! String || rawReason.trim().isEmpty) {
    throw const ApiError(400, 'reasonCode is required');
  }
  final reason = rawReason.trim();
  if (reason.length > 200) {
    throw const ApiError(400, 'reason must be 200 characters or less');
  }
  return CancelReason(code: null, note: note, text: reason);
}

/// Reads a required hex id from the body (for example an addressId).
ObjectId cleanObjectId(Object? value, String field) {
  if (value is! String || value.trim().isEmpty) {
    throw ApiError(400, '$field is required');
  }
  try {
    return ObjectId.fromHexString(value.trim());
  } catch (_) {
    throw ApiError(400, '$field is not valid');
  }
}

/// Turns the id in the URL into an ObjectId. A malformed id answers 404, the
/// same as an id that belongs to another buyer.
ObjectId parseOrderId(String raw) {
  try {
    return ObjectId.fromHexString(raw.trim());
  } catch (_) {
    throw const ApiError(404, 'Order not found');
  }
}

/// Formats a kg number for messages and responses without a trailing ".0".
String kgText(num? value) {
  if (value == null) return '0';
  final number = value.toDouble();
  return number == number.roundToDouble()
      ? number.round().toString()
      : number.toString();
}

/// What the app receives for one order. Money is in dollars here; the stored
/// document keeps cents.
Map<String, dynamic> orderView(Map<String, dynamic> order) {
  final createdAt = order['createdAt'];
  final items = ((order['items'] as List?) ?? const <dynamic>[])
      .map((raw) => Map<String, dynamic>.from(raw as Map))
      .toList();
  final history = ((order['statusHistory'] as List?) ?? const <dynamic>[])
      .map((raw) => Map<String, dynamic>.from(raw as Map))
      .toList();
  return <String, dynamic>{
    'id': (order['_id'] as ObjectId).oid,
    'orderNumber': order['orderNumber'],
    'orderNumberValue': order['orderNumberValue'],
    'items': [
      for (final item in items)
        {
          'productId': (item['productId'] as ObjectId).oid,
          'name': item['name'],
          'image': item['image'],
          'quantityKg': item['quantityKg'],
          'pricePerKg': toDollars((item['pricePerKgCents'] as num).round()),
          'lineTotal': toDollars((item['lineTotalCents'] as num).round()),
        },
    ],
    'totalWeightKg': order['totalWeightKg'],
    'subtotal': toDollars((order['subtotalCents'] as num).round()),
    'discount': toDollars((order['discountCents'] as num).round()),
    'deliveryFee': toDollars((order['deliveryFeeCents'] as num).round()),
    'total': toDollars((order['totalCents'] as num).round()),
    'grandTotal': toDollars((order['grandTotalCents'] as num).round()),
    'address': order['address'],
    'deliveryDate': order['deliveryDate'],
    'deliveryWindow': order['deliveryWindow'],
    'paymentMethod': order['paymentMethod'],
    'paymentStatus': order['paymentStatus'],
    'status': order['status'],
    'statusHistory': [
      for (final entry in history)
        {'status': entry['status'], 'at': entry['at']},
    ],
    // Chunk 11: a PayPal order carries the moment the money arrived.
    if (order['paidAt'] is DateTime)
      'paidAt': (order['paidAt'] as DateTime).toIso8601String(),
    if (order['cancelReason'] != null) 'cancelReason': order['cancelReason'],
    if (order['cancelReasonCode'] != null)
      'cancelReasonCode': order['cancelReasonCode'],
    if (order['cancelNote'] != null) 'cancelNote': order['cancelNote'],
    if (createdAt is DateTime) 'createdAt': createdAt.toIso8601String(),
  };
}

/// One stock change we already made, kept so it can be undone exactly.
class _StockChange {
  const _StockChange(this.productId, this.delta);

  final ObjectId productId;

  /// Negative when stock was taken away.
  final num delta;
}

/// A whole kg becomes an int so the stored stock stays an int.
num _delta(double kg, {required bool restore}) {
  final whole = kg == kg.roundToDouble();
  final value = whole ? kg.round() : kg;
  return restore ? value : -value;
}

/// Takes [kg] off one product's stock, atomically.
///
/// The filter `stock >= kg` is the trick: MongoDB applies a single document
/// update atomically even on a standalone node, so two buyers cannot both buy
/// the last bag. If nothing matched, the stock ran out between the check and
/// the update, and the caller rolls back what it already took.
Future<void> _deductStock(
  Db db,
  Map<String, dynamic> product,
  double kg,
  List<_StockChange> done,
) async {
  final stock = product['stock'];
  if (stock is! num) return; // A product with no stock field is unlimited.
  final delta = _delta(kg, restore: false);
  final result = await db
      .collection('products')
      .updateOne(
        where.eq('_id', product['_id']).gte('stock', kg),
        modify.inc('stock', delta),
      );
  if (result.nMatched == 0) {
    final fresh = await db
        .collection('products')
        .findOne(where.id(product['_id'] as ObjectId));
    throw ApiError(
      409,
      'Not enough stock of ${product['name']}: '
      '${kgText(fresh?['stock'] as num?)} kg left',
    );
  }
  done.add(_StockChange(product['_id'] as ObjectId, delta));
}

/// Undoes every deduction in [done], newest first.
Future<void> _restoreStock(Db db, List<_StockChange> done) async {
  for (final change in done.reversed) {
    await db
        .collection('products')
        .updateOne(
          where.id(change.productId),
          modify.inc('stock', _delta(-change.delta.toDouble(), restore: true)),
        );
  }
}

/// Puts one product's kg back (used when an order is cancelled).
Future<void> giveBackStock(
  Db db,
  ObjectId productId,
  double kg,
) async {
  final product = await db.collection('products').findOne(where.id(productId));
  if (product == null || product['stock'] is! num) return;
  await db
      .collection('products')
      .updateOne(
        where.id(productId),
        modify.inc('stock', _delta(kg, restore: true)),
      );
}

/// Puts the kg of a cancelled order back on the shelf, item by item. The
/// buyer's cancel and the admin's cancel both call this, so stock can never
/// come back twice with two different rules.
Future<void> restoreStockForOrder(
  Db db,
  Map<String, dynamic> order,
) async {
  final lines = ((order['items'] as List?) ?? const <dynamic>[])
      .map((raw) => Map<String, dynamic>.from(raw as Map))
      .toList();
  for (final line in lines) {
    await giveBackStock(
      db,
      line['productId'] as ObjectId,
      (line['quantityKg'] as num).toDouble(),
    );
  }
}

/// Copies the address onto the order, so editing the address later never
/// rewrites an old delivery.
Map<String, dynamic> addressCopy(Map<String, dynamic> address) {
  return <String, dynamic>{
    'label': address['label'],
    'receiverName': address['receiverName'],
    'phone': address['phone'],
    'street': address['street'],
    'town': address['town'],
    'lat': address['lat'],
    'lng': address['lng'],
  };
}

/// Reserves the next order number from the "counters" collection.
///
/// `findAndModify` with `$inc` is a single atomic document operation, so two
/// orders created at the same moment always get different numbers.
Future<int> nextOrderNumber(Db db) async {
  final counters = db.collection('counters');
  final existing = await counters.findOne(where.eq('_id', 'orders'));
  if (existing == null) {
    try {
      await counters.insertOne(<String, dynamic>{
        '_id': 'orders',
        'seq': firstOrderNumber - 1,
      });
    } catch (_) {
      // Another request created it in the same instant; that is fine.
    }
  }
  final result = await counters.modernFindAndModify(
    query: where.eq('_id', 'orders'),
    update: modify.inc('seq', 1),
    returnNew: true,
  );
  final seq = result.value?['seq'];
  if (seq is! num) {
    throw const ApiError(500, 'Could not create an order number');
  }
  return seq.round();
}

/// The items saved in the buyer's cart.
Future<List<Map<String, dynamic>>> _cartItems(
  Db db,
  ObjectId userId,
) async {
  final cart = await db.collection('carts').findOne(where.id(userId));
  final saved = (cart?['items'] as List?) ?? const [];
  return [
    for (final item in saved) Map<String, dynamic>.from(item as Map),
  ];
}

/// Creates the order for the buyer's cart (screens 20, 22 and 23).
///
/// Order of work, chosen so nothing is half done:
/// validate -> take the stock -> save the order -> empty the cart.
/// If the stock runs out the deductions are undone; if saving the order fails
/// the deductions are undone and the cart is left alone.
Future<Map<String, dynamic>> createOrder(
  Db db,
  ObjectId userId,
  Object? body,
) async {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }

  final addressId = cleanObjectId(body['addressId'], 'addressId');
  final deliveryDate = cleanDeliveryDate(body['deliveryDate']);
  final deliveryWindow = cleanDeliveryWindow(body['deliveryWindow']);
  final paymentMethod = cleanPaymentMethod(body['paymentMethod']);

  final settings = await loadSettings(db);
  final methods = settings['paymentMethods'] as Map<String, dynamic>;
  if (methods[paymentMethod] != true) {
    throw ApiError(
      400,
      '${paymentMethodLabels[paymentMethod]} is not available right now',
    );
  }

  final address = await db
      .collection('addresses')
      .findOne(where.eq('_id', addressId).eq('userId', userId));
  if (address == null) throw const ApiError(404, 'Address not found');

  final saved = await _cartItems(db, userId);
  if (saved.isEmpty) throw const ApiError(400, 'Your cart is empty');

  final ids = [for (final item in saved) item['productId'] as ObjectId];
  final products = await db
      .collection('products')
      .find(where.oneFrom('_id', ids).eq('isActive', true))
      .toList();
  final byId = {for (final p in products) (p['_id'] as ObjectId).oid: p};

  final lines = <Map<String, dynamic>>[];
  final lineCents = <int>[];
  var totalKg = 0.0;

  for (final item in saved) {
    final productId = item['productId'] as ObjectId;
    final product = byId[productId.oid];
    if (product == null) {
      throw const ApiError(
        409,
        'An item in your cart is no longer available',
      );
    }
    final kg = (item['quantityKg'] as num).toDouble();
    final unitCents = toCents(product['pricePerKg'] as num);
    final line = (unitCents * kg).round();

    lineCents.add(line);
    totalKg += kg;
    lines.add(<String, dynamic>{
      'productId': productId,
      'name': product['name'],
      'image': product['image'],
      'quantityKg': kg,
      'pricePerKgCents': unitCents,
      'lineTotalCents': line,
    });
  }

  final rules = rulesFrom(settings);
  final totals = calculateTotals(
    lineCents: lineCents,
    totalKg: totalKg,
    thresholdKg: rules.thresholdKg,
    discountPercent: rules.percent,
    flatFeeCents: rules.deliveryFeeCents,
    discountEnabled: rules.discountEnabled,
  );

  final deducted = <_StockChange>[];
  try {
    for (final item in saved) {
      final product = byId[(item['productId'] as ObjectId).oid]!;
      await _deductStock(
        db,
        product,
        (item['quantityKg'] as num).toDouble(),
        deducted,
      );
    }
  } on ApiError {
    await _restoreStock(db, deducted);
    rethrow;
  }

  final seq = await nextOrderNumber(db);
  final now = DateTime.now().toUtc();
  final doc = <String, dynamic>{
    '_id': ObjectId(),
    'userId': userId,
    'orderNumber': orderNumberFor(seq),
    'orderNumberValue': seq,
    'items': lines,
    'totalWeightKg': totalKg,
    'subtotalCents': totals.subtotalCents,
    'discountCents': totals.discountCents,
    'deliveryFeeCents': totals.deliveryFeeCents,
    'totalCents': totals.totalCents,
    'grandTotalCents': totals.grandTotalCents,
    'address': addressCopy(address),
    'deliveryDate': deliveryDate,
    'deliveryWindow': deliveryWindow,
    'paymentMethod': paymentMethod,
    'paymentStatus': 'unpaid',
    'status': 'pending',
    'statusHistory': [
      {'status': 'pending', 'at': now.toIso8601String()},
    ],
    'createdAt': now,
  };

  try {
    await db.collection('orders').insertOne(doc);
  } catch (_) {
    await _restoreStock(db, deducted);
    rethrow;
  }

  await db
      .collection('carts')
      .updateOne(
        where.id(userId),
        modify.set('items', <Map<String, dynamic>>[]),
        upsert: true,
      );

  // Screen 31 gets "Order FH-1042 placed" the moment the order exists. The
  // helper swallows its own errors, so a notification can never fail an order.
  await notifyOrder(db, doc);

  return orderView(doc);
}

/// Screen 07: a page of this buyer's orders, newest first.
///
/// `query["tab"]` is "active" or "past"; empty means every order.
Future<Map<String, dynamic>> listOrders(
  Db db,
  ObjectId userId,
  Map<String, String> query,
) async {
  final tab = (query['tab'] ?? '').trim().toLowerCase();
  final page = int.tryParse(query['page'] ?? '') ?? 1;
  final limit = int.tryParse(query['limit'] ?? '') ?? 20;
  if (page < 1 || limit < 1 || limit > 100) {
    throw const ApiError(400, 'page must be 1 or more and limit 1 to 100');
  }

  final statuses = tab == 'active'
      ? activeOrderStatuses
      : tab == 'past'
      ? pastOrderStatuses
      : null;
  if (tab.isNotEmpty && statuses == null) {
    throw const ApiError(400, 'tab must be active or past');
  }

  final countSelector = where.eq('userId', userId);
  if (statuses != null) countSelector.oneFrom('status', statuses);
  final total = await db.collection('orders').count(countSelector);

  final selector = where.eq('userId', userId);
  if (statuses != null) selector.oneFrom('status', statuses);
  selector
      .sortBy('createdAt', descending: true)
      .skip((page - 1) * limit)
      .limit(limit);
  final docs = await db.collection('orders').find(selector).toList();

  return <String, dynamic>{
    'items': [for (final doc in docs) orderView(doc)],
    'total': total,
    'page': page,
    'limit': limit,
  };
}

/// One order, but only if it belongs to this buyer.
Future<Map<String, dynamic>> findOrder(
  Db db,
  ObjectId userId,
  ObjectId orderId,
) async {
  final order = await db
      .collection('orders')
      .findOne(where.eq('_id', orderId).eq('userId', userId));
  if (order == null) throw const ApiError(404, 'Order not found');
  return orderView(order);
}

/// Screen 28: the buyer cancels an order and the kg go back on the shelf.
Future<Map<String, dynamic>> cancelOrder(
  Db db,
  ObjectId userId,
  ObjectId orderId,
  Object? body,
) async {
  final orders = db.collection('orders');
  final order = await orders.findOne(
    where.eq('_id', orderId).eq('userId', userId),
  );
  if (order == null) throw const ApiError(404, 'Order not found');

  final reason = cleanCancelReason(body);

  final status = order['status'] as String? ?? '';
  if (!canCancel(status)) {
    throw const ApiError(
      409,
      'Only pending or processing orders can be cancelled',
    );
  }

  await restoreStockForOrder(db, order);

  final now = DateTime.now().toUtc();
  final history = [
    ...((order['statusHistory'] as List?) ?? const <dynamic>[]),
    {'status': 'cancelled', 'at': now.toIso8601String()},
  ];
  final update = modify
      .set('status', 'cancelled')
      .set('cancelReason', reason.text)
      .set('statusHistory', history)
      .set('updatedAt', now);
  if (reason.code == null) {
    update.unset('cancelReasonCode');
  } else {
    update.set('cancelReasonCode', reason.code);
  }
  if (reason.note == null) {
    update.unset('cancelNote');
  } else {
    update.set('cancelNote', reason.note);
  }
  await orders.updateOne(where.id(orderId), update);

  final updated = await orders.findOne(where.id(orderId));
  if (updated == null) throw const ApiError(404, 'Order not found');
  return orderView(updated);
}

/// One call from screen 07: copies the items of one of the buyer's own orders
/// back into the cart at today's prices.
///
/// Anything unavailable is skipped and reported, so the app can tell the buyer
/// exactly what did not come back. The rules are the cart's own rules, because
/// it reuses addCartItem instead of copying its checks.
Future<Map<String, dynamic>> reorderOrder(
  Db db,
  ObjectId userId,
  ObjectId orderId,
) async {
  final order = await db
      .collection('orders')
      .findOne(where.eq('_id', orderId).eq('userId', userId));
  if (order == null) throw const ApiError(404, 'Order not found');

  final skipped = <Map<String, dynamic>>[];
  for (final item in (order['items'] as List?) ?? const []) {
    final line = Map<String, dynamic>.from(item as Map);
    final productId = line['productId'] as ObjectId;
    try {
      await addCartItem(db, userId, productId, line['quantityKg'] as num);
    } on ApiError catch (error) {
      skipped.add(<String, dynamic>{
        'productId': productId.oid,
        'name': line['name'],
        'reason': error.message,
      });
    }
  }

  return <String, dynamic>{
    'cart': await buildCartView(db, userId),
    'skipped': skipped,
  };
}
