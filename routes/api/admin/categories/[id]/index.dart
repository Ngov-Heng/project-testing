import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/category_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  final db = context.read<Db>();

  if (context.request.method == HttpMethod.get) {
    return Response.json(body: await categoryDetail(db, id));
  }

  if (context.request.method == HttpMethod.put) {
    final raw = await context.request.body();
    final Object? body;
    try {
      body = jsonDecode(raw);
    } catch (_) {
      return jsonError(400, 'Body must be valid JSON');
    }
    return Response.json(body: await renameCategory(db, id, body));
  }

  if (context.request.method == HttpMethod.delete) {
    return Response.json(body: await deleteCategory(db, id));
  }

  return Response(statusCode: 405);
}
