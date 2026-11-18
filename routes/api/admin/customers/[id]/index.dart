import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/customer_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }

  final customer = await adminCustomerDetail(context.read<Db>(), id);
  return Response.json(body: customer);
}
