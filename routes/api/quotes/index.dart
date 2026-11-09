// WHY: Screen 25 (bulk quote request) posts here, and the buyer's own list of
// requests is read from the same path.
// Where it sits in the flow: authGuard has already run, so the buyer id comes
// from the token. The rules live in quote_service.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/quote_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Sends a quote request, or lists this buyer's requests.
Future<Response> onRequest(RequestContext context) async {
  final user = context.read<Map<String, dynamic>>();
  final userId = user['_id'] as ObjectId;
  final db = context.read<Db>();

  if (context.request.method == HttpMethod.get) {
    final page = await listMyQuotes(
      db,
      userId,
      context.request.uri.queryParameters,
    );
    return Response.json(body: page);
  }

  if (context.request.method == HttpMethod.post) {
    final raw = await context.request.body();
    final Object? body;
    try {
      body = jsonDecode(raw);
    } catch (_) {
      return jsonError(400, 'Body must be valid JSON');
    }
    final created = await createQuote(db, userId, body);
    return Response.json(statusCode: 201, body: created);
  }

  return Response(statusCode: 405);
}
