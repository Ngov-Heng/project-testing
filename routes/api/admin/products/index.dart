// WHY: Screen 41 is the products table (search, category filter, stock filter,
// "8 rice products - 3,268 kg in stock") and screen 42 saves a new product
// through the same path.
// Where it sits in the flow: adminGuard in routes/api/admin/_middleware.dart
// has already refused anyone who is not the owner. Rules and the stock status
// live in product_service.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/product_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Lists the catalogue for screen 41, or adds a product from screen 42.
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
