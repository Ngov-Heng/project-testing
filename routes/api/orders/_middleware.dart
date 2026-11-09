// WHY: Orders are private to the buyer who placed them, so every route in
// this folder needs a logged in user. Putting the guard here means a new
// order route can never be written without it.
// Where it sits in the flow: a request to /api/orders/... runs authGuard
// (Bearer token -> user document in the request context) before the route.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/middleware/auth_guard.dart';

/// Wraps every route file in this folder and its subfolders.
Handler middleware(Handler handler) => authGuard(handler);
