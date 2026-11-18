/*
Manages product categories for both buyers and the store owner: listing
categories with live product counts, creating new categories, renaming
categories (updating all matching products), and safely deleting unused ones.
Reads and writes the "categories" and "products" collections.
*/

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/json_safe.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Reads the category name from screen 44's side panel.
String cleanCategoryName(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const ApiError(400, 'name is required');
  }
  final name = value.trim();
  if (name.length > 40) {
    throw const ApiError(400, 'name must be 40 characters or less');
  }
  return name;
}

/// The id from the URL, or the message the screen can show.
ObjectId parseCategoryId(String raw) {
  try {
    return ObjectId.fromHexString(raw);
  } catch (_) {
    throw const ApiError(404, 'Category not found');
  }
}

/// How many products use each category name. One query, not one per category.
Future<Map<String, int>> _productCounts(Db db) async {
  final docs = await db.collection('products').find().toList();
  final counts = <String, int>{};
  for (final doc in docs) {
    final name = doc['category'];
    if (name is String) counts[name] = (counts[name] ?? 0) + 1;
  }
  return counts;
}

/// The public list behind the chips on screens 03 and 15. It keeps the shape
/// chunk 1 already shipped (`_id`, `name`, `sortOrder`) and adds `productCount`
/// so the chips can show "Jasmine (3)" without a second call.
Future<Map<String, dynamic>> publicCategories(Db db) async {
  final docs = await db
      .collection('categories')
      .find(where.sortBy('sortOrder'))
      .toList();
  final counts = await _productCounts(db);
  final items = docs.map((doc) {
    final name = doc['name'] as String? ?? '';
    return <String, dynamic>{
      ...rawDocView(doc),
      'productCount': counts[name] ?? 0,
    };
  }).toList();
  return <String, dynamic>{'items': items, 'count': items.length};
}

/// Screen 44's list: every category with its product count.
Future<Map<String, dynamic>> adminCategories(Db db) async {
  final docs = await db
      .collection('categories')
      .find(where.sortBy('sortOrder'))
      .toList();
  final counts = await _productCounts(db);
  final items = docs.map((doc) {
    final name = doc['name'] as String? ?? '';
    return <String, dynamic>{
      'id': (doc['_id'] as ObjectId).oid,
      'name': name,
      'sortOrder': doc['sortOrder'] ?? 0,
      'productCount': counts[name] ?? 0,
    };
  }).toList();
  return <String, dynamic>{
    'items': items,
    'total': items.length,
    'productTotal': counts.values.fold<int>(0, (sum, n) => sum + n),
  };
}

/// Refuses a name another category already uses, ignoring letter case, because
/// "Jasmine" and "jasmine" would split the shop in two.
Future<void> _ensureNameFree(Db db, String name, {ObjectId? except}) async {
  final clash = await db
      .collection('categories')
      .findOne(
        where.match('name', '^${RegExp.escape(name)}\$', caseInsensitive: true),
      );
  if (clash != null && (except == null || clash['_id'] != except)) {
    throw const ApiError(409, 'A category with this name already exists');
  }
}

/// Screen 44's "Add category".
Future<Map<String, dynamic>> createCategory(Db db, Object? body) async {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }
  final name = cleanCategoryName(body['name']);
  await _ensureNameFree(db, name);

  final last = await db
      .collection('categories')
      .find(where.sortBy('sortOrder', descending: true))
      .toList();
  final nextOrder = last.isEmpty
      ? 1
      : ((last.first['sortOrder'] as num?)?.toInt() ?? 0) + 1;

  final id = ObjectId();
  await db.collection('categories').insertOne(<String, dynamic>{
    '_id': id,
    'name': name,
    'sortOrder': nextOrder,
    'createdAt': DateTime.now().toUtc(),
  });
  return <String, dynamic>{
    'id': id.oid,
    'name': name,
    'sortOrder': nextOrder,
    'productCount': 0,
  };
}

/// Screen 44's "Save" after editing a name. Renaming also rewrites the
/// category string on every product, otherwise those products would point at a
/// category that no longer exists.
Future<Map<String, dynamic>> renameCategory(
  Db db,
  String rawId,
  Object? body,
) async {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }
  final id = parseCategoryId(rawId);
  final name = cleanCategoryName(body['name']);
  final categories = db.collection('categories');
  final category = await categories.findOne(where.id(id));
  if (category == null) throw const ApiError(404, 'Category not found');

  final oldName = category['name'] as String? ?? '';
  if (oldName == name) {
    final counts = await _productCounts(db);
    return <String, dynamic>{
      'id': id.oid,
      'name': name,
      'sortOrder': category['sortOrder'] ?? 0,
      'productCount': counts[name] ?? 0,
    };
  }
  await _ensureNameFree(db, name, except: id);

  await categories.updateOne(
    where.id(id),
    modify.set('name', name).set('updatedAt', DateTime.now().toUtc()),
  );
  await db
      .collection('products')
      .updateMany(where.eq('category', oldName), modify.set('category', name));

  final counts = await _productCounts(db);
  return <String, dynamic>{
    'id': id.oid,
    'name': name,
    'sortOrder': category['sortOrder'] ?? 0,
    'productCount': counts[name] ?? 0,
    'renamedFrom': oldName,
  };
}

/// Screen 44's Delete. It is refused while products still use the category,
/// because deleting it would leave those products with a category the shop
/// screens cannot show.
Future<Map<String, dynamic>> deleteCategory(Db db, String rawId) async {
  final id = parseCategoryId(rawId);
  final categories = db.collection('categories');
  final category = await categories.findOne(where.id(id));
  if (category == null) throw const ApiError(404, 'Category not found');

  final name = category['name'] as String? ?? '';
  final products = db.collection('products');
  final used = await products.count(where.eq('category', name));
  if (used > 0) {
    throw ApiError(
      409,
      'Move the $used product${used == 1 ? '' : 's'} in "$name" first',
    );
  }
  await categories.deleteOne(where.id(id));
  return adminCategories(db);
}

/// The side panel on screen 44: the category and the products inside it, so
/// the admin can see what a rename or a delete would touch.
Future<Map<String, dynamic>> categoryDetail(Db db, String rawId) async {
  final id = parseCategoryId(rawId);
  final category = await db.collection('categories').findOne(where.id(id));
  if (category == null) throw const ApiError(404, 'Category not found');

  final name = category['name'] as String? ?? '';
  final docs = await db
      .collection('products')
      .find(where.eq('category', name).sortBy('name'))
      .toList();
  return <String, dynamic>{
    'id': id.oid,
    'name': name,
    'sortOrder': category['sortOrder'] ?? 0,
    'productCount': docs.length,
    'items': docs.map((doc) {
      return <String, dynamic>{
        'id': (doc['_id'] as ObjectId).oid,
        'name': doc['name'],
        'pricePerKg': doc['pricePerKg'],
        'stock': (doc['stock'] as num?)?.toInt() ?? 0,
      };
    }).toList(),
  };
}
