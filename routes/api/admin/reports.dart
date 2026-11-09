// WHY: Screen 49 (sales reports) is one range picker and three answers:
// revenue per day, top products by kg, best customers by spend.
// Where it sits in the flow: the /api/admin guard has already checked the role;
// the range comes from the query string, and no range means the last 7 days.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/report_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Builds the sales report for a date range.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }

  final report = await salesReport(
    context.read<Db>(),
    context.request.uri.queryParameters,
  );
  return Response.json(body: report);
}
