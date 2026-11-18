// The admin door. It runs authGuard first, then checks the role.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/middleware/auth_guard.dart';
import 'package:faheng_api/services/api_error.dart';

Handler adminGuard(Handler handler) {
  return authGuard((context) async {
    final user = context.read<Map<String, dynamic>>();
    // Order matters: no token is a 401 here, a buyer token is the 403 below.
    if (user['role'] != 'admin') {
      return jsonError(403, 'Admin only');
    }
    return handler(context);
  });
}
