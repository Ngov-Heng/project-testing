// WHY: The notification on screen 31 links back to one quote, so the app needs
// to read a single request, including its price once the admin has answered.
// Where it sits in the flow: authGuard has already run; another buyer's quote
// answers 404 inside the service.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/quote_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Returns one of this buyer's quote requests.
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
