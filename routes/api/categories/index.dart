// WHY: The category chips on screens 03 (listing), 15 (filter) and 44 (admin)
// all need the same list. It now also carries `productCount`, so a chip can
// say how many varieties sit behind it without a second request.
// Where it sits in the flow: public route, read-only; admin writes live in
// routes/api/admin/categories. The rule code is in category_service.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/category_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  return Response.json(body: await publicCategories(context.read<Db>()));
}
