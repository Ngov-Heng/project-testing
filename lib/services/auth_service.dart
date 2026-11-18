// Who you are: registration, verification codes, login, password reset.
// Collections: users

import 'dart:math';

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/password_service.dart';
import 'package:faheng_api/services/token_service.dart';
import 'package:faheng_api/services/validators.dart';
import 'package:mongo_dart/mongo_dart.dart';

const int codeLength = 6;
const Duration codeLifetime = Duration(minutes: 10);
const Duration resendCooldown = Duration(seconds: 60);
const int maxCodeAttempts = 5;
const String signupPurpose = 'signup';
const String resetPurpose = 'reset';
const List<String> customerTypes = <String>['household', 'business'];

String generateCode([Random? random]) {
  final rng = random ?? Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < codeLength; i++) {
    buffer.write(rng.nextInt(10));
  }
  return buffer.toString();
}

Map<String, dynamic> identifierQuery(String identifier) {
  final trimmed = identifier.trim();
  if (trimmed.contains('@')) {
    final email = normalizeEmail(trimmed);
    if (!isValidEmail(email)) {
      throw const ApiError(400, 'email is not valid');
    }
    return <String, dynamic>{'email': email};
  }
  final phone = normalizePhone(trimmed);
  if (!isValidPhone(phone)) {
    throw const ApiError(400, 'phone is not valid');
  }
  return <String, dynamic>{'phone': phone};
}

String cleanIdentifier(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const ApiError(400, 'identifier is required');
  }
  return value.trim();
}

String cleanCode(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const ApiError(400, 'code is required');
  }
  final code = value.trim();
  if (!RegExp('^[0-9]{$codeLength}\$').hasMatch(code)) {
    throw const ApiError(400, 'code must be 6 digits');
  }
  return code;
}

String cleanCustomerType(Object? value) {
  if (value == null) return 'household';
  final text = value is String ? value.trim().toLowerCase() : '';
  if (!customerTypes.contains(text)) {
    throw const ApiError(400, 'customerType must be household or business');
  }
  return text;
}

String cleanNewPassword(Object? value) {
  if (value is! String || value.isEmpty) {
    throw const ApiError(400, 'password is required');
  }
  if (value.length < 8) {
    throw const ApiError(400, 'password must be at least 8 characters');
  }
  return value;
}

void ensurePasswordChanged(String newPassword, String hash) {
  if (verifyPassword(newPassword, hash)) {
    throw const ApiError(
      400,
      'New password must be different from your old one',
    );
  }
}

Map<String, dynamic> verificationDoc(
  String code,
  String purpose, [
  DateTime? nowUtc,
]) {
  final now = nowUtc ?? DateTime.now().toUtc();
  return <String, dynamic>{
    'code': code,
    'purpose': purpose,
    'issuedAt': now,
    'expiresAt': now.add(codeLifetime),
    'attempts': 0,
  };
}

int resendWaitSeconds(Map<String, dynamic> user, [DateTime? nowUtc]) {
  final raw = user['verification'];
  if (raw is! Map) return 0;
  final issuedAt = raw['issuedAt'];
  if (issuedAt is! DateTime) return 0;
  final now = nowUtc ?? DateTime.now().toUtc();
  final waited = now.difference(issuedAt).inSeconds;
  final left = resendCooldown.inSeconds - waited;
  return left > 0 ? left : 0;
}

void checkVerification(
  Map<String, dynamic> user,
  String code,
  String purpose, [
  DateTime? nowUtc,
]) {
  final raw = user['verification'];
  if (raw is! Map) {
    throw const ApiError(400, 'Ask for a code first');
  }
  final doc = Map<String, dynamic>.from(raw);
  if (doc['purpose'] != purpose) {
    throw const ApiError(400, 'That code is not for this action');
  }
  final expiresAt = doc['expiresAt'];
  final now = nowUtc ?? DateTime.now().toUtc();
  if (expiresAt is! DateTime || now.isAfter(expiresAt)) {
    throw const ApiError(400, 'That code has expired. Ask for a new one');
  }
  final attempts = doc['attempts'];
  if (attempts is num && attempts >= maxCodeAttempts) {
    throw const ApiError(429, 'Too many wrong codes. Ask for a new one');
  }
  if (doc['code'] != code) {
    throw const ApiError(400, 'That code is not correct');
  }
}

Map<String, dynamic> authUserView(Map<String, dynamic> user) {
  return <String, dynamic>{
    'id': (user['_id'] as ObjectId).oid,
    'name': user['name'],
    if (user['email'] != null) 'email': user['email'],
    if (user['phone'] != null) 'phone': user['phone'],

    'role': user['role'] ?? 'buyer',
    'customerType': user['customerType'] ?? 'household',

    'isVerified': user['isVerified'] != false,
  };
}

