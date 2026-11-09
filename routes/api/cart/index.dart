// WHY: The cart screen itself.
// Where it sits in the flow: route -> authGuard (routes/api/cart/_middleware)
// -> cart_service. GET shows the cart, DELETE empties it.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/cart_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

Future<Response> onRequest(RequestContext context) async {
  final user = context.read<Map<String, dynamic>>();
  final userId = user['_id'] as ObjectId;
  final db = context.read<Db>();

  switch (context.request.method) {
    case HttpMethod.get:
      return Response.json(body: await buildCartView(db, userId));
    case HttpMethod.delete:
      return Response.json(body: await clearCart(db, userId));
    case HttpMethod.post:
    case HttpMethod.put:
    case HttpMethod.patch:
    case HttpMethod.head:
    case HttpMethod.options:
      return Response(statusCode: 405);
  }
}
