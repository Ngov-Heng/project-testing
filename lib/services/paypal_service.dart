// Payment state machine. The two provider calls are stubs; everything around
// them is real.
// Collections: payments, orders

import 'dart:math';

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/notification_service.dart';
import 'package:faheng_api/services/order_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

const paymentStates = <String>['created', 'captured', 'failed'];
const paypalProvider = 'paypal';

int paypalAmountCents(Map<String, dynamic> order) =>
    ((order['grandTotalCents'] as num?) ?? 0).round();

ObjectId parsePaymentOrderId(String raw) {
  try {
    return ObjectId.fromHexString(raw.trim());
  } catch (_) {
    throw const ApiError(404, 'Order not found');
  }
}

void checkPaypalMethod(Map<String, dynamic> order) {
  if (order['paymentMethod'] != paypalProvider) {
    throw const ApiError(400, 'This order is paid on delivery');
  }
}

void checkPaypalOrder(Map<String, dynamic> order) {
  checkPaypalMethod(order);
  if (order['status'] == 'cancelled') {
    throw const ApiError(409, 'A cancelled order cannot be paid');
  }
  if (order['paymentStatus'] == 'paid') {
    throw const ApiError(409, 'This order is already paid');
  }
}

Map<String, dynamic> paymentView(Map<String, dynamic> doc) {
  final createdAt = doc['createdAt'];
  final capturedAt = doc['capturedAt'];
  final failedAt = doc['failedAt'];
  return <String, dynamic>{
    'id': (doc['_id'] as ObjectId).oid,
    'provider': doc['provider'] ?? paypalProvider,
    'paypalOrderId': doc['paypalOrderId'],
    'amount': ((doc['amountCents'] as num?) ?? 0) / 100,
    'status': doc['status'],
    if (doc['approvalUrl'] != null) 'approvalUrl': doc['approvalUrl'],
    if (createdAt is DateTime) 'createdAt': createdAt.toIso8601String(),
    if (capturedAt is DateTime) 'capturedAt': capturedAt.toIso8601String(),
    if (failedAt is DateTime) 'failedAt': failedAt.toIso8601String(),
  };
}

String newSandboxPaypalOrderId([Random? random]) {
  final rng = random ?? Random.secure();
  final part = List<String>.generate(
    12,
    (_) => rng.nextInt(36).toRadixString(36),
  ).join();
  return 'SBX-${part.toUpperCase()}';
}

String sandboxApprovalUrl(String paypalOrderId) =>
    '/api/payments/paypal/approve?token=$paypalOrderId';

Future<Map<String, dynamic>> _findOrder(
  Db db,
  ObjectId userId,
  String rawOrderId,
) async {
  final order = await db
      .collection('orders')
      .findOne(where.id(parsePaymentOrderId(rawOrderId)).eq('userId', userId));
  if (order == null) throw const ApiError(404, 'Order not found');
  return order;
}

Future<Map<String, dynamic>> _sandboxCreate(
  Db db,
  Map<String, dynamic> order,
) async {
  final payments = db.collection('payments');
  final existing = await payments.findOne(
    where.eq('orderId', order['_id'] as ObjectId).eq('status', 'created'),
  );
  // Pay pressed twice reuses the open payment instead of opening a
  // second one. We do not trust the client to press only once.
  if (existing != null) return existing;
  final now = DateTime.now().toUtc();
  final paypalOrderId = newSandboxPaypalOrderId();
  final doc = <String, dynamic>{
    '_id': ObjectId(),
    'orderId': order['_id'] as ObjectId,
    'orderNumber': order['orderNumber'],
    'userId': order['userId'] as ObjectId,
    'provider': paypalProvider,
    'paypalOrderId': paypalOrderId,
    'amountCents': paypalAmountCents(order),
    'status': 'created',
    'approvalUrl': sandboxApprovalUrl(paypalOrderId),
    'createdAt': now,
  };
  await payments.insertOne(doc);
  return doc;
}

Future<Map<String, dynamic>> startPaypalPayment(
  Db db,
  ObjectId userId,
  String rawOrderId,
) async {
  final order = await _findOrder(db, userId, rawOrderId);
  checkPaypalOrder(order);
  final payment = await _sandboxCreate(db, order);
  return <String, dynamic>{
    'payment': paymentView(payment),
    'order': <String, dynamic>{
      'id': (order['_id'] as ObjectId).oid,
      'orderNumber': order['orderNumber'],
      'paymentMethod': order['paymentMethod'],
      'paymentStatus': order['paymentStatus'],
      'amount': paypalAmountCents(order) / 100,
    },
  };
}

