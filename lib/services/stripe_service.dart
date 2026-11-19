// Card payments through Stripe. The provider calls are real; the money is test
// money until STRIPE_SECRET_KEY points at a live key.
// Collections: payments, orders

import 'dart:convert';
import 'dart:io';

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/notification_service.dart';
import 'package:faheng_api/services/order_service.dart';
import 'package:http/http.dart' as http;
import 'package:mongo_dart/mongo_dart.dart';

const stripeProvider = 'stripe';
const stripeApiBase = 'https://api.stripe.com/v1';

String get stripeSecretKey => Platform.environment['STRIPE_SECRET_KEY'] ?? '';

String get stripeCurrency =>
    (Platform.environment['STRIPE_CURRENCY'] ?? 'usd').toLowerCase();

String get stripeTestPaymentMethod =>
    Platform.environment['STRIPE_TEST_PAYMENT_METHOD'] ?? 'pm_card_visa';

http.Client stripeHttpClient = http.Client();

int stripeAmountCents(Map<String, dynamic> order) =>
    ((order['grandTotalCents'] as num?) ?? 0).round();

void checkStripeMethod(Map<String, dynamic> order) {
  if (order['paymentMethod'] != stripeProvider) {
    throw const ApiError(400, 'This order is not paid by card');
  }
}

void checkStripeOrder(Map<String, dynamic> order) {
  checkStripeMethod(order);
  if (order['status'] == 'cancelled') {
    throw const ApiError(409, 'A cancelled order cannot be paid');
  }
  if (order['paymentStatus'] == 'paid') {
    throw const ApiError(409, 'This order is already paid');
  }
}

// The one rule this file exists for: the provider's answer decides, never the
// client's word.
void verifyStripeIntent(
  Map<String, dynamic> intent, {
  required int amountCents,
  required String orderId,
}) {
  final status = intent['status'] as String? ?? 'unknown';
  if (status != 'succeeded') {
    throw ApiError(402, 'Stripe reports "$status", so the order is not paid');
  }
  final received =
      ((intent['amount_received'] as num?) ??
              (intent['amount'] as num?) ??
              0)
          .round();
  if (received != amountCents) {
    throw ApiError(
      409,
      'Stripe received $received cents, the order says $amountCents',
    );
  }
  final paidIn = (intent['currency'] as String? ?? '').toLowerCase();
  if (paidIn != stripeCurrency) {
    throw ApiError(409, 'Stripe charged in $paidIn, not $stripeCurrency');
  }
  final metadata = intent['metadata'];
  final stampedOrder = metadata is Map ? metadata['orderId'] : null;
  if (stampedOrder != orderId) {
    throw const ApiError(409, 'This payment belongs to another order');
  }
}

Map<String, dynamic> stripePaymentView(Map<String, dynamic> doc) {
  final createdAt = doc['createdAt'];
  final capturedAt = doc['capturedAt'];
  final failedAt = doc['failedAt'];
  return <String, dynamic>{
    'id': (doc['_id'] as ObjectId).oid,
    'provider': stripeProvider,
    'paymentIntentId': doc['paymentIntentId'],
    'amount': ((doc['amountCents'] as num?) ?? 0) / 100,
    'status': doc['status'],
    if (doc['failedAt'] != null) 'failureReason': doc['failureReason'],
    if (createdAt is DateTime) 'createdAt': createdAt.toIso8601String(),
    if (capturedAt is DateTime) 'capturedAt': capturedAt.toIso8601String(),
    if (failedAt is DateTime) 'failedAt': failedAt.toIso8601String(),
  };
}

Map<String, String> get _formHeaders => <String, String>{
  'Authorization': 'Bearer $stripeSecretKey',
  'Content-Type': 'application/x-www-form-urlencoded',
};

Map<String, dynamic> _decode(http.Response response, String action) {
  Object? body;
  try {
    body = jsonDecode(response.body);
  } catch (_) {
    throw const ApiError(502, 'Stripe sent a reply we could not read');
  }
  if (body is! Map<String, dynamic>) {
    throw const ApiError(502, 'Stripe sent a reply we could not read');
  }
  if (response.statusCode >= 400) {
    final error = body['error'];
    final detail = error is Map ? error['message'] : null;
    throw ApiError(
      502,
      'Stripe rejected the $action: ${detail ?? 'no detail'}',
    );
  }
  return body;
}

Future<Map<String, dynamic>> createStripeIntent({
  required int amountCents,
  required String orderId,
  required String description,
}) async {
  final response = await stripeHttpClient.post(
    Uri.parse('$stripeApiBase/payment_intents'),
    headers: _formHeaders,
    body: <String, String>{
      'amount': '$amountCents',
      'currency': stripeCurrency,
      'payment_method': stripeTestPaymentMethod,
      'payment_method_types[]': 'card',
      'confirm': 'true',
      'description': description,
      'metadata[orderId]': orderId,
    },
  );
  return _decode(response, 'payment');
}

Future<Map<String, dynamic>> retrieveStripeIntent(String intentId) async {
  final response = await stripeHttpClient.get(
    Uri.parse('$stripeApiBase/payment_intents/$intentId'),
    headers: <String, String>{'Authorization': 'Bearer $stripeSecretKey'},
  );
  return _decode(response, 'lookup');
}

String cleanConfirmInput(Object? body) {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }
  final raw = body['paymentIntentId'];
  if (raw is! String || raw.trim().isEmpty) {
    throw const ApiError(400, 'paymentIntentId is required');
  }
  return raw.trim();
}

