// WHY: Screen 47's right hand panel is "Respond to quote", and its "Send quote"
// button posts the price here.
// Where it sits in the flow: the /api/admin guard has already run; the body is
// {"pricePerKg": 1.33, "note": "..."}.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/quote_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Sends (or re-sends) the price of one quote request.
Future<Response> onRequest(RequestContext context, String id) async {
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

  final quote = await sendQuote(context.read<Db>(), id, body);
  return Response.json(body: quote);
}
