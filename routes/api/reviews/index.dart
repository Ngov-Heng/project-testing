// WHY: Screen 17 (product reviews) asks for one product's reviews and needs
// the average, the count and the star breakdown on top of the list.
// Where it sits in the flow: this route is public, because a shopper who has
// not signed up still wants to read reviews before buying. It only reads the
// query string; the rules and the query live in review_service.
//
// Why /api/reviews?productId=... and not /api/products/:id/reviews: Dart Frog
// cannot hold both routes/api/products/[id].dart and routes/api/products/[id]/
// at the same time, and [id].dart is already the product detail from chunk 6.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/review_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Lists the reviews of one product.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }

  final page = await listProductReviews(
    context.read<Db>(),
    context.request.uri.queryParameters,
  );
  return Response.json(body: page);
}
