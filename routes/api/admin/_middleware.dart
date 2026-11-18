import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/middleware/admin_guard.dart';

Handler middleware(Handler handler) => adminGuard(handler);
