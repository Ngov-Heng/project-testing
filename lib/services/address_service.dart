import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/validators.dart';
import 'package:mongo_dart/mongo_dart.dart';

/*
Takes raw, untrusted JSON sent from the mobile app, checks every field (label, phone format, lat/lng limits, string lengths), throws a 400 ApiError if anything is wrong, and returns a strongly-typed, safe CleanAddress object.
*/

/// The labels screen 19 offers, stored lowercase. The app capitalises them.
const addressLabels = ['home', 'work', 'other'];

/// How many addresses one buyer may save.
const maxAddressesPerUser = 10;

/// An address that passed every check, ready to store.
class CleanAddress {
  /// Creates a checked address.
  const CleanAddress({
    required this.label,
    required this.receiverName,
    required this.phone,
    required this.street,
    required this.town,
    required this.lat,
    required this.lng,
    required this.isDefault,
  });

  /// home, work or other.
  final String label;

  /// Who receives the delivery.
  final String receiverName;

  /// Phone with spaces, dashes and dots removed.
  final String phone;

  /// House number and street.
  final String street;

  /// Town or city (free text, the app owns the dropdown list).
  final String town;

  /// Latitude of the map pin, null when the app sent none.
  final double? lat;

  /// Longitude of the map pin, null when the app sent none.
  final double? lng;

  /// True when this address should become the buyer's default.
  final bool isDefault;
}

/// Reads a required string field, trimmed, and refuses a missing or too long
/// value with a 400 that names the field.
String _requiredText(Object? value, String field, int maxLength) {
  if (value is! String || value.trim().isEmpty) {
    throw ApiError(400, '$field is required');
  }
  final trimmed = value.trim();
  if (trimmed.length > maxLength) {
    throw ApiError(400, '$field must be $maxLength characters or less');
  }
  return trimmed;
}

/// Reads an optional map coordinate. A missing value is allowed (the app may
/// not have a pin yet); a wrong one is refused.
double? _coordinate(Object? value, String field, num limit) {
  if (value == null) return null;
  if (value is! num) {
    throw ApiError(400, '$field must be a number');
  }
  if (value < -limit || value > limit) {
    throw ApiError(400, '$field must be between -$limit and $limit');
  }
  return value.toDouble();
}

/// Checks the body sent by screen 19 and returns the clean address.
/// Throws ApiError(400) naming the field that is wrong.
CleanAddress cleanAddressInput(Object? body) {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }

  final rawLabel = body['label'];
  if (rawLabel is! String || rawLabel.trim().isEmpty) {
    throw const ApiError(400, 'label is required');
  }
  final label = rawLabel.trim().toLowerCase();
  if (!addressLabels.contains(label)) {
    throw const ApiError(400, 'label must be home, work or other');
  }

  final receiverName = _requiredText(body['receiverName'], 'receiverName', 80);

  final rawPhone = body['phone'];
  if (rawPhone is! String || rawPhone.trim().isEmpty) {
    throw const ApiError(400, 'phone is required');
  }
  final phone = normalizePhone(rawPhone.trim());
  if (!isValidPhone(phone)) {
    throw const ApiError(400, 'phone is not valid');
  }

  final street = _requiredText(body['street'], 'street', 120);
  final town = _requiredText(body['town'], 'town', 60);
  final lat = _coordinate(body['lat'], 'lat', 90);
  final lng = _coordinate(body['lng'], 'lng', 180);

  final rawDefault = body['isDefault'];
  if (rawDefault != null && rawDefault is! bool) {
    throw const ApiError(400, 'isDefault must be true or false');
  }

  return CleanAddress(
    label: label,
    receiverName: receiverName,
    phone: phone,
    street: street,
    town: town,
    lat: lat,
    lng: lng,
    isDefault: rawDefault == true,
  );
}

/*
Converts raw MongoDB documents into clean JSON maps for the 
app (turning _id ObjectId into a string 'id'), 
safely parses URL IDs, and provides small reusable 
helpers for sorting and resetting default flags.
*/

/// The shape the app receives for one address. One address is always one
/// object with an "id", never a raw database document.
Map<String, dynamic> addressView(Map<String, dynamic> doc) {
  final createdAt = doc['createdAt'];
  return <String, dynamic>{
    'id': (doc['_id'] as ObjectId).oid,
    'label': doc['label'],
    'receiverName': doc['receiverName'],
    'phone': doc['phone'],
    'street': doc['street'],
    'town': doc['town'],
    'lat': doc['lat'],
    'lng': doc['lng'],
    'isDefault': doc['isDefault'] == true,
    if (createdAt is DateTime) 'createdAt': createdAt.toIso8601String(),
  };
}

