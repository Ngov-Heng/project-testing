// Products and their categories, including the 100 kg low-stock line.
// Collections: products, categories

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/json_safe.dart';
import 'package:mongo_dart/mongo_dart.dart';

const int lowStockKg = 100;
const int maxDescriptionLength = 160;

const List<String> stockLevelFilters = <String>[
  'all',
  'in_stock',
  'low',
  'out',
];

const List<String> productSorts = <String>[
  'name',
  'price_asc',
  'price_desc',
];

String stockStatus(int stock) {
  if (stock <= 0) return 'out';
  if (stock < lowStockKg) return 'low';
  return 'in_stock';
}

String cleanProductName(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const ApiError(400, 'name is required');
  }
  final name = value.trim();
  if (name.length > 80) {
    throw const ApiError(400, 'name must be 80 characters or less');
  }
  return name;
}

double cleanPricePerKg(Object? value) {
  if (value is! num) {
    throw const ApiError(400, 'pricePerKg is required as a number');
  }
  if (value <= 0) {
    throw const ApiError(400, 'pricePerKg must be more than 0');
  }
  if (value > 1000) {
    throw const ApiError(400, 'pricePerKg must be 1000 or less');
  }
  return double.parse(value.toStringAsFixed(2));
}

int cleanStockKg(Object? value) {
  if (value is num) {
    if (value < 0) {
      throw const ApiError(400, 'stock cannot be negative');
    }
    if (value != value.roundToDouble()) {
      throw const ApiError(400, 'stock must be whole kilograms');
    }
    return value.toInt();
  }
  throw const ApiError(400, 'stock is required as a number');
}

String? cleanDescription(Object? value) {
  if (value == null) return null;
  if (value is! String) {
    throw const ApiError(400, 'description must be a string');
  }
  final text = value.trim();
  if (text.length > maxDescriptionLength) {
    throw const ApiError(
      400,
      'description must be 160 characters or less',
    );
  }
  return text.isEmpty ? null : text;
}

String? cleanImage(Object? value) {
  if (value == null) return null;
  if (value is! String) {
    throw const ApiError(400, 'image must be a string');
  }
  final text = value.trim();
  if (text.isEmpty) return null;
  if (text.length > 300) {
    throw const ApiError(400, 'image must be 300 characters or less');
  }
  return text;
}

bool cleanIsActive(Object? value) {
  if (value == null) return true;
  if (value is! bool) {
    throw const ApiError(400, 'isActive must be true or false');
  }
  return value;
}

bool cleanIsFeatured(Object? value) {
  if (value == null) return false;
  if (value is! bool) {
    throw const ApiError(400, 'isFeatured must be true or false');
  }
  return value;
}

class CleanProduct {
  const CleanProduct({
    required this.name,
    required this.category,
    required this.pricePerKg,
    required this.stock,
    required this.isActive,
    required this.isFeatured,
    this.description,
    this.image,
  });
  final String name;
  final String category;
  final double pricePerKg;
  final int stock;
  final bool isActive;
  final bool isFeatured;
  final String? description;
  final String? image;
}

Future<void> ensureCategoryExists(Db db, String category) async {
  final found = await db
      .collection('categories')
      .findOne(where.eq('name', category));
  if (found == null) {
    throw const ApiError(400, 'category must be one of the shop categories');
  }
}

Future<CleanProduct> cleanProduct(Db db, Object? body) async {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }
  final categoryRaw = body['category'];
  if (categoryRaw is! String || categoryRaw.trim().isEmpty) {
    throw const ApiError(400, 'category is required');
  }
  final category = categoryRaw.trim();
  await ensureCategoryExists(db, category);

  return CleanProduct(
    name: cleanProductName(body['name']),
    category: category,
    pricePerKg: cleanPricePerKg(body['pricePerKg']),
    stock: cleanStockKg(body['stock']),
    isActive: cleanIsActive(body['isActive']),
    isFeatured: cleanIsFeatured(body['isFeatured']),
    description: cleanDescription(body['description']),
    image: cleanImage(body['image']),
  );
}

