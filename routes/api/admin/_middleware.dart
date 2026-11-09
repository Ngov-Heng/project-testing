// WHY: Every route under /api/admin must be owner-only. Putting the guard here
// means each admin route file stays a plain handler and none can be forgotten.
// Where it sits in the flow: a request to /api/admin/... runs adminGuard,
// which runs authGuard (token -> user) and then checks role == "admin".

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/middleware/admin_guard.dart';

/// Wraps every route file in this folder and its subfolders.
Handler middleware(Handler handler) => adminGuard(handler);
