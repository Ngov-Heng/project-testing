// Opens the Mongo connection once and hands it to every route through
// context.

import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mongo_dart/mongo_dart.dart';

Db? _db;

Future<Db> _getDb() async {
  // Reused while it is still connected. A dropped connection reopens
  // on the next request instead of crashing the server.
  final existing = _db;
  if (existing != null && existing.isConnected) return existing;

  final url =
      Platform.environment['MONGO_URL'] ??
      'mongodb://localhost:27018/faheng_dev';
  final db = await Db.create(url);
  await db.open();
  _db = db;
  return db;
}

Handler middleware(Handler handler) {
  return (context) async {
    final db = await _getDb();
    return handler.use(provider<Db>((_) => db)).call(context);
  };
}
