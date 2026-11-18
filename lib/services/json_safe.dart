// Turns Mongo documents into something jsonEncode accepts: dates become ISO
// strings.

import 'package:mongo_dart/mongo_dart.dart';

Map<String, dynamic> jsonSafe(Map<String, dynamic> doc) {
  return <String, dynamic>{
    for (final entry in doc.entries) entry.key: jsonSafeValue(entry.value),
  };
}

// Walks lists and nested maps, not just the top level: a date
// inside a list breaks jsonEncode. restockHistory has both.
Object? jsonSafeValue(Object? value) {
  if (value is DateTime) return value.toIso8601String();
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        '${entry.key}': jsonSafeValue(entry.value),
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) jsonSafeValue(item)];
  }
  return value;
}

Map<String, dynamic> rawDocView(Map<String, dynamic> doc) {
  return <String, dynamic>{
    ...jsonSafe(doc),
    '_id': (doc['_id'] as ObjectId).oid,
  };
}
