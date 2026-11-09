// WHY: Screen 40 is the week: seven days, a Morning and an Afternoon column,
// the kg per day, a "Heavy" badge for 150 kg or more, and a panel of orders
// that still have no confirmed slot.
// Where it sits in the flow: GET /api/admin/delivery-schedule?weekStart=...
// (any day inside the wanted week; today's week when it is left out). The
// week runs Monday to Sunday, which is how the screen's header reads.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/admin_order_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Returns one week of deliveries plus the unscheduled orders.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  final query = context.request.uri.queryParameters;
  return Response.json(
    body: await deliverySchedule(context.read<Db>(), query),
  );
}
