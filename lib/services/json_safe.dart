/*
Prepares raw MongoDB documents to be sent as JSON responses without crashing.
Recursively converts DateTime objects into ISO-8601 strings (even inside nested
lists or maps) and turns MongoDB ObjectIds into plain hex strings.
*/

import 'package:mongo_dart/mongo_dart.dart';

/// Copies [doc] with every DateTime replaced by an ISO 8601 string, at any
/// depth (maps inside lists inside maps included).
Map<String, dynamic> jsonSafe(Map<String, dynamic> doc) {
  return <String, dynamic>{
    for (final entry in doc.entries) entry.key: jsonSafeValue(entry.value),
  };
}

/// One value made JSON-sendable: dates become ISO strings, maps and lists are
/// walked, everything else (numbers, strings, ObjectId, null) is left as is.
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

/// A product as the Flutter app already receives it: `_id` as a hex string,
/// dollars in `pricePerKg`, dates as strings.
Map<String, dynamic> rawDocView(Map<String, dynamic> doc) {
  return <String, dynamic>{
    ...jsonSafe(doc),
    '_id': (doc['_id'] as ObjectId).oid,
  };
}
