// WHY: Screen 37 is the first thing the owner sees: orders today, revenue
// today, pending orders, low stock items, the five most recent orders and the
// low stock list beside them.
// Where it sits in the flow: adminGuard already ran. "Today" is a Phnom Penh
// day (UTC+7), the same rule the buyer's delivery dates use.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/admin_order_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Returns the dashboard cards and lists.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  return Response.json(body: await adminDashboard(context.read<Db>()));
}
