// The buyer's own profile: read it, edit it.
// Collections: users

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/validators.dart';
import 'package:mongo_dart/mongo_dart.dart';

class CleanProfile {
  const CleanProfile({
    required this.name,
    required this.phone,
    required this.email,
  });
  final String name;
  final String? phone;
  final String? email;
}

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

Map<String, dynamic> profileView(Map<String, dynamic> user) {
  final createdAt = user['createdAt'];
  return <String, dynamic>{
    'id': (user['_id'] as ObjectId).oid,
    'name': user['name'],
    if (user['email'] != null) 'email': user['email'],
    if (user['phone'] != null) 'phone': user['phone'],

    'customerType': user['customerType'] ?? 'household',
    if (createdAt is DateTime) 'createdAt': createdAt.toIso8601String(),
  };
}

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

Future<Map<String, dynamic>> updateProfile(
  Db db,
  ObjectId userId,
  Object? body,
) async {
  final clean = cleanProfileInput(body);

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
