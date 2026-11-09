// WHY: Screen 26 (order detail) and screen 27 (delivery map) need one order
// with its items, address copy and status history.
// Where it sits in the flow: authGuard has already run; the id from the URL is
// looked up together with the buyer id, so another buyer's order answers 404.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/order_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Returns one order that belongs to this buyer.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }

  final user = context.read<Map<String, dynamic>>();
  final order = await findOrder(
    context.read<Db>(),
    user['_id'] as ObjectId,
    parseOrderId(id),
  );
  return Response.json(body: order);
}
