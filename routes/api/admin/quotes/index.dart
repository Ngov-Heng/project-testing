// WHY: Screen 47 (quote requests) is the admin's list: search, status filter
// and the counts under the title.
// Where it sits in the flow: the admin guard for /api/admin has already run, so
// this route only reads the query string.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/quote_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Lists the shop's quote requests.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }

  final page = await adminListQuotes(
    context.read<Db>(),
    context.request.uri.queryParameters,
  );
  return Response.json(body: page);
}
