// WHY: Screen 34 (change password) is reached from Settings (33) while the
// buyer is logged in, so it is the opposite of screen 12: here the old
// password must be typed, and there is no code involved.
// Where it sits in the flow: authGuard in routes/api/users/_middleware.dart
// has already loaded the user, so this file only reads JSON and calls
// auth_service.changePassword with that user.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/auth_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Changes the logged-in buyer's own password (screen 34).
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.patch) {
    return Response(statusCode: 405);
  }

  final raw = await context.request.body();
  final Object? body;
  try {
    body = jsonDecode(raw);
  } catch (_) {
    return jsonError(400, 'Body must be valid JSON');
  }

  final user = context.read<Map<String, dynamic>>();
  final result = await changePassword(context.read<Db>(), user, body);
  return Response.json(body: result);
}
