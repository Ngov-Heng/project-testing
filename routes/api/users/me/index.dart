import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/profile_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

Future<Response> onRequest(RequestContext context) async {
  final user = context.read<Map<String, dynamic>>();
  final userId = user['_id'] as ObjectId;

  if (context.request.method == HttpMethod.get) {
    return Response.json(body: profileView(user));
  }

  if (context.request.method == HttpMethod.put) {
    final raw = await context.request.body();
    final Object? body;
    try {
      body = jsonDecode(raw);
    } catch (_) {
      return jsonError(400, 'Body must be valid JSON');
    }
    final saved = await updateProfile(context.read<Db>(), userId, body);
    return Response.json(body: saved);
  }

  return Response(statusCode: 405);
}
