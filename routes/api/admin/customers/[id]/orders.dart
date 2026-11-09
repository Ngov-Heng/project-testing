// WHY: Screen 46 shows only the five most recent orders and a footer saying
// "Showing 5 of 11"; the rest is read here, with the same row shape as screen
// 38 so the table code is shared.
// Where it sits in the flow: the /api/admin guard has already checked the role.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/customer_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Lists one customer's orders, newest first.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }

  final page = await adminCustomerOrders(
    context.read<Db>(),
    id,
    context.request.uri.queryParameters,
  );
  return Response.json(body: page);
}
