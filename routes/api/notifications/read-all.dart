// WHY: Screen 31 has one "Mark all as read" button in the header.
// Where it sits in the flow: authGuard has already run; the answer is the new
// unread count, always zero, so the app can redraw the bell without asking.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/notification_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Marks every notification of this buyer read.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.patch) {
    return Response(statusCode: 405);
  }

  final user = context.read<Map<String, dynamic>>();
  final result = await markAllNotificationsRead(
    context.read<Db>(),
    user['_id'] as ObjectId,
  );
  return Response.json(body: result);
}
