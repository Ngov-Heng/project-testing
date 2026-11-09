// WHY: Chunk 11 is the PayPal path: screen 21a sends the buyer to PayPal,
// screen 21b waits for the answer, screen 24 is a payment that did not go
// through, and screen 23b is the order placed with "PayPal · Paid".
// Where it sits in the flow: the order is placed first, exactly like a cash
// order, with paymentMethod "paypal" and paymentStatus "unpaid". Then
// startPaypalPayment opens a payment, capturePaypalPayment finishes it, and
// paypalPaymentStatus answers the waiting screen.
//
// WHAT IS REAL AND WHAT IS STANDING IN FOR PAYPAL: the order, the amount, the
// state machine, the stock, the 409s and the "nothing was charged" message are
// all real. The two calls that would go to PayPal's servers - create an order
// and capture it - are made here, locally, against a `payments` collection,
// because this project has no PayPal sandbox account and must never be given
// one's secret. When real credentials exist, only `_sandboxCreate` and
// `_sandboxCapture` change: everything around them already speaks PayPal's
// vocabulary (order id, approval, capture) and the routes do not move.

import 'dart:math';

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/notification_service.dart';
import 'package:faheng_api/services/order_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// The states a payment attempt can be in, in the order they happen.
const paymentStates = <String>['created', 'captured', 'failed'];

/// The provider name stored on every payment.
const paypalProvider = 'paypal';

/// The amount to charge for an order: the grand total the buyer saw on 21a,
/// which already includes the delivery fee. In cents, like every other amount.
int paypalAmountCents(Map<String, dynamic> order) =>
    ((order['grandTotalCents'] as num?) ?? 0).round();

/// The order a payment id belongs to, from a URL.
ObjectId parsePaymentOrderId(String raw) {
  try {
    return ObjectId.fromHexString(raw.trim());
  } catch (_) {
    throw const ApiError(404, 'Order not found');
  }
}

/// The narrowest check: is this even a PayPal order? Pure.
///
/// The capture path runs this first and the rest of [checkPaypalOrder] last, so
/// that a double tap on "pay" is answered with the state of *the payment*
/// ("already captured"), which is more useful than the state of the order.
void checkPaypalMethod(Map<String, dynamic> order) {
  if (order['paymentMethod'] != paypalProvider) {
    throw const ApiError(400, 'This order is paid on delivery');
  }
}

/// Refuses a PayPal payment on an order that cannot take one. Pure, so all the
/// rules can be tested without a database.
///
/// The order of the checks is the order of the messages: what the order is
/// first, then whether it can still be paid.
void checkPaypalOrder(Map<String, dynamic> order) {
  checkPaypalMethod(order);
  if (order['status'] == 'cancelled') {
    throw const ApiError(409, 'A cancelled order cannot be paid');
  }
  if (order['paymentStatus'] == 'paid') {
    throw const ApiError(409, 'This order is already paid');
  }
}

/// A payment as the app receives it. No raw document, no `_id`.
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

/// The id PayPal would have given the payment. A sandbox id is prefixed so
/// nobody mistakes one for a real PayPal order.
String newSandboxPaypalOrderId([Random? random]) {
  final rng = random ?? Random.secure();
  final part = List<String>.generate(
    12,
    (_) => rng.nextInt(36).toRadixString(36),
  ).join();
  return 'SBX-${part.toUpperCase()}';
}

/// Where screen 21a sends the buyer. In a real integration this is the
/// `approve` link PayPal returns; here it points back at this API, and the app
/// finishes the flow with the capture call.
String sandboxApprovalUrl(String paypalOrderId) =>
    '/api/payments/paypal/approve?token=$paypalOrderId';

/// Loads one of this buyer's orders, or answers 404 - never 403, because a
/// stranger must not learn that the order exists.
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

/// Standing in for PayPal's "create order" call.
///
/// Re-using an open attempt is deliberate: tapping "Pay with PayPal" twice
/// must not open two payments for one order.
Future<Map<String, dynamic>> _sandboxCreate(
  Db db,
  Map<String, dynamic> order,
) async {
  final payments = db.collection('payments');
  final existing = await payments.findOne(
    where
        .eq('orderId', order['_id'] as ObjectId)
        .eq('status', 'created'),
  );
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

/// Screen 21a -> 21b: opens the payment and returns the approval link.
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

/// Screen 21b: the app asks "has PayPal answered yet?" while it waits.
Future<Map<String, dynamic>> paypalPaymentStatus(
  Db db,
  ObjectId userId,
  String rawOrderId,
) async {
  final order = await _findOrder(db, userId, rawOrderId);
  final payment = await db
      .collection('payments')
      .findOne(
        where.eq('orderId', order['_id'] as ObjectId).sortBy('createdAt',
            descending: true),
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

/// Standing in for PayPal's "capture order" call. Returns true when the money
/// is taken; in the sandbox the answer is whatever the app asked for, which is
/// how screen 24 can be reached without a real declined card.
bool _sandboxCapture({required bool approved}) => approved;

/// Reads `paypalOrderId` and `approved` off the capture body.
///
/// `approved` defaults to true: the app only reaches this line after the buyer
/// pressed the button in the sandbox approval window. Sending `false` is how
/// the failed-payment screen is produced.
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

/// Screen 23b and screen 24: the money is taken, or the order is taken apart.
///
/// A failed payment **cancels the order** and puts the kg back on the shelf.
/// Screen 24 promises exactly that - "Your order has not been placed" - and an
/// unpaid order nobody can pay for would hold stock hostage otherwise. "Try
/// again" therefore means placing the order again, which the app does from the
/// cart it still has on screen.
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
  // Only now the order itself: method, cancelled, already paid.
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

  // The buyer has just paid, so the notification list on screen 31 says so
  // with its own type and icon.
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

/// Turns a failed payment into the state screen 24 describes: nothing was
/// placed, nothing was charged, and the rice is back on the shelf.
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
}