Future<Map<String, dynamic>> _requireUser(Db db, String identifier) async {
  final query = identifierQuery(identifier);
  final user = await db.collection('users').findOne(query);
  if (user == null) {
    throw const ApiError(404, 'Account not found');
  }
  return user;
}

class CleanSignup {
  const CleanSignup({
    required this.name,
    required this.password,
    required this.customerType,
    this.email,
    this.phone,
  });
  final String name;
  final String password;
  final String customerType;
  final String? email;
  final String? phone;
}

CleanSignup cleanSignup(Object? body) {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }
  final nameRaw = body['name'];
  if (nameRaw is! String || nameRaw.trim().isEmpty) {
    throw const ApiError(400, 'name is required');
  }
  final password = cleanNewPassword(body['password']);
  final customerType = cleanCustomerType(body['customerType']);
  final emailRaw = body['email'];
  final phoneRaw = body['phone'];
  final emailText = emailRaw is String ? emailRaw.trim() : '';
  final phoneText = phoneRaw is String ? phoneRaw.trim() : '';
  if (emailText.isEmpty && phoneText.isEmpty) {
    throw const ApiError(400, 'email or phone is required');
  }

  String? email;
  if (emailText.isNotEmpty) {
    email = normalizeEmail(emailText);
    if (!isValidEmail(email)) {
      throw const ApiError(400, 'email is not valid');
    }
  }
  String? phone;
  if (phoneText.isNotEmpty) {
    phone = normalizePhone(phoneText);
    if (!isValidPhone(phone)) {
      throw const ApiError(400, 'phone is not valid');
    }
  }

  return CleanSignup(
    name: nameRaw.trim(),
    password: password,
    customerType: customerType,
    email: email,
    phone: phone,
  );
}

Future<Map<String, dynamic>> registerAccount(
  Db db,
  Object? body, [
  DateTime? nowUtc,
]) async {
  final clean = cleanSignup(body);
  final users = db.collection('users');

  final clash = await users.findOne({
    r'$or': [
      if (clean.email != null) {'email': clean.email},
      if (clean.phone != null) {'phone': clean.phone},
    ],
  });
  if (clash != null) {
    throw const ApiError(
      409,
      'An account with this email or phone already exists',
    );
  }

  final now = nowUtc ?? DateTime.now().toUtc();
  final code = generateCode();
  final id = ObjectId();
  final inserted = await users.insertOne(<String, dynamic>{
    '_id': id,
    'name': clean.name,
    if (clean.email != null) 'email': clean.email,
    if (clean.phone != null) 'phone': clean.phone,
    'passwordHash': hashPassword(clean.password),
    'customerType': clean.customerType,
    'isVerified': false,
    'verification': verificationDoc(code, signupPurpose, now),
    'createdAt': now,
  });
  if (!inserted.isSuccess) {
    throw const ApiError(
      409,
      'An account with this email or phone already exists',
    );
  }

  final user = <String, dynamic>{
    '_id': id,
    'name': clean.name,
    if (clean.email != null) 'email': clean.email,
    if (clean.phone != null) 'phone': clean.phone,
    'customerType': clean.customerType,
    'isVerified': false,
  };
  return <String, dynamic>{
    'user': authUserView(user),
    'verification': codeReply(code, user, now),
  };
}

Map<String, dynamic> codeReply(
  String code,
  Map<String, dynamic> user,
  DateTime now,
) {
  final channel = user['email'] != null ? 'email' : 'phone';
  final sentTo = user['email'] ?? user['phone'];
  return <String, dynamic>{
    'sent': true,
    'channel': channel,
    'sentTo': sentTo,
    'expiresInMinutes': codeLifetime.inMinutes,
    'resendAfterSeconds': resendCooldown.inSeconds,
    'devCode': code,
  };
}

Future<Map<String, dynamic>> loginAccount(Db db, Object? body) async {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }
  final identifier = cleanIdentifier(body['identifier']);
  final password = body['password'];
  if (password is! String || password.isEmpty) {
    throw const ApiError(400, 'password is required');
  }

  final users = db.collection('users');
  final user = await users.findOne(identifierQuery(identifier));
  if (user == null ||
      !verifyPassword(password, user['passwordHash'] as String)) {
    throw const ApiError(401, 'Invalid credentials');
  }
  if (user['isVerified'] == false) {
    throw const ApiError(403, 'Please verify your account first');
  }
  return <String, dynamic>{
    'token': createToken((user['_id'] as ObjectId).oid),
    'user': authUserView(user),
  };
}

