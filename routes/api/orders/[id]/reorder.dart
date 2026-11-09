// WHY: The Reorder button on screen 07 is one call, so the app does not have
// to loop over items itself and guess why one of them failed.
// Where it sits in the flow: authGuard has already run; order_service copies
// the order's items into the cart at today's prices and reports what it
// skipped.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/order_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Puts one of this buyer's old orders back into their cart.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }

  final user = context.read<Map<String, dynamic>>();
  final result = await reorderOrder(
    context.read<Db>(),
    user['_id'] as ObjectId,
    parseOrderId(id),
  );
  return Response.json(body: result);
}
