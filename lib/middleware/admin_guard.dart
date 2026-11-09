// WHY: Admin screens (36, 37-50) may only be used by the shop owner. The
// normal authGuard only proves "somebody is logged in"; this adds the second
// check, "and that somebody has role admin".
// Where it sits in the flow: routes/api/admin/_middleware.dart applies it to
// every route under /api/admin, so a new admin route is protected the moment
// it is created. It reuses authGuard, so the token check stays in one place.
// A user with no role at all counts as a buyer, so an account created before
// roles existed can never reach admin routes.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/middleware/auth_guard.dart';
import 'package:faheng_api/services/api_error.dart';

/// Runs authGuard first, then refuses anyone whose role is not admin.
Handler adminGuard(Handler handler) {
  return authGuard((context) async {
    final user = context.read<Map<String, dynamic>>();
    if (user['role'] != 'admin') {
      return jsonError(403, 'Admin only');
    }
    return handler(context);
  });
}
