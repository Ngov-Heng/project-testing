import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/settings_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

Future<Response> onRequest(RequestContext context) async {
  final db = context.read<Db>();

  if (context.request.method == HttpMethod.get) {
    final settings = await loadSettings(db);
    return Response.json(body: adminSettingsView(settings));
  }

  if (context.request.method == HttpMethod.put) {
    final raw = await context.request.body();
    final Object? body;
    try {
      body = jsonDecode(raw);
    } catch (_) {
      return jsonError(400, 'Body must be valid JSON');
    }
    final saved = await saveSettings(db, body);
    return Response.json(body: adminSettingsView(saved));
  }

  return Response(statusCode: 405);
}
