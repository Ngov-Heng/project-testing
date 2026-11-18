// JWT sign and verify. The secret comes from JWT_SECRET.

import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

String get _secret =>
    // Change the secret and every token we ever issued stops working.
    Platform.environment['JWT_SECRET'] ?? 'dev-only-secret-change-me';

String createToken(String userId) {
  return JWT({'sub': userId}).sign(
    SecretKey(_secret),
    expiresIn: const Duration(days: 7),
  );
}

String? verifyToken(String token) {
  try {
    final jwt = JWT.verify(token, SecretKey(_secret));
    final payload = jwt.payload;
    if (payload is Map<String, dynamic>) return payload['sub'] as String?;
    return null;
  } catch (_) {
    return null;
  }
}
