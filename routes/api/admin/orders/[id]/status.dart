// WHY: Screen 39 has "Update status - Save changes" with the note "the
// customer sees this status in their order tracking". So this route is the one
// place where the owner writes what the buyer reads.
// Where it sits in the flow: PATCH with {"status": "processing"}. Only the
// moves in orderTransitions are allowed, and cancelling from here puts the kg
// back on the shelf exactly like the buyer's own cancel.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/admin_order_service.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Moves an order to its next status.
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
    body: await changeOrderStatus(context.read<Db>(), id, body),
  );
}
