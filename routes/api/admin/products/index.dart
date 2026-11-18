import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/product_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

Future<Response> onRequest(RequestContext context) async {
  final db = context.read<Db>();

  if (context.request.method == HttpMethod.get) {
    final query = context.request.uri.queryParameters;
    final page = await adminListProducts(db, query);
    return Response.json(body: page);
  }

  if (context.request.method == HttpMethod.post) {
    final raw = await context.request.body();
    final Object? body;
    try {
      body = jsonDecode(raw);
    } catch (_) {
      return jsonError(400, 'Body must be valid JSON');
    }
    final created = await createProduct(db, body);
    return Response.json(statusCode: 201, body: created);
  }

  return Response(statusCode: 405);
}
