import 'package:dart_frog/dart_frog.dart';
import 'package:mongo_dart/mongo_dart.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }

  final params = context.request.uri.queryParameters;
  final category = params['category'];
  final page = int.tryParse(params['page'] ?? '') ?? 1;
  final limit = int.tryParse(params['limit'] ?? '') ?? 10;

  if (page < 1 || limit < 1 || limit > 50) {
    return Response.json(
      statusCode: 400,
      body: {'error': 'page must be 1 or more, limit must be 1 to 50'},
    );
  }

  final db = context.read<Db>();
  final collection = db.collection('products');

  final selector = where.eq('isActive', true);
  if (category != null && category.isNotEmpty) {
    selector.eq('category', category);
  }

  final total = await collection.count(selector);

  selector.sortBy('name').skip((page - 1) * limit).limit(limit);
  final docs = await collection.find(selector).toList();

  final items = docs.map((doc) {
    return {...doc, '_id': (doc['_id'] as ObjectId).oid};
  }).toList();

  return Response.json(
    body: {'items': items, 'total': total, 'page': page, 'limit': limit},
  );
}
