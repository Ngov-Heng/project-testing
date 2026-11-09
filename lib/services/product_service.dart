// WHY: Chunk 6 is the shop catalogue: the buyer side (screens 02, 03, 13, 14,
// 15) filters and sorts, and the admin side (41, 42, 43) adds, edits and
// restocks. The rules that must be identical everywhere - a price is a
// positive dollar amount, stock is a whole number of kg, a description is at
// most 160 characters, "low stock" starts under 100 kg - live here.
// Where it sits in the flow: routes/api/products/index.dart (public list) and
// routes/api/admin/products/* (admin) call these functions. Products keep the
// original document shape on the public route (`_id`, dollars) because chunk 1
// already ships that; the admin routes answer with `id` like every new route.

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/json_safe.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Screen 43 says "Reorder level is 100 kg per product", so anything under
/// this is shown as low stock and counted in the Low stock card.
const int lowStockKg = 100;

/// Screen 42 counts the short description as "90 / 160".
const int maxDescriptionLength = 160;

/// The four values the admin stock filter (screen 41) offers.
const List<String> stockLevelFilters = <String>[
  'all',
  'in_stock',
  'low',
  'out',
];

/// The three sort orders screen 15 offers, plus `name` as the default.
const List<String> productSorts = <String>[
  'name',
  'price_asc',
  'price_desc',
];

/// Turns a stored stock number into the label screens 41 and 43 print.
String stockStatus(int stock) {
  if (stock <= 0) return 'out';
  if (stock < lowStockKg) return 'low';
  return 'in_stock';
}

/// Reads the product name from screen 42.
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

/// Reads "Price per kg" from screen 42. Stored as dollars, exactly like the
/// products that were already in the database, because cart and order code
/// reads `pricePerKg` in dollars.
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

/// Reads "Stock in kg" from screen 42. Whole kilograms only, never negative.
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

/// Reads the optional "Short description" from screen 42.
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

/// Reads the optional photo. The admin mock uploads a file; until there is a
/// file store, the route accepts the URL the upload will produce, or the icon
/// name the seed uses.
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

/// Reads the "Active" switch from screen 42. It defaults to on.
bool cleanIsActive(Object? value) {
  if (value == null) return true;
  if (value is! bool) {
    throw const ApiError(400, 'isActive must be true or false');
  }
  return value;
}

/// Reads the featured flag the home screen (02) uses. Defaults to off.
bool cleanIsFeatured(Object? value) {
  if (value == null) return false;
  if (value is! bool) {
    throw const ApiError(400, 'isFeatured must be true or false');
  }
  return value;
}

/// A product that passed every check on screen 42, ready to store.
class CleanProduct {
  /// Creates a checked product.
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

  /// The variety name shown in the list.
  final String name;

  /// Category name, which must match a document in `categories`.
  final String category;

  /// Dollars per kilogram.
  final double pricePerKg;

  /// Whole kilograms on the shelf.
  final int stock;

  /// False means hidden from the storefront (screen 42's switch).
  final bool isActive;

  /// True means it appears in the home screen's featured row.
  final bool isFeatured;

  /// Short description, at most 160 characters.
  final String? description;

  /// Photo URL or icon name.
  final String? image;
}

/// Checks a category name against the `categories` collection, because screen
/// 42 picks from a dropdown: a free-typed name that is not in the list would
/// create a category the admin screen never shows.
Future<void> ensureCategoryExists(Db db, String category) async {
  final found = await db
      .collection('categories')
      .findOne(where.eq('name', category));
  if (found == null) {
    throw const ApiError(400, 'category must be one of the shop categories');
  }
}

/// Reads the whole body of screen 42.
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

/// The document that is written to the `products` collection.
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

/// What the public list and one-product route send: the document as it is,
/// with `_id` as a hex string and any date turned into a string.
Map<String, dynamic> publicProductView(Map<String, dynamic> doc) =>
    rawDocView(doc);

