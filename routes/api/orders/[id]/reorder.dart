import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/order_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

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
