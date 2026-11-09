// WHY: A Mongo document can hold a DateTime, and a DateTime cannot be turned
// into JSON, so returning a raw document (which the public product and
// category routes do, to keep the shape chunk 1 shipped) would answer 500 as
// soon as a document has `createdAt`. This turns dates into ISO strings and
// leaves everything else alone, so the shape stays the same but is sendable.
// Where it sits in the flow: routes/api/products/* and the public category
// list wrap their documents with jsonSafe before Response.json.

import 'package:mongo_dart/mongo_dart.dart';

/// Copies [doc] with every DateTime replaced by an ISO 8601 string.
Map<String, dynamic> jsonSafe(Map<String, dynamic> doc) {
  return doc.map((key, value) {
    if (value is DateTime) return MapEntry(key, value.toIso8601String());
    return MapEntry(key, value);
  });
}

/// A product as the Flutter app already receives it: `_id` as a hex string,
/// dollars in `pricePerKg`, dates as strings.
Map<String, dynamic> rawDocView(Map<String, dynamic> doc) {
  return <String, dynamic>{
    ...jsonSafe(doc),
    '_id': (doc['_id'] as ObjectId).oid,
  };
}
