import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/paypal_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  final user = context.read<Map<String, dynamic>>();
  final db = context.read<Db>();
  final userId = user['_id'] as ObjectId;

  if (context.request.method == HttpMethod.post) {
    final started = await startPaypalPayment(db, userId, id);
    return Response.json(statusCode: 201, body: started);
  }

  if (context.request.method == HttpMethod.get) {
    return Response.json(body: await paypalPaymentStatus(db, userId, id));
  }

  return Response(statusCode: 405);
}
