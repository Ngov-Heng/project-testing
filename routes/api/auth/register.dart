// WHY: Screen 09 (sign up) collects full name, one contact, a password and
// "I'm buying for" (household or business). The account it creates is not
// usable yet: this chunk's rule is verify first, log in after.
// Where it sits in the flow: the field checks, the duplicate check and the
// first 6-digit code all live in auth_service; this file only reads JSON and
// answers 201.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/auth_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Creates an account and sends the code for screen 10.
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

  final created = await registerAccount(context.read<Db>(), body);
  return Response.json(statusCode: 201, body: created);
}
