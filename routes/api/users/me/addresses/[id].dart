// WHY: Screens 18 and 19 again, for the Edit and Delete actions on one saved
// address.
// Where it sits in the flow: /api/users/_middleware.dart has already run
// authGuard. The id from the URL is looked up together with the buyer id, so an
// id that belongs to another buyer answers 404 and reveals nothing.

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/address_service.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Replaces one address, or deletes it.
Future<Response> onRequest(RequestContext context, String id) async {
  final user = context.read<Map<String, dynamic>>();
  final userId = user['_id'] as ObjectId;
  final db = context.read<Db>();
  final addressId = parseAddressId(id);

  if (context.request.method == HttpMethod.put) {
    final raw = await context.request.body();
    final Object? body;
    try {
      body = jsonDecode(raw);
    } catch (_) {
      return jsonError(400, 'Body must be valid JSON');
    }
    final clean = cleanAddressInput(body);
    final saved = await updateAddress(db, userId, addressId, clean);
    return Response.json(body: saved);
  }

  if (context.request.method == HttpMethod.delete) {
    final items = await deleteAddress(db, userId, addressId);
    return Response.json(body: {'items': items});
  }

  return Response(statusCode: 405);
}
