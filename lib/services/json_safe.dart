// WHY: A Mongo document can hold a DateTime, and a DateTime cannot be turned
// into JSON, so returning a raw document (which the public product and
// category routes do, to keep the shape chunk 1 shipped) would answer 500 as
// soon as a document has `createdAt`. This turns dates into ISO strings and
// leaves everything else alone, so the shape stays the same but is sendable.
// It has to walk lists and nested maps too: `restockHistory` is a list of
// {stock, at} maps, and a date inside a list is just as unsendable as a
// top-level one.
// Where it sits in the flow: routes/api/products/* and the public category
// list wrap their documents with jsonSafe before Response.json.

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