/// What the admin screens get back: `id` (like every route since chunk 3) plus
/// the computed stock status, so screens 41 and 43 never have to know the
/// 100 kg rule.
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

/// Reads the filters on screen 41: search, category and stock level.
class AdminProductFilters {
  /// Creates the checked filter set.
  const AdminProductFilters({
    required this.page,
    required this.limit,
    required this.stockLevel,
    this.search,
    this.category,
  });

  /// 1-based page number.
  final int page;

  /// How many rows per page (screen 41 asks for all of them at once).
  final int limit;

  /// all, in_stock, low or out.
  final String stockLevel;

  /// Free text typed in "Search products".
  final String? search;

  /// Category name from the "All categories" dropdown.
  final String? category;
}

/// Reads the query string of screen 41.
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

/// Builds the Mongo selector for screen 41.
Map<String, dynamic> adminSelector(AdminProductFilters filters) {
  final and = <Map<String, dynamic>>[];
  if (filters.search != null) {
    and.add(<String, dynamic>{
      r'$or': <Map<String, dynamic>>[
        <String, dynamic>{
          'name': <String, dynamic>{
            r'$regex': RegExp.escape(filters.search!),
            r'$options': 'i',
          },
        },
        <String, dynamic>{
          'category': <String, dynamic>{
            r'$regex': RegExp.escape(filters.search!),
            r'$options': 'i',
          },
        },
      ],
    });
  }
  if (filters.category != null) {
    and.add({'category': filters.category});
  }
  switch (filters.stockLevel) {
    case 'in_stock':
      and.add({'stock': {r'$gte': lowStockKg}});
    case 'low':
      and.add({
        'stock': {r'$gt': 0, r'$lt': lowStockKg},
      });
    case 'out':
      and.add({'stock': {r'$lte': 0}});
  }
  return and.isEmpty ? <String, dynamic>{} : {r'$and': and};
}

/// The list on screen 41: every product, active or not, with the totals the
/// header prints ("8 rice products - 3,268 kg in stock").
Future<Map<String, dynamic>> adminListProducts(
  Db db,
  Map<String, String> query,
) async {
  final filters = adminProductFilters(query);
  final collection = db.collection('products');
  final selector = adminSelector(filters);
  final total = await collection.count(selector);
  final paged = where
      .raw(selector)
      .sortBy('name')
      .skip((filters.page - 1) * filters.limit)
      .limit(filters.limit);
  final docs = await collection.find(paged).toList();

  final everything = await collection.find().toList();
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
    'items': docs.map(adminProductView).toList(),
    'total': total,
    'page': filters.page,
    'limit': filters.limit,
    'summary': <String, dynamic>{
      'products': everything.length,
      'totalKg': totalKg,
      'lowStock': low,
      'outOfStock': out,
    },
  };
}

/// Screen 43: the three cards and the stock table. Every product, lowest
/// stock first, because that is the order the admin needs to act on.
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

/// Screen 42's Save product button.
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

/// The id from the URL, or the message screen 41 can show.
ObjectId parseProductId(String raw) {
  try {
    return ObjectId.fromHexString(raw);
  } catch (_) {
    throw const ApiError(404, 'Product not found');
  }
}

/// Screen 42 opened on an existing product: the form posts every field again,
/// so this is a full replace of the editable fields only.
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

/// Screen 43's Restock button. It sets the new level in kg rather than adding
/// to it, because the button opens a box the admin types the counted stock
/// into; `restockHistory` keeps the audit trail.
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
    modify
        .set('stock', stock)
        .set('restockedAt', now)
        .push('restockHistory', <String, dynamic>{'stock': stock, 'at': now}),
  );
  if (result.nMatched == 0) {
    throw const ApiError(404, 'Product not found');
  }
  final doc = await collection.findOne(where.id(id));
  if (doc == null) throw const ApiError(404, 'Product not found');
  return adminProductView(doc);
}
