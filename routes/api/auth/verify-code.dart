// WHY: Screen 10 is six boxes and a Verify button. A correct code proves the
// buyer owns the phone number or email they signed up with, so the account
// becomes verified and a token comes back - that token is how the app reaches
// the home screen without going through the login screen again.
// Where it sits in the flow: POST /api/auth/verify-code with
// {"identifier": "...", "code": "482913"}; the code, its 10-minute life and
// the five-try limit are enforced in auth_service.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/auth_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Checks the six digits from screen 10.
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

  final result = await verifyAccount(context.read<Db>(), body);
  return Response.json(body: result);
}
