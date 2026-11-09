// WHY: Screen 11 asks for "your email or phone number" and answers with one
// sentence: a code is on its way. The endpoint deliberately says the same
// thing whether or not the account exists, so nobody can use it to discover
// who shops at FAHENG.
// Where it sits in the flow: POST /api/auth/forgot-password; the code it
// creates is stored with purpose "reset", so it can only be used on screen 12
// and never to verify a new sign-up.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/auth_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Starts the forgotten-password flow from screen 11.
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

  final result = await requestPasswordReset(context.read<Db>(), body);
  return Response.json(body: result);
}
