import 'dart:io';

import 'package:mongo_dart/mongo_dart.dart';

class SeedProduct {
  const SeedProduct(
    this.name,
    this.category,
    this.pricePerKg,
    this.stock,
    this.description, {
    this.isFeatured = false,
    this.image = 'rice_bag',
  });
  final String name;
  final String category;
  final double pricePerKg;
  final int stock;
  final String description;
  final bool isFeatured;
  final String image;
}

const List<String> seedCategories = <String>[
  'Jasmine',
  'Sticky',
  'Brown',
  'Bulk',
];

const List<SeedProduct> seedProducts = <SeedProduct>[
  SeedProduct(
    'Jasmine rice',
    'Jasmine',
    1.48,
    1240,
    'Fragrant jasmine rice from Battambang, milled this week.',
    isFeatured: true,
  ),
  SeedProduct(
    'Premium jasmine rice',
    'Jasmine',
    1.72,
    860,
    'Hand-sorted jasmine rice, the longest grains in the shop.',
  ),
  SeedProduct(
    'Organic jasmine rice',
    'Jasmine',
    2.20,
    180,
    'Grown without chemicals on a small farm near Kampot.',
  ),
  SeedProduct(
    'Sticky rice',
    'Sticky',
    1.92,
    640,
    'Glutinous rice for desserts and bamboo tubes.',
    isFeatured: true,
  ),
  SeedProduct(
    'Black sticky rice',
    'Sticky',
    2.30,
    6000,
    'Deep purple sticky rice, sold by the kilogram.',
  ),
  SeedProduct(
    'Sweet sticky rice pack',
    'Sticky',
    2.05,
    420,
    'Ready-soaked sticky rice in a 5 kg pack.',
  ),
  SeedProduct(
    'Brown rice',
    'Brown',
    1.60,
    310,
    'Whole grain brown rice with the bran left on.',
    isFeatured: true,
  ),
  SeedProduct(
    'Red rice',
    'Brown',
    2.10,
    95,
    'Red cargo rice, nutty and slow to cook.',
  ),
  SeedProduct(
    'Organic brown rice',
    'Brown',
    2.40,
    15,
    'Naturally grown black rice from Battambang.',
  ),
  SeedProduct(
    'Bulk jasmine sack 25 kg',
    'Bulk',
    1.35,
    900,
    'Restaurant sack of jasmine rice, 25 kg.',
  ),
  SeedProduct(
    'Bulk sticky sack 25 kg',
    'Bulk',
    1.78,
    520,
    'Restaurant sack of sticky rice, 25 kg.',
  ),
  SeedProduct(
    'Bulk brown sack 25 kg',
    'Bulk',
    1.45,
    640,
    'Restaurant sack of brown rice, 25 kg.',
  ),
];

Future<void> main() async {
  final url =
      Platform.environment['MONGO_URL'] ??
      'mongodb://localhost:27018/faheng_dev';
  final db = await Db.create(url);
  await db.open();
  stdout.writeln('seeding $url');
  final categories = db.collection('categories');
  var order = 1;
  var addedCategories = 0;
  for (final name in seedCategories) {
    final found = await categories.findOne(where.eq('name', name));
    if (found == null) {
      await categories.insertOne(<String, dynamic>{
        '_id': ObjectId(),
        'name': name,
        'sortOrder': order,
        'createdAt': DateTime.now().toUtc(),
      });
      addedCategories++;
      stdout.writeln('  + category $name');
    }
    order++;
  }

  final products = db.collection('products');
  var addedProducts = 0;
  for (final product in seedProducts) {
    final found = await products.findOne(where.eq('name', product.name));
    if (found != null) continue;
    await products.insertOne(<String, dynamic>{
      '_id': ObjectId(),
      'name': product.name,
      'category': product.category,
      'pricePerKg': product.pricePerKg,
      'stock': product.stock,
      'description': product.description,
      'image': product.image,
      'isActive': true,
      'isFeatured': product.isFeatured,
      'createdAt': DateTime.now().toUtc(),
    });
    addedProducts++;
    stdout.writeln(
      '  + ${product.name} (${product.category}, '
      '${product.stock} kg)',
    );
  }

  final all = await products.find().toList();
  final totalKg = all.fold<int>(
    0,
    (sum, doc) => sum + ((doc['stock'] as num?)?.toInt() ?? 0),
  );
  final low = all
      .where((doc) => ((doc['stock'] as num?)?.toInt() ?? 0) < 100)
      .length;
  stdout.writeln(
    'done: $addedCategories categories and $addedProducts products added. '
    'Now ${all.length} products, $totalKg kg in stock, $low under 100 kg.',
  );
  await db.close();
}
