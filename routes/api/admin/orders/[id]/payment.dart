// WHY: Screen 39 mentions marking a cash order as paid. The buyer's screen 23
// says "Cash on delivery - Unpaid" until the money is in hand, and this is
// where the owner says it is.
// Where it sits in the flow: PATCH {"paymentStatus": "paid"}. PayPal orders are
// refused here on purpose: their state comes from the provider in chunk 11.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/admin_order_service.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:mongo_dart/mongo_dart.dart';
  
/// Marks a cash order paid or unpaid.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.patch) {
    return Response(statusCode: 405);
  }
  final raw = await context.request.body();
  final Object? body;
  try {
    body = jsonDecode(raw);
  } catch (_) {
    return jsonError(400, 'Body must be valid JSON');
  }
  return Response.json(
    body: await setAdminPaymentStatus(context.read<Db>(), id, body),
  );
}
