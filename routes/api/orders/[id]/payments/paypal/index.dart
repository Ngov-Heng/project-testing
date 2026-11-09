// WHY: Screen 21a presses "Pay with PayPal" (POST) and screen 21b waits for
// the answer (GET), so both live on the same path.
// Where it sits in the flow: authGuard has already run for /api/orders; the
// order must belong to this buyer, which the service checks.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/paypal_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Opens a PayPal payment, or reports where it has got to.
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
