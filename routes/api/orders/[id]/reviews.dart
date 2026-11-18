import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/order_service.dart';
import 'package:faheng_api/services/review_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

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
