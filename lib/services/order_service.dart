// Buyer orders: what can be ordered, and the status ladder an order moves
// through.
// Collections: orders, carts, addresses, products, counters

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/cart_service.dart';
import 'package:faheng_api/services/notification_service.dart';
import 'package:faheng_api/services/pricing_service.dart';
import 'package:faheng_api/services/settings_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

const orderStatuses = [
  'pending',
  'processing',
  'on_the_way',
  'delivered',
  'cancelled',
];
const activeOrderStatuses = ['pending', 'processing', 'on_the_way'];
const pastOrderStatuses = ['delivered', 'cancelled'];

const orderTransitions = <String, List<String>>{
  'pending': ['processing', 'cancelled'],
  'processing': ['on_the_way', 'cancelled'],
  'on_the_way': ['delivered'],
  'delivered': <String>[],
  'cancelled': <String>[],
};
const deliveryWindows = ['morning', 'afternoon'];

const cancelReasons = <String, String>{
  'ordered_by_mistake': 'I ordered by mistake',
  'change_address_or_date': 'I want to change the address or date',
  'found_better_price': 'I found a better price',
  'other': 'Other reason',
};
const paymentMethods = ['paypal', 'cod'];

const paymentMethodLabels = {
  'paypal': 'PayPal',
  'cod': 'Cash on delivery',
};
const firstOrderNumber = 1001;

bool canChangeStatus(String from, String to) =>
    orderTransitions[from]?.contains(to) ?? false;
bool canCancel(String status) => status == 'pending' || status == 'processing';
String orderNumberFor(int value) => 'FH-$value';

DateTime phnomPenhToday({DateTime? nowUtc}) {
  final now = (nowUtc ?? DateTime.now().toUtc()).toUtc();
  final local = now.add(const Duration(hours: 7));
  return DateTime.utc(local.year, local.month, local.day);
}

final _datePattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

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

class CancelReason {
  const CancelReason({
    required this.code,
    required this.note,
    required this.text,
  });
  final String? code;
  final String? note;
  final String text;
}

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

ObjectId parseOrderId(String raw) {
  try {
    return ObjectId.fromHexString(raw.trim());
  } catch (_) {
    throw const ApiError(404, 'Order not found');
  }
}

String kgText(num? value) {
  if (value == null) return '0';
  final number = value.toDouble();
  return number == number.roundToDouble()
      ? number.round().toString()
      : number.toString();
}

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

    if (order['paidAt'] is DateTime)
      'paidAt': (order['paidAt'] as DateTime).toIso8601String(),
    if (order['cancelReason'] != null) 'cancelReason': order['cancelReason'],
    if (order['cancelReasonCode'] != null)
      'cancelReasonCode': order['cancelReasonCode'],
    if (order['cancelNote'] != null) 'cancelNote': order['cancelNote'],
    if (createdAt is DateTime) 'createdAt': createdAt.toIso8601String(),
  };
}

class _StockChange {
  const _StockChange(this.productId, this.delta);
  final ObjectId productId;
  final num delta;
}

num _delta(double kg, {required bool restore}) {
  final whole = kg == kg.roundToDouble();
  final value = whole ? kg.round() : kg;
  return restore ? value : -value;
}

Future<void> _deductStock(
  Db db,
  Map<String, dynamic> product,
  double kg,
  List<_StockChange> done,
) async {
  final stock = product['stock'];
  if (stock is! num) return;
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
  await notifyOrder(db, doc);
  return orderView(doc);
}

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
