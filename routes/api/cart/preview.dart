// WHY: The totals only, for the checkout screen and for testing the pricing
// rules without reading the item list.
// Where it sits in the flow: route -> authGuard -> buildCartView, and we keep
// only the money part. It reuses buildCartView on purpose: one pricing
// function, so the preview and the real order can never disagree.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/cart_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }

  final user = context.read<Map<String, dynamic>>();
  final userId = user['_id'] as ObjectId;

  final cart = await buildCartView(context.read<Db>(), userId);
  return Response.json(
    body: {
      'totalKg': cart['totalKg'],
      'subtotal': cart['subtotal'],
      'discount': cart['discount'],
      'deliveryFee': cart['deliveryFee'],
      'total': cart['total'],
      'grandTotal': cart['grandTotal'],
    },
  );
}
