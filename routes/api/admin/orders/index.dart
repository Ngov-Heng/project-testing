// WHY: Screen 38 is the orders table: search by order number or customer, an
// "All statuses" filter, a date range, a sort order, and the counts printed
// under the title ("48 orders in November - 6 pending, 3 on the way").
// Where it sits in the flow: adminGuard already ran; the filters and the rows
// are built in admin_order_service so the dashboard can reuse the same row.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/admin_order_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Lists the shop's orders for screen 38.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  final query = context.request.uri.queryParameters;
  return Response.json(body: await adminListOrders(context.read<Db>(), query));
}
