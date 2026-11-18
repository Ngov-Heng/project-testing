import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/cart_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }

  Object? body;
  try {
    body = await context.request.json();
  } catch (_) {
    return jsonError(400, 'Body must be valid JSON');
  }
  if (body is! Map<String, dynamic>) {
    return jsonError(400, 'Body must be a JSON object');
  }

  final productIdRaw = body['productId'];
  final quantityKg = body['quantityKg'];
  if (productIdRaw is! String || productIdRaw.trim().isEmpty) {
    return jsonError(400, 'productId is required');
  }
  if (quantityKg is! num) {
    return jsonError(400, 'quantityKg must be a number');
  }

  final ObjectId productId;
  try {
    productId = ObjectId.fromHexString(productIdRaw.trim());
  } catch (_) {
    return jsonError(400, 'productId is not a valid id');
  }

  final user = context.read<Map<String, dynamic>>();
  final userId = user['_id'] as ObjectId;
  final cart = await addCartItem(
    context.read<Db>(),
    userId,
    productId,
    quantityKg,
  );
  return Response.json(body: cart);
}
