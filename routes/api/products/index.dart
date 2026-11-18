import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/product_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }

  final params = context.request.uri.queryParameters;
  final category = params['category'];
  final q = params['q']?.trim();
  final featured = params['featured'] == 'true';
  final inStockOnly = params['inStock'] == 'true';
  final sort = params['sort'] ?? 'name';
  final page = int.tryParse(params['page'] ?? '') ?? 1;
  final limit = int.tryParse(params['limit'] ?? '') ?? 10;
  final minPrice = double.tryParse(params['minPrice'] ?? '');
  final maxPrice = double.tryParse(params['maxPrice'] ?? '');
  const allowedSorts = ['name', 'price_asc', 'price_desc'];
  if (page < 1 || limit < 1 || limit > 50 || !allowedSorts.contains(sort)) {
    return Response.json(
      statusCode: 400,
      body: {
        'error':
            'page must be 1 or more, limit 1 to 50, '
            'sort must be name, price_asc or price_desc',
      },
    );
  }
  if ((params['minPrice'] != null && minPrice == null) ||
      (params['maxPrice'] != null && maxPrice == null)) {
    return Response.json(
      statusCode: 400,
      body: {'error': 'minPrice and maxPrice must be numbers'},
    );
  }
  if (minPrice != null && maxPrice != null && minPrice > maxPrice) {
    return Response.json(
      statusCode: 400,
      body: {'error': 'minPrice cannot be more than maxPrice'},
    );
  }

  final db = context.read<Db>();
  final collection = db.collection('products');
  final selector = where.eq('isActive', true);
  if (category != null && category.isNotEmpty) {
    selector.eq('category', category);
  }
  if (q != null && q.isNotEmpty) {
    selector.match('name', RegExp.escape(q), caseInsensitive: true);
  }
  if (featured) {
    selector.eq('isFeatured', true);
  }

  if (minPrice != null) selector.gte('pricePerKg', minPrice);
  if (maxPrice != null) selector.lte('pricePerKg', maxPrice);
  if (inStockOnly) selector.gt('stock', 0);
  final total = await collection.count(selector);

  switch (sort) {
    case 'price_asc':
      selector.sortBy('pricePerKg');
    case 'price_desc':
      selector.sortBy('pricePerKg', descending: true);
    default:
      selector.sortBy('name');
  }
  selector.skip((page - 1) * limit).limit(limit);
  final docs = await collection.find(selector).toList();
  final items = docs.map(publicProductView).toList();

  return Response.json(
    body: {'items': items, 'total': total, 'page': page, 'limit': limit},
  );
}
