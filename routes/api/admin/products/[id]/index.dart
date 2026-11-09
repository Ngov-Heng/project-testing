// WHY: Screen 42 opens the same form for "Add" and "Edit"; editing saves over
// one product, and the admin list may re-open a single row before showing the
// form.
// Where it sits in the flow: adminGuard already ran; the checks and the write
// are in product_service.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/product_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Reads one product for the edit form, or saves it.
Future<Response> onRequest(RequestContext context, String id) async {
  final db = context.read<Db>();

  if (context.request.method == HttpMethod.get) {
    final product = await db
        .collection('products')
        .findOne(where.id(parseProductId(id)));
    if (product == null) return jsonError(404, 'Product not found');
    return Response.json(body: adminProductView(product));
  }

  if (context.request.method == HttpMethod.put) {
    final raw = await context.request.body();
    final Object? body;
    try {
      body = jsonDecode(raw);
    } catch (_) {
      return jsonError(400, 'Body must be valid JSON');
    }
    return Response.json(body: await updateProduct(db, id, body));
  }

  return Response(statusCode: 405);
}
