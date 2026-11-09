// WHY: Screen 46 (customer detail) needs the contact details, the three cards
// and the five most recent orders in one response.
// Where it sits in the flow: the /api/admin guard has already checked the role;
// an unknown or non-buyer id answers 404 inside the service.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/customer_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Returns one customer.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }

  final customer = await adminCustomerDetail(context.read<Db>(), id);
  return Response.json(body: customer);
}
