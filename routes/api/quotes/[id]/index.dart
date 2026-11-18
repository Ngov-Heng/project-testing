import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/quote_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }

  final user = context.read<Map<String, dynamic>>();
  final quote = await findMyQuote(
    context.read<Db>(),
    user['_id'] as ObjectId,
    id,
  );
  return Response.json(body: quote);
}
