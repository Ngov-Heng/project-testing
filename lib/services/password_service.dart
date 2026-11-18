// Password hashing, kept in one place so nobody hand-rolls it elsewhere.

import 'package:bcrypt/bcrypt.dart';

String hashPassword(String password) {
  return BCrypt.hashpw(password, BCrypt.gensalt());
}

bool verifyPassword(String password, String hashed) {
  return BCrypt.checkpw(password, hashed);
}
