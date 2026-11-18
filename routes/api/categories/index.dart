import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/category_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  return Response.json(body: await publicCategories(context.read<Db>()));
}
