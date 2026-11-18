import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/category_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

Future<Response> onRequest(RequestContext context) async {
  final db = context.read<Db>();

  if (context.request.method == HttpMethod.get) {
    return Response.json(body: await adminCategories(db));
  }

  if (context.request.method == HttpMethod.post) {
    final raw = await context.request.body();
    final Object? body;
    try {
      body = jsonDecode(raw);
    } catch (_) {
      return jsonError(400, 'Body must be valid JSON');
    }
    final created = await createCategory(db, body);
    return Response.json(statusCode: 201, body: created);
  }

  return Response(statusCode: 405);
}
