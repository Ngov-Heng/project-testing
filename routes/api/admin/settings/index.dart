// WHY: Screen 48 (discount and delivery fee) and screen 50 (shop info and
// payment toggles) both read and save the one settings document.
// Where it sits in the flow: the admin console sends GET to fill the form and
// PUT to save it. admin_guard has already rejected anyone who is not the owner,
// and settings_service does the validation and the database work.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/settings_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// GET returns the current settings, PUT saves the whole form.
/// Both answer with the same shape, so the screen can load, edit and send it
/// straight back.
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
