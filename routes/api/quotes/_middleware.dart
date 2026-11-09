// WHY: A quote request is private to the buyer who sent it, so every route in
// this folder needs a logged in user.
// Where it sits in the flow: authGuard runs first and puts the user document in
// the request context; the services below take the buyer id from there.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/middleware/auth_guard.dart';

/// Wraps every route file in this folder and its subfolders.
Handler middleware(Handler handler) => authGuard(handler);
