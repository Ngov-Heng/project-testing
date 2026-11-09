// WHY: Screen 43 has a Restock button on every row. It sets the counted stock,
// which is what the admin actually knows after counting the bags, and it keeps
// a small history so the audit question ("who emptied this?") is answerable.
// Where it sits in the flow: POST /api/admin/products/:id/restock {"stock": 400}.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/product_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Saves the new stock level for one product.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
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
    body: await restockProduct(context.read<Db>(), id, body),
  );
}
