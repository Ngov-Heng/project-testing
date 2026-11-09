// WHY: Notifications belong to one buyer, so the whole folder needs a login.
// Where it sits in the flow: authGuard runs first; every service below takes
// the buyer id out of the request context.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/middleware/auth_guard.dart';

/// Wraps every route file in this folder and its subfolders.
Handler middleware(Handler handler) => authGuard(handler);
