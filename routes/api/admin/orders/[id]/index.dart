// WHY: Screen 39 opens one order: the items, the totals, the customer card
// ("Regular customer - 12 orders"), the delivery date, and the status dropdown
// that must only offer the statuses the server would accept.
// Where it sits in the flow: adminGuard already ran. The answer carries
// `allowedStatuses` from orderTransitions, which is the same map chunk 3 wrote.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/admin_order_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Returns one order for the admin detail screen.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  return Response.json(
    body: await adminOrderDetail(context.read<Db>(), id),
  );
}