Future<Map<String, dynamic>> _findOrder(
  Db db,
  ObjectId userId,
  String rawOrderId,
) async {
  final ObjectId orderId;
  try {
    orderId = ObjectId.fromHexString(rawOrderId.trim());
  } catch (_) {
    throw const ApiError(404, 'Order not found');
  }
  final order = await db
      .collection('orders')
      .findOne(where.id(orderId).eq('userId', userId));
  if (order == null) throw const ApiError(404, 'Order not found');
  return order;
}

Future<Map<String, dynamic>> _openPayment(
  Db db,
  Map<String, dynamic> order,
) async {
  final payments = db.collection('payments');
  final existing = await payments.findOne(
    where
        .eq('orderId', order['_id'] as ObjectId)
        .eq('provider', stripeProvider)
        .eq('status', 'created'),
  );
  if (existing != null) return existing;

  final intent = await createStripeIntent(
    amountCents: stripeAmountCents(order),
    orderId: (order['_id'] as ObjectId).oid,
    description: 'Faheng Rice ${order['orderNumber']}',
  );
  final now = DateTime.now().toUtc();
  final doc = <String, dynamic>{
    '_id': ObjectId(),
    'orderId': order['_id'] as ObjectId,
    'orderNumber': order['orderNumber'],
    'userId': order['userId'] as ObjectId,
    'provider': stripeProvider,
    'paymentIntentId': intent['id'],
    'amountCents': stripeAmountCents(order),
    'status': 'created',
    'providerStatus': intent['status'],
    'createdAt': now,
  };
  await payments.insertOne(doc);
  return doc;
}

Future<Map<String, dynamic>> startStripePayment(
  Db db,
  ObjectId userId,
  String rawOrderId,
) async {
  if (stripeSecretKey.isEmpty) {
    throw const ApiError(503, 'Stripe is not configured on this server');
  }
  final order = await _findOrder(db, userId, rawOrderId);
  checkStripeOrder(order);
  final payment = await _openPayment(db, order);
  return <String, dynamic>{
    'payment': stripePaymentView(payment),
    'order': <String, dynamic>{
      'id': (order['_id'] as ObjectId).oid,
      'orderNumber': order['orderNumber'],
      'paymentMethod': order['paymentMethod'],
      'paymentStatus': order['paymentStatus'],
      'amount': stripeAmountCents(order) / 100,
      'currency': stripeCurrency,
    },
  };
}

Future<Map<String, dynamic>> stripePaymentStatus(
  Db db,
  ObjectId userId,
  String rawOrderId,
) async {
  final order = await _findOrder(db, userId, rawOrderId);
  final payment = await db.collection('payments').findOne(
    where.eq('orderId', order['_id'] as ObjectId).sortBy(
          'createdAt',
          descending: true,
        ),
  );
  return <String, dynamic>{
    'order': <String, dynamic>{
      'id': (order['_id'] as ObjectId).oid,
      'orderNumber': order['orderNumber'],
      'paymentMethod': order['paymentMethod'],
      'paymentStatus': order['paymentStatus'],
      'status': order['status'],
      'amount': stripeAmountCents(order) / 100,
      'currency': stripeCurrency,
    },
    'payment': payment == null ? null : stripePaymentView(payment),
  };
}

Future<Map<String, dynamic>> captureStripePayment(
  Db db,
  ObjectId userId,
  String rawOrderId,
  Object? body,
) async {
  final intentId = cleanConfirmInput(body);
  final orders = db.collection('orders');
  final payments = db.collection('payments');
  final order = await _findOrder(db, userId, rawOrderId);

  final payment = await payments.findOne(
    where
        .eq('orderId', order['_id'] as ObjectId)
        .eq('paymentIntentId', intentId),
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

  checkStripeOrder(order);
  final now = DateTime.now().toUtc();

  final Map<String, dynamic> intent;
  try {
    intent = await retrieveStripeIntent(intentId);
    verifyStripeIntent(
      intent,
      amountCents: ((payment['amountCents'] as num?) ?? 0).round(),
      orderId: (order['_id'] as ObjectId).oid,
    );
  } on ApiError catch (error) {
    await payments.updateOne(
      where.id(payment['_id'] as ObjectId),
      modify
          .set('status', 'failed')
          .set('failedAt', now)
          .set('failureReason', error.message),
    );
    await _cancelForFailedPayment(db, order, now);
    rethrow;
  }

  await payments.updateOne(
    where.id(payment['_id'] as ObjectId),
    modify
        .set('status', 'captured')
        .set('providerStatus', intent['status'])
        .set('capturedAt', now),
  );
  final captured =
      await payments.findOne(where.id(payment['_id'] as ObjectId));
  await orders.updateOne(
    where.id(order['_id'] as ObjectId),
    modify
        .set('paymentStatus', 'paid')
        .set('paidAt', now)
        .set('payment', <String, dynamic>{
          'provider': stripeProvider,
          'paymentIntentId': intentId,
          'amountCents': ((payment['amountCents'] as num?) ?? 0).round(),
          'currency': stripeCurrency,
          'capturedAt': now.toIso8601String(),
        })
        .set('updatedAt', now),
  );

  await addNotification(
    db,
    userId: userId,
    type: 'payment_received',
    title: 'Payment received for ${order['orderNumber']}',
    body: '${moneyLabel(payment['amountCents'])} paid by card.',
    orderId: order['_id'] as ObjectId,
  );
  final updated = await orders.findOne(where.id(order['_id'] as ObjectId));
  return <String, dynamic>{
    'paid': true,
    'message': 'Payment received',
    'payment': captured == null
        ? stripePaymentView(payment)
        : stripePaymentView(captured),
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

  final history = <dynamic>[
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
