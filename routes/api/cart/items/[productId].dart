// WHY: Changes or removes one line of the buyer's cart.
// Where it sits in the flow: route -> authGuard -> cart_service.
// PUT sets a new quantity in kg, DELETE takes the line out.
// Removing by setting 0 kg is not allowed on purpose: DELETE says it clearly.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/cart_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

Future<Response> onRequest(RequestContext context, String productId) async {
  final ObjectId id;
  try {
    id = ObjectId.fromHexString(productId);
  } catch (_) {
    return jsonError(400, 'Invalid product id');
  }

  final user = context.read<Map<String, dynamic>>();
  final userId = user['_id'] as ObjectId;
  final db = context.read<Db>();

  switch (context.request.method) {
    case HttpMethod.put:
      Object? body;
      try {
        body = await context.request.json();
      } catch (_) {
        return jsonError(400, 'Body must be valid JSON');
      }
      if (body is! Map<String, dynamic>) {
        return jsonError(400, 'Body must be a JSON object');
      }

      final quantityKg = body['quantityKg'];
      if (quantityKg is! num) {
        return jsonError(400, 'quantityKg must be a number');
      }

      return Response.json(
        body: await changeCartItemKg(db, userId, id, quantityKg),
      );

    case HttpMethod.delete:
      return Response.json(body: await removeCartItem(db, userId, id));

    case HttpMethod.get:
    case HttpMethod.post:
    case HttpMethod.patch:
    case HttpMethod.head:
    case HttpMethod.options:
      return Response(statusCode: 405);
  }
}
