// WHY: Screen 01 (buyer login) and screen 36 (admin login) post the same
// thing: one field that is an email or a phone number, plus a password. The
// answer now also says which role the account has, because screen 36 must
// refuse a buyer, and it says whether the account is verified, because an
// unverified account goes to screen 10 instead of the home screen.
// Where it sits in the flow: the rules live in auth_service.loginAccount;
// this file only reads JSON. Screens 36's second check (admin only) is
// adminGuard, which already protects every /api/admin route since chunk 2.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/auth_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Logs a buyer or the shop owner in.
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

  final result = await loginAccount(context.read<Db>(), body);
  return Response.json(body: result);
}
