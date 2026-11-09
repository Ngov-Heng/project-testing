// WHY: Screen 43 is stock as its own subject: three cards (products, low
// stock, out of stock) and a table sorted by "what should I act on first".
// Where it sits in the flow: adminGuard already ran. The 100 kg reorder level
// is one constant in product_service, so this screen and screen 41 can never
// disagree about what "Low" means.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/product_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Returns the stock overview for screen 43.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  return Response.json(body: await stockOverview(context.read<Db>()));
}
