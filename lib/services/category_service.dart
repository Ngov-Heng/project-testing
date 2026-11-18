// Categories, plus a product count for each one.
// Collections: categories, products

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/json_safe.dart';
import 'package:mongo_dart/mongo_dart.dart';

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

ObjectId parseCategoryId(String raw) {
  try {
    return ObjectId.fromHexString(raw);
  } catch (_) {
    throw const ApiError(404, 'Category not found');
  }
}

Future<Map<String, int>> _productCounts(Db db) async {
  final docs = await db.collection('products').find().toList();
  final counts = <String, int>{};
  for (final doc in docs) {
    final name = doc['category'];
    if (name is String) counts[name] = (counts[name] ?? 0) + 1;
  }
  return counts;
}

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
