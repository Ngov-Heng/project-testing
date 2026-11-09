// WHY: Screens 08 (profile) and 32 (edit profile) show and save the logged in
// buyer's own details.
// Where it sits in the flow: /api/users/_middleware.dart has already run
// authGuard, so context.read<Map<String, dynamic>>() is the logged in user.
// GET returns the profile, PUT saves the full name, phone and email through
// profile_service.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/profile_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Returns the profile, or saves a new one.
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