Future<Map<String, dynamic>> verifyAccount(
  Db db,
  Object? body, [
  DateTime? nowUtc,
]) async {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }
  final user = await _requireUser(db, cleanIdentifier(body['identifier']));
  if (user['isVerified'] == true) {
    throw const ApiError(409, 'This account is already verified');
  }
  final code = cleanCode(body['code']);
  await _checkAndCount(db, user, code, signupPurpose, nowUtc);

  final updated = await db
      .collection('users')
      .updateOne(
        where.eq('_id', user['_id']),
        modify
            .set('isVerified', true)
            .set('verifiedAt', nowUtc ?? DateTime.now().toUtc())
            .unset('verification'),
      );
  if (updated.nMatched == 0) {
    throw const ApiError(404, 'Account not found');
  }
  final fresh = Map<String, dynamic>.from(user)
    ..['isVerified'] = true
    ..remove('verification');
  return <String, dynamic>{
    'token': createToken((user['_id'] as ObjectId).oid),
    'user': authUserView(fresh),
  };
}

Future<void> _checkAndCount(
  Db db,
  Map<String, dynamic> user,
  String code,
  String purpose,
  DateTime? nowUtc,
) async {
  try {
    checkVerification(user, code, purpose, nowUtc);
  } on ApiError catch (error) {
    if (error.message == 'That code is not correct') {
      await recordWrongCode(db, user);
    }
    rethrow;
  }
}

Future<void> recordWrongCode(Db db, Map<String, dynamic> user) async {
  await db
      .collection('users')
      .updateOne(
        where.eq('_id', user['_id']),
        modify.inc('verification.attempts', 1),
      );
}

Future<Map<String, dynamic>> resendSignupCode(
  Db db,
  Object? body, [
  DateTime? nowUtc,
]) async {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }
  final user = await _requireUser(db, cleanIdentifier(body['identifier']));
  if (user['isVerified'] == true) {
    throw const ApiError(409, 'This account is already verified');
  }
  final wait = resendWaitSeconds(user, nowUtc);
  if (wait > 0) {
    throw ApiError(
      429,
      'Please wait $wait seconds before asking for a new code',
    );
  }
  final now = nowUtc ?? DateTime.now().toUtc();
  final code = generateCode();
  await db
      .collection('users')
      .updateOne(
        where.eq('_id', user['_id']),
        modify.set('verification', verificationDoc(code, signupPurpose, now)),
      );
  return <String, dynamic>{
    'verification': codeReply(code, user, now),
  };
}

Future<Map<String, dynamic>> requestPasswordReset(
  Db db,
  Object? body, [
  DateTime? nowUtc,
]) async {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }
  final identifier = cleanIdentifier(body['identifier']);
  final query = identifierQuery(identifier);
  final user = await db.collection('users').findOne(query);
  final answer = <String, dynamic>{
    'sent': true,
    'message': 'If that account exists, a code has been sent.',
    'expiresInMinutes': codeLifetime.inMinutes,
    'resendAfterSeconds': resendCooldown.inSeconds,
  };
  if (user == null) return answer;
  final wait = resendWaitSeconds(user, nowUtc);
  if (wait > 0) {
    throw ApiError(
      429,
      'Please wait $wait seconds before asking for a new code',
    );
  }
  final now = nowUtc ?? DateTime.now().toUtc();
  final code = generateCode();
  await db
      .collection('users')
      .updateOne(
        where.eq('_id', user['_id']),
        modify.set('verification', verificationDoc(code, resetPurpose, now)),
      );
  return <String, dynamic>{
    ...answer,
    'verification': codeReply(code, user, now),
  };
}

Future<Map<String, dynamic>> resetPassword(
  Db db,
  Object? body, [
  DateTime? nowUtc,
]) async {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }
  final user = await _requireUser(db, cleanIdentifier(body['identifier']));
  final code = cleanCode(body['code']);
  final password = cleanNewPassword(body['password']);
  await _checkAndCount(db, user, code, resetPurpose, nowUtc);
  ensurePasswordChanged(password, user['passwordHash'] as String);

  await db
      .collection('users')
      .updateOne(
        where.eq('_id', user['_id']),
        modify
            .set('passwordHash', hashPassword(password))
            .set('isVerified', true)
            .set('passwordChangedAt', nowUtc ?? DateTime.now().toUtc())
            .unset('verification'),
      );
  return <String, dynamic>{'message': 'Password updated, please log in'};
}

Future<Map<String, dynamic>> changePassword(
  Db db,
  Map<String, dynamic> user,
  Object? body, [
  DateTime? nowUtc,
]) async {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }
  final current = body['currentPassword'];
  if (current is! String || current.isEmpty) {
    throw const ApiError(400, 'currentPassword is required');
  }
  final hash = user['passwordHash'] as String;
  if (!verifyPassword(current, hash)) {
    throw const ApiError(401, 'Current password is not correct');
  }
  final password = cleanNewPassword(body['newPassword']);
  ensurePasswordChanged(password, hash);

  await db
      .collection('users')
      .updateOne(
        where.eq('_id', user['_id']),
        modify
            .set('passwordHash', hashPassword(password))
            .set('passwordChangedAt', nowUtc ?? DateTime.now().toUtc()),
      );
  return <String, dynamic>{'message': 'Password updated'};
}
