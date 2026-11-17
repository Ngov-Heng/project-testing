// WHY: Chunk 5 is the account life cycle: sign up (screen 09), the 6-digit
// code (10), forgot password (11), the new password (12), change password
// (34) and the login rules the buyer app (01) and the admin site (36) need.
// All of it is one story - "prove this account belongs to you" - so the rules
// live in one file and the routes above them stay thin.
// Where it sits in the flow: routes/api/auth/*.dart and
// routes/api/users/me/password.dart call these functions. Only the "users"
// collection is touched; a pending code is stored on the user document itself,
// so there is no second collection to keep in step.

import 'dart:math';

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/password_service.dart';
import 'package:faheng_api/services/token_service.dart';
import 'package:faheng_api/services/validators.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Screen 10 shows six little boxes, so a code is six digits.
const int codeLength = 6;

/// How long a code stays usable. Ten minutes is the usual wording on such
/// screens and long enough to type six digits.
const Duration codeLifetime = Duration(minutes: 10);

/// Screen 10 shows "Resend code in 0:42", so a new code cannot be asked for
/// more often than once a minute.
const Duration resendCooldown = Duration(seconds: 60);

/// A code may be typed wrong five times before it is thrown away, so a bot
/// cannot try all one million numbers.
const int maxCodeAttempts = 5;

/// The two jobs a code can do. One code can never do both: a sign-up code
/// cannot reset a password and a reset code cannot verify a new account.
const String signupPurpose = 'signup';

/// Marks a code that was asked for by "forgot password".
const String resetPurpose = 'reset';

/// The two values screen 09 offers under "I'm buying for".
const List<String> customerTypes = <String>['household', 'business'];

/// Builds a fresh 6-digit code, keeping the leading zero if there is one.
String generateCode([Random? random]) {
  final rng = random ?? Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < codeLength; i++) {
    buffer.write(rng.nextInt(10));
  }
  return buffer.toString();
}

/// Reads the "email or phone number" field that screens 01, 09, 10, 11 and 12
/// all share and turns it into the query that finds the account.
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

/// Reads the identifier from a request body and says which field it is.
String cleanIdentifier(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const ApiError(400, 'identifier is required');
  }
  return value.trim();
}

/// Reads the six digits screen 10 sends.
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

/// Reads "I'm buying for" from screen 09. Household is the pre-selected
/// option, so a missing field counts as household.
String cleanCustomerType(Object? value) {
  if (value == null) return 'household';
  final text = value is String ? value.trim().toLowerCase() : '';
  if (!customerTypes.contains(text)) {
    throw const ApiError(400, 'customerType must be household or business');
  }
  return text;
}

/// Reads a new password from screens 12 and 34. Eight characters is printed
/// under both fields ("At least 8 characters").
String cleanNewPassword(Object? value) {
  if (value is! String || value.isEmpty) {
    throw const ApiError(400, 'password is required');
  }
  if (value.length < 8) {
    throw const ApiError(400, 'password must be at least 8 characters');
  }
  return value;
}

/// Screen 12 says "Your new password must be different from your old one",
/// and screen 34 has the same rule. [hash] is what is stored today.
void ensurePasswordChanged(String newPassword, String hash) {
  if (verifyPassword(newPassword, hash)) {
    throw const ApiError(
      400,
      'New password must be different from your old one',
    );
  }
}

/// The document stored under "verification" on the user while a code is
/// waiting to be typed. [nowUtc] is passed in so a test can freeze time.
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

/// How many seconds are left before screen 10's "Resend code" link works.
/// Zero means the buyer may ask for a new code right now.
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

/// Checks a typed code against what is stored on the user. It throws the
/// reason the buyer will read on screen 10 instead of returning a bool, so
/// every route reports the same sentence.
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

/// The user object login sends back. `role` is what the admin site (36) reads
/// to know whether to let somebody in, and `isVerified` mirrors screen 01's
/// "verify your account" rule.
Map<String, dynamic> authUserView(Map<String, dynamic> user) {
  return <String, dynamic>{
    'id': (user['_id'] as ObjectId).oid,
    'name': user['name'],
    if (user['email'] != null) 'email': user['email'],
    if (user['phone'] != null) 'phone': user['phone'],
    // Accounts made before roles existed are ordinary buyers.
    'role': user['role'] ?? 'buyer',
    'customerType': user['customerType'] ?? 'household',
    // Accounts made before verification existed are treated as verified,
    // otherwise the whole shop would be locked out after the upgrade.
    'isVerified': user['isVerified'] != false,
  };
}

/// Finds the account behind an identifier, or says it does not exist.
Future<Map<String, dynamic>> _requireUser(Db db, String identifier) async {
  final query = identifierQuery(identifier);
  final user = await db.collection('users').findOne(query);
  if (user == null) {
    throw const ApiError(404, 'Account not found');
  }
  return user;
}

/// The body screen 09 sends, checked. Password hashing stays in the route so
/// this class only describes data.
class CleanSignup {
  /// Creates a checked sign-up when every field passed its rule.
  const CleanSignup({
    required this.name,
    required this.password,
    required this.customerType,
    this.email,
    this.phone,
  });

  /// Full name, as typed on screen 09.
  final String name;

  /// The raw password; it is hashed once, in [registerAccount].
  final String password;

  /// household or business.
  final String customerType;

  /// Email, or null when the buyer signed up with a phone number.
  final String? email;

  /// Phone, or null when the buyer signed up with an email.
  final String? phone;
}

/// Reads screen 09's four fields.
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

/// Creates the account for screen 09 and sends the first code for screen 10.
///
/// The account starts `isVerified: false` and no token is handed out, because
/// the rule for this chunk is: verify first, log in after.
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

/// The small object every "we sent you a code" answer carries. The code itself
/// is echoed as `devCode` because this project has no SMS or email provider
/// yet; a real sender would drop that field and only print to the console.
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

/// Screen 01 and 36 both post here. Rules: the password must match, and an
/// account that never typed its code cannot get in (403), which is the only
/// reason screen 10 exists.
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

/// Screen 10's Verify button. On success the account is marked verified, the
/// code is thrown away and a token is returned so the app can go straight in.
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

/// Runs [checkVerification] and, when the code itself was wrong, counts that
/// try on the user document before passing the message on. Both screen 10 and
/// screen 12 go through here so the five-try limit works the same way.
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

/// Counts a wrong guess so the code dies after [maxCodeAttempts] tries.
Future<void> recordWrongCode(Db db, Map<String, dynamic> user) async {
  await db
      .collection('users')
      .updateOne(
        where.eq('_id', user['_id']),
        modify.inc('verification.attempts', 1),
      );
}

/// Screen 10's "Resend code in 0:42" link.
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

/// Screen 11's "Send code" button for a forgotten password.
///
/// The answer is the same sentence for a known and an unknown identifier, so
/// the endpoint cannot be used to find out who shops here. The dev code is
/// only present when the account exists, which is the one dev-only giveaway.
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

/// Screen 12. A reset code proves the buyer owns the phone or email, so the
/// account also becomes verified at this moment - otherwise somebody who
/// never finished screen 10 could reset and still not log in.
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

/// Screen 34, the logged-in buyer changing their own password. Here the old
/// password must be typed, which is different from screen 12 where the code
/// plays that part.
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
