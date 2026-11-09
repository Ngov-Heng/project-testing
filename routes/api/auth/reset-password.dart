// WHY: Screen 12 types the new password twice and prints "Your new password
// must be different from your old one". The app compares the two boxes itself;
// the server checks the rule that matters - the code from screen 11 must still
// be valid, and the new password must not be the old one.
// Where it sits in the flow: POST /api/auth/reset-password with
// {"identifier": "...", "code": "482913", "password": "..."}. No token is
// needed: the code is the proof. The buyer logs in afterwards.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/auth_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Saves the new password from screen 12.
Future<Response> onRequest(RequestContext context) async {
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

  final result = await resetPassword(context.read<Db>(), body);
  return Response.json(body: result);
}
