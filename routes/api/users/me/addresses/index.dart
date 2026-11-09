// WHY: Screens 18 (address list) and 19 (add address).
// Where it sits in the flow: /api/users/_middleware.dart has already run
// authGuard. GET lists this buyer's addresses (default first), POST adds one
// through address_service. The buyer id always comes from the token, never
// from the body, so a buyer cannot write into somebody else's list.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/address_service.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Lists the addresses, or adds a new one.
Future<Response> onRequest(RequestContext context) async {
  final user = context.read<Map<String, dynamic>>();
  final userId = user['_id'] as ObjectId;
  final db = context.read<Db>();

  if (context.request.method == HttpMethod.get) {
    final items = await listAddresses(db, userId);
    return Response.json(body: {'items': items});
  }

  if (context.request.method == HttpMethod.post) {
    final raw = await context.request.body();
    final Object? body;
    try {
      body = jsonDecode(raw);
    } catch (_) {
      return jsonError(400, 'Body must be valid JSON');
    }
    final clean = cleanAddressInput(body);
    final created = await createAddress(db, userId, clean);
    return Response.json(statusCode: 201, body: created);
  }

  return Response(statusCode: 405);
}
