// WHY: The bell on Home only needs a number, so it must not download the list.
// Where it sits in the flow: authGuard has already run.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/notification_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Returns how many notifications are still unread.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }

  final user = context.read<Map<String, dynamic>>();
  final count = await unreadNotifications(
    context.read<Db>(),
    user['_id'] as ObjectId,
  );
  return Response.json(body: count);
}
