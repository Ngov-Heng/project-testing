import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/report_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

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
