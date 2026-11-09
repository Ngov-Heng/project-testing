// WHY: Screen 10 counts down "Resend code in 0:42" and then turns that line
// into a button. Sending again too early would let a bot burn through codes,
// so the 60-second wait lives in auth_service.
// Where it sits in the flow: POST /api/auth/resend-code with
// {"identifier": "..."} while the account is still unverified.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/auth_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Sends a new sign-up code for screen 10.
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

  final result = await resendSignupCode(context.read<Db>(), body);
  return Response.json(body: result);
}