Map<String, dynamic> productDoc(CleanProduct clean) {
  return <String, dynamic>{
    'name': clean.name,
    'category': clean.category,
    'pricePerKg': clean.pricePerKg,
    'stock': clean.stock,
    'description': clean.description,
    'image': clean.image,
    'isActive': clean.isActive,
    'isFeatured': clean.isFeatured,
  };
}

Map<String, dynamic> publicProductView(Map<String, dynamic> doc) =>
    rawDocView(doc);

Map<String, dynamic> adminProductView(Map<String, dynamic> doc) {
  final stock = (doc['stock'] as num?)?.toInt() ?? 0;
  final updatedAt = doc['updatedAt'];
  final createdAt = doc['createdAt'];
  return <String, dynamic>{
    'id': (doc['_id'] as ObjectId).oid,
    'name': doc['name'],
    'category': doc['category'],
    'pricePerKg': doc['pricePerKg'],
    'stock': stock,
    'stockStatus': stockStatus(stock),
    'description': doc['description'],
    'image': doc['image'],
    'isActive': doc['isActive'] ?? true,
    'isFeatured': doc['isFeatured'] ?? false,
    if (createdAt is DateTime) 'createdAt': createdAt.toIso8601String(),
    if (updatedAt is DateTime) 'updatedAt': updatedAt.toIso8601String(),
  };
}

class AdminProductFilters {
  const AdminProductFilters({
    required this.page,
    required this.limit,
    required this.stockLevel,
    this.search,
    this.category,
  });
  final int page;
  final int limit;
  final String stockLevel;
  final String? search;
  final String? category;
}

AdminProductFilters adminProductFilters(Map<String, String> query) {
  final page = int.tryParse(query['page'] ?? '') ?? 1;
  final limit = int.tryParse(query['limit'] ?? '') ?? 20;
  if (page < 1 || limit < 1 || limit > 100) {
    throw const ApiError(400, 'page must be 1 or more and limit 1 to 100');
  }
  final level = (query['stockLevel'] ?? 'all').toLowerCase();
  if (!stockLevelFilters.contains(level)) {
    throw const ApiError(
      400,
      'stockLevel must be all, in_stock, low or out',
    );
  }
  final search = query['q']?.trim();
  final category = query['category']?.trim();
  return AdminProductFilters(
    page: page,
    limit: limit,
    stockLevel: level,
    search: (search == null || search.isEmpty) ? null : search,
    category: (category == null || category.isEmpty) ? null : category,
  );
}

SelectorBuilder buildProductQuery(AdminProductFilters filters) {
  final selector = SelectorBuilder();
  if (filters.category != null) {
    selector.eq('category', filters.category);
  }
  switch (filters.stockLevel) {
    case 'in_stock':
      selector.gte('stock', lowStockKg);
    case 'low':
      selector.gt('stock', 0).lt('stock', lowStockKg);
    case 'out':
      selector.lte('stock', 0);
  }
  return selector;
}

Future<List<ObjectId>> searchProductIds(Db db, String term) async {
  final pattern = RegExp.escape(term);
  final byName = await db
      .collection('products')
      .find(where.match('name', pattern, caseInsensitive: true))
      .toList();
  final byCategory = await db
      .collection('products')
      .find(where.match('category', pattern, caseInsensitive: true))
      .toList();
  return <ObjectId>{
    for (final doc in [...byName, ...byCategory]) doc['_id'] as ObjectId,
  }.toList();
}

Future<Map<String, dynamic>> adminListProducts(
  Db db,
  Map<String, String> query,
) async {
  final filters = adminProductFilters(query);
  final collection = db.collection('products');
  final selector = buildProductQuery(filters);

  if (filters.search != null) {
    final ids = await searchProductIds(db, filters.search!);
    if (ids.isEmpty) {
      return <String, dynamic>{
        'items': const <Map<String, dynamic>>[],
        'total': 0,
        'page': filters.page,
        'limit': filters.limit,
        'summary': await _productSummary(db),
      };
    }
    selector.oneFrom('_id', ids);
  }

  final total = await collection.count(selector);
  final paged = selector
      .sortBy('name')
      .skip((filters.page - 1) * filters.limit)
      .limit(filters.limit);
  final docs = await collection.find(paged).toList();

  return <String, dynamic>{
    'items': docs.map(adminProductView).toList(),
    'total': total,
    'page': filters.page,
    'limit': filters.limit,
    'summary': await _productSummary(db),
  };
}