Future<Map<String, dynamic>> paypalPaymentStatus(
  Db db,
  ObjectId userId,
  String rawOrderId,
) async {
  final order = await _findOrder(db, userId, rawOrderId);
  final payment = await db
      .collection('payments')
      .findOne(
        where
            .eq('orderId', order['_id'] as ObjectId)
            .sortBy('createdAt', descending: true),
      );
  return <String, dynamic>{
    'order': <String, dynamic>{
      'id': (order['_id'] as ObjectId).oid,
      'orderNumber': order['orderNumber'],
      'paymentMethod': order['paymentMethod'],
      'paymentStatus': order['paymentStatus'],
      'status': order['status'],
      'amount': paypalAmountCents(order) / 100,
    },
    'payment': payment == null ? null : paymentView(payment),
  };
}

// Stub. A live version asks the provider right here, and only a
// COMPLETED answer is allowed to mark the order paid.
bool _sandboxCapture({required bool approved}) => approved;

({String paypalOrderId, bool approved}) cleanCaptureInput(Object? body) {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }
  final rawId = body['paypalOrderId'];
  if (rawId is! String || rawId.trim().isEmpty) {
    throw const ApiError(400, 'paypalOrderId is required');
  }
  final rawApproved = body['approved'];
  if (rawApproved != null && rawApproved is! bool) {
    throw const ApiError(400, 'approved must be true or false');
  }
  return (paypalOrderId: rawId.trim(), approved: rawApproved != false);
}

Future<Map<String, dynamic>> capturePaypalPayment(
  Db db,
  ObjectId userId,
  String rawOrderId,
  Object? body,
) async {
  final input = cleanCaptureInput(body);
  final orders = db.collection('orders');
  final payments = db.collection('payments');
  final order = await _findOrder(db, userId, rawOrderId);
  checkPaypalMethod(order);

  final payment = await payments.findOne(
    where
        .eq('orderId', order['_id'] as ObjectId)
        .eq('paypalOrderId', input.paypalOrderId),
  );
  if (payment == null) throw const ApiError(404, 'Payment not found');
  final state = payment['status'] as String? ?? 'created';
  if (state != 'created') {
    throw ApiError(
      409,
      state == 'captured'
          ? 'This payment was already captured'
          : 'This payment already failed',
    );
  }

  checkPaypalOrder(order);
  final now = DateTime.now().toUtc();
  final approved = _sandboxCapture(approved: input.approved);

  if (!approved) {
    await payments.updateOne(
      where.id(payment['_id'] as ObjectId),
      modify
          .set('status', 'failed')
          .set('failedAt', now)
          .set('failureReason', 'declined_by_provider'),
    );
    await _cancelForFailedPayment(db, order, now);
    final updated = await orders.findOne(where.id(order['_id'] as ObjectId));
    return <String, dynamic>{
      'paid': false,
      'message': "Payment didn't go through",
      'payment': paymentView(
        await payments.findOne(where.id(payment['_id'] as ObjectId)) ?? payment,
      ),
      'order': updated == null ? null : orderView(updated),
    };
  }

  await payments.updateOne(
    where.id(payment['_id'] as ObjectId),
    modify.set('status', 'captured').set('capturedAt', now),
  );
  final captured = await payments.findOne(where.id(payment['_id'] as ObjectId));
  await orders.updateOne(
    where.id(order['_id'] as ObjectId),
    modify
        .set('paymentStatus', 'paid')
        .set('paidAt', now)
        .set('payment', <String, dynamic>{
          'provider': paypalProvider,
          'paypalOrderId': input.paypalOrderId,
          'amountCents': ((payment['amountCents'] as num?) ?? 0).round(),
          'capturedAt': now.toIso8601String(),
        })
        .set('updatedAt', now),
  );

  await addNotification(
    db,
    userId: userId,
    type: 'payment_received',
    title: 'Payment received for ${order['orderNumber']}',
    body: '${moneyLabel(payment['amountCents'])} paid with PayPal.',
    orderId: order['_id'] as ObjectId,
  );
  final updated = await orders.findOne(where.id(order['_id'] as ObjectId));
  return <String, dynamic>{
    'paid': true,
    'message': 'Payment received',
    'payment': captured == null ? paymentView(payment) : paymentView(captured),
    'order': updated == null ? null : orderView(updated),
  };
}

Future<void> _cancelForFailedPayment(
  Db db,
  Map<String, dynamic> order,
  DateTime now,
) async {
  final orders = db.collection('orders');
  await restoreStockForOrder(db, order);

  final history = [
    ...((order['statusHistory'] as List?) ?? const <dynamic>[]),
    <String, dynamic>{'status': 'cancelled', 'at': now.toIso8601String()},
  ];
  await orders.updateOne(
    where.id(order['_id'] as ObjectId),
    modify
        .set('status', 'cancelled')
        .set('cancelReason', 'Payment failed')
        .set('cancelReasonCode', 'payment_failed')
        .set('statusHistory', history)
        .set('updatedAt', now),
  );
  await notifyOrder(db, <String, dynamic>{...order, 'status': 'cancelled'});
}