/// Turns the id in the URL into an ObjectId. A malformed id is answered with
/// 404, exactly like an id that belongs to somebody else.
ObjectId parseAddressId(String raw) {
  try {
    return ObjectId.fromHexString(raw.trim());
  } catch (_) {
    throw const ApiError(404, 'Address not found');
  }
}

/// Clears the default flag on all of this buyer's addresses. Called right
/// before another address becomes the default, so only one can ever be it.
Future<void> _clearDefaults(DbCollection collection, ObjectId userId) async {
  await collection.updateMany(
    where.eq('userId', userId),
    modify.set('isDefault', false),
  );
}

/// Oldest first, so the list keeps a stable order after a default changes.
int _byCreatedAt(Map<String, dynamic> a, Map<String, dynamic> b) {
  final aAt = a['createdAt'] as DateTime?;
  final bAt = b['createdAt'] as DateTime?;
  if (aAt == null || bAt == null) return 0;
  return aAt.compareTo(bAt);
}

/// Screen 18: this buyer's addresses, the default one first.
Future<List<Map<String, dynamic>>> listAddresses(
  Db db,
  ObjectId userId,
) async {
  final docs = await db
      .collection('addresses')
      .find(where.eq('userId', userId))
      .toList();
  docs
    ..sort(_byCreatedAt)
    ..sort((a, b) {
      final aDefault = a['isDefault'] == true ? 0 : 1;
      final bDefault = b['isDefault'] == true ? 0 : 1;
      return aDefault.compareTo(bDefault);
    });
  return [for (final doc in docs) addressView(doc)];
}

/// Adds an address. The first address a buyer saves becomes the default, so
/// checkout always has one to show.
Future<Map<String, dynamic>> createAddress(
  Db db,
  ObjectId userId,
  CleanAddress clean,
) async {
  final collection = db.collection('addresses');
  final count = await collection.count(where.eq('userId', userId));
  if (count >= maxAddressesPerUser) {
    throw const ApiError(
      400,
      'You can save at most $maxAddressesPerUser addresses',
    );
  }

  final makeDefault = clean.isDefault || count == 0;
  if (makeDefault) await _clearDefaults(collection, userId);

  final doc = <String, dynamic>{
    '_id': ObjectId(),
    'userId': userId,
    'label': clean.label,
    'receiverName': clean.receiverName,
    'phone': clean.phone,
    'street': clean.street,
    'town': clean.town,
    'lat': clean.lat,
    'lng': clean.lng,
    'isDefault': makeDefault,
    'createdAt': DateTime.now().toUtc(),
  };
  await collection.insertOne(doc);
  return addressView(doc);
}

/// Replaces the editable fields of one address.
/// The default flag can only move by making *another* address the default, so
/// an update that says "not default" on the current default keeps it default -
/// otherwise the buyer could end up with no default at all.
Future<Map<String, dynamic>> updateAddress(
  Db db,
  ObjectId userId,
  ObjectId addressId,
  CleanAddress clean,
) async {
  final collection = db.collection('addresses');
  final existing = await collection.findOne(
    where.eq('userId', userId).eq('_id', addressId),
  );
  if (existing == null) throw const ApiError(404, 'Address not found');

  final wasDefault = existing['isDefault'] == true;
  if (clean.isDefault) await _clearDefaults(collection, userId);

  final doc = <String, dynamic>{
    ...existing,
    'label': clean.label,
    'receiverName': clean.receiverName,
    'phone': clean.phone,
    'street': clean.street,
    'town': clean.town,
    'lat': clean.lat,
    'lng': clean.lng,
    'isDefault': clean.isDefault || wasDefault,
    'updatedAt': DateTime.now().toUtc(),
  };
  await collection.replaceOne(
    where.eq('userId', userId).eq('_id', addressId),
    doc,
  );
  return addressView(doc);
}

/// Deletes one address and returns the remaining list.
///
/// If the default was deleted, the oldest remaining address is promoted, so
/// there is always exactly one default while the buyer has any address.
Future<List<Map<String, dynamic>>> deleteAddress(
  Db db,
  ObjectId userId,
  ObjectId addressId,
) async {
  final collection = db.collection('addresses');
  final existing = await collection.findOne(
    where.eq('userId', userId).eq('_id', addressId),
  );
  if (existing == null) throw const ApiError(404, 'Address not found');

  await collection.deleteOne(where.eq('userId', userId).eq('_id', addressId));

  if (existing['isDefault'] == true) {
    final rest = await collection.find(where.eq('userId', userId)).toList();
    if (rest.isNotEmpty) {
      rest.sort(_byCreatedAt);
      await collection.updateOne(
        where.id(rest.first['_id'] as ObjectId),
        modify.set('isDefault', true),
      );
    }
  }

  return listAddresses(db, userId);
}