Future<Map<String, dynamic>> _productSummary(Db db) async {
  final everything = await db.collection('products').find().toList();
  final totalKg = everything.fold<int>(
    0,
    (sum, doc) => sum + ((doc['stock'] as num?)?.toInt() ?? 0),
  );
  final low = everything.where((doc) {
    final stock = (doc['stock'] as num?)?.toInt() ?? 0;
    return stock > 0 && stock < lowStockKg;
  }).length;
  final out = everything
      .where((doc) => ((doc['stock'] as num?)?.toInt() ?? 0) <= 0)
      .length;
  return <String, dynamic>{
    'products': everything.length,
    'totalKg': totalKg,
    'lowStock': low,
    'outOfStock': out,
  };
}

Future<Map<String, dynamic>> stockOverview(Db db) async {
  final docs = await db
      .collection('products')
      .find(where.sortBy('stock'))
      .toList();
  final totalKg = docs.fold<int>(
    0,
    (sum, doc) => sum + ((doc['stock'] as num?)?.toInt() ?? 0),
  );
  final items = docs.map(adminProductView).toList();
  return <String, dynamic>{
    'summary': <String, dynamic>{
      'products': docs.length,
      'totalKg': totalKg,
      'lowStock': items.where((item) => item['stockStatus'] == 'low').length,
      'outOfStock': items.where((item) => item['stockStatus'] == 'out').length,
      'reorderLevelKg': lowStockKg,
    },
    'items': items,
  };
}

Future<Map<String, dynamic>> createProduct(Db db, Object? body) async {
  final clean = await cleanProduct(db, body);
  final now = DateTime.now().toUtc();
  final id = ObjectId();
  final inserted = await db.collection('products').insertOne(<String, dynamic>{
    '_id': id,
    ...productDoc(clean),
    'createdAt': now,
  });
  if (!inserted.isSuccess) {
    throw const ApiError(500, 'Could not save the product');
  }
  final saved = <String, dynamic>{
    '_id': id,
    ...productDoc(clean),
    'createdAt': now,
  };
  return adminProductView(saved);
}

ObjectId parseProductId(String raw) {
  try {
    return ObjectId.fromHexString(raw);
  } catch (_) {
    throw const ApiError(404, 'Product not found');
  }
}

Future<Map<String, dynamic>> updateProduct(
  Db db,
  String rawId,
  Object? body,
) async {
  final id = parseProductId(rawId);
  final clean = await cleanProduct(db, body);
  final collection = db.collection('products');
  final result = await collection.updateOne(
    where.id(id),
    modify
        .set('name', clean.name)
        .set('category', clean.category)
        .set('pricePerKg', clean.pricePerKg)
        .set('stock', clean.stock)
        .set('description', clean.description)
        .set('image', clean.image)
        .set('isActive', clean.isActive)
        .set('isFeatured', clean.isFeatured)
        .set('updatedAt', DateTime.now().toUtc()),
  );
  if (result.nMatched == 0) {
    throw const ApiError(404, 'Product not found');
  }
  final doc = await collection.findOne(where.id(id));
  if (doc == null) throw const ApiError(404, 'Product not found');
  return adminProductView(doc);
}

Future<Map<String, dynamic>> restockProduct(
  Db db,
  String rawId,
  Object? body,
) async {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }
  final id = parseProductId(rawId);
  final stock = cleanStockKg(body['stock']);
  final collection = db.collection('products');
  final now = DateTime.now().toUtc();
  final result = await collection.updateOne(
    where.id(id),
    modify.set('stock', stock).set('restockedAt', now).push(
      'restockHistory',
      <String, dynamic>{'stock': stock, 'at': now},
    ),
  );
  if (result.nMatched == 0) {
    throw const ApiError(404, 'Product not found');
  }
  final doc = await collection.findOne(where.id(id));
  if (doc == null) throw const ApiError(404, 'Product not found');
  return adminProductView(doc);
}
