/*
Manages reading and updating a buyer's own profile (full name, phone number,
and email) in the "users" collection. Validates contact formats, ensures
a buyer keeps at least one login method (phone or email), and prevents
duplicate phone numbers or emails across accounts.
*/

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/validators.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// A profile that passed every check, ready to store.
class CleanProfile {
  /// Creates a checked profile.
  const CleanProfile({
    required this.name,
    required this.phone,
    required this.email,
  });

  /// The buyer's full name.
  final String name;

  /// Phone, or null when the buyer cleared the field.
  final String? phone;

  /// Email, or null when the buyer cleared the field.
  final String? email;
}

/// Reads an optional phone field. An empty string means "remove my phone".
String? _optionalPhone(Object? value) {
  if (value == null) return null;
  if (value is! String) {
    throw const ApiError(400, 'phone must be a string');
  }
  if (value.trim().isEmpty) return null;
  final phone = normalizePhone(value.trim());
  if (!isValidPhone(phone)) {
    throw const ApiError(400, 'phone is not valid');
  }
  return phone;
}

/// Reads an optional email field. An empty string means "remove my email".
String? _optionalEmail(Object? value) {
  if (value == null) return null;
  if (value is! String) {
    throw const ApiError(400, 'email must be a string');
  }
  if (value.trim().isEmpty) return null;
  final email = normalizeEmail(value);
  if (!isValidEmail(email)) {
    throw const ApiError(400, 'email is not valid');
  }
  return email;
}

/// Checks the body sent by screen 32.
///
/// The screen shows all three fields and saves them together, so this is a
/// full replace: a phone or email that is missing from the body is removed.
CleanProfile cleanProfileInput(Object? body) {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }

  final rawName = body['name'];
  if (rawName is! String || rawName.trim().isEmpty) {
    throw const ApiError(400, 'name is required');
  }
  final name = rawName.trim();
  if (name.length > 80) {
    throw const ApiError(400, 'name must be 80 characters or less');
  }

  return CleanProfile(
    name: name,
    phone: _optionalPhone(body['phone']),
    email: _optionalEmail(body['email']),
  );
}

/// The shape the app receives for the logged in buyer (screens 08 and 32).
Map<String, dynamic> profileView(Map<String, dynamic> user) {
  final createdAt = user['createdAt'];
  return <String, dynamic>{
    'id': (user['_id'] as ObjectId).oid,
    'name': user['name'],
    if (user['email'] != null) 'email': user['email'],
    if (user['phone'] != null) 'phone': user['phone'],
    // Accounts created before customerType existed count as household.
    'customerType': user['customerType'] ?? 'household',
    if (createdAt is DateTime) 'createdAt': createdAt.toIso8601String(),
  };
}

/// Refuses a phone or an email that another account already uses.
Future<void> _checkUnique(
  Db db,
  ObjectId userId,
  CleanProfile clean,
) async {
  final users = db.collection('users');
  if (clean.phone != null) {
    final clash = await users.findOne(
      where.eq('phone', clean.phone).ne('_id', userId),
    );
    if (clash != null) {
      throw const ApiError(409, 'That phone number is used by another account');
    }
  }
  if (clean.email != null) {
    final clash = await users.findOne(
      where.eq('email', clean.email).ne('_id', userId),
    );
    if (clash != null) {
      throw const ApiError(409, 'That email is used by another account');
    }
  }
}

/// Saves the profile of the logged in buyer and returns the new profile.
Future<Map<String, dynamic>> updateProfile(
  Db db,
  ObjectId userId,
  Object? body,
) async {
  final clean = cleanProfileInput(body);

  // Sign up needs an email or a phone, so the account must keep at least one
  // way to log in and to be contacted.
  if (clean.phone == null && clean.email == null) {
    throw const ApiError(400, 'Keep a phone number or an email address');
  }

  await _checkUnique(db, userId, clean);

  final update = modify.set('name', clean.name);
  if (clean.phone == null) {
    update.unset('phone');
  } else {
    update.set('phone', clean.phone);
  }
  if (clean.email == null) {
    update.unset('email');
  } else {
    update.set('email', clean.email);
  }

  final users = db.collection('users');
  await users.updateOne(where.id(userId), update);

  final refreshed = await users.findOne(where.id(userId));
  if (refreshed == null) throw const ApiError(404, 'User not found');
  return profileView(refreshed);
}
