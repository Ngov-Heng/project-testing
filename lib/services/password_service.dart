/*
Handles password security using BCrypt: scrambles plain-text passwords into
salted one-way hashes before saving to MongoDB, and safely verifies typed
passwords against stored hashes during login and password changes.
*/
import 'package:bcrypt/bcrypt.dart';

/// Turns a typed password into a one-way hash that is safe to store.
String hashPassword(String password) {
  return BCrypt.hashpw(password, BCrypt.gensalt());
}

/// Checks a typed password against a stored hash (used at login).
bool verifyPassword(String password, String hashed) {
  return BCrypt.checkpw(password, hashed);
}
