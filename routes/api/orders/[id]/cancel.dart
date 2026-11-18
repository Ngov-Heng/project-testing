import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/order_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

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

  final user = context.read<Map<String, dynamic>>();
  final order = await cancelOrder(
    context.read<Db>(),
    user['_id'] as ObjectId,
    parseOrderId(id),
    body,
  );
  return Response.json(body: order);
}
