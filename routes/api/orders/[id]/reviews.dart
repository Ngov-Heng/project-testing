// WHY: Screen 30 (rate your order) has two halves: read which products of the
// order still need a rating (GET), and send one review (POST, 201).
// Where it sits in the flow: authGuard has already run for everything under
// /api/orders, so the buyer id comes from the token and another buyer's order
// answers 404 inside the service.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/order_service.dart';
import 'package:faheng_api/services/review_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Reads the review state of this order, or writes one review.
Future<Response> onRequest(RequestContext context, String id) async {
  final user = context.read<Map<String, dynamic>>();
  final db = context.read<Db>();
  final orderId = parseOrderId(id);

  if (context.request.method == HttpMethod.get) {
    final state = await orderReviewState(db, user['_id'] as ObjectId, orderId);
    return Response.json(body: state);
  }

  if (context.request.method == HttpMethod.post) {
    final raw = await context.request.body();
    final Object? body;
    try {
      body = jsonDecode(raw);
    } catch (_) {
      return jsonError(400, 'Body must be valid JSON');
    }
    final created = await placeReview(db, user, orderId, body);
    return Response.json(statusCode: 201, body: created);
  }

  return Response(statusCode: 405);
}
