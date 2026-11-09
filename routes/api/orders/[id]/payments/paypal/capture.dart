// WHY: Screen 23b (order placed, PayPal paid) and screen 24 (payment did not go
// through) are the two answers of this one call.
// Where it sits in the flow: authGuard has already run; the body is
// {"paypalOrderId": "SBX-...", "approved": true}.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/paypal_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Takes the money, or cancels the order and frees the stock.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }

  final raw = await context.request.body();
  final Object? body;
  try {
    body = jsonDecode(raw);
  } catch (_) {
    return jsonError(400, 'Body must be valid JSON');
  }

  final user = context.read<Map<String, dynamic>>();
  final result = await capturePaypalPayment(
    context.read<Db>(),
    user['_id'] as ObjectId,
    id,
    body,
  );
  return Response.json(body: result);
}
