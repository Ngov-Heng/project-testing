// WHY: Screen 45 (customers list) needs one page of buyers with their order
// count, their spend and their town, plus the counts in the subtitle.
// Where it sits in the flow: the /api/admin guard has already checked the role,
// so this route only reads the query string.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/customer_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Lists the shop's customers.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }

  final page = await adminListCustomers(
    context.read<Db>(),
    context.request.uri.queryParameters,
  );
  return Response.json(body: page);
}
