// WHY: Tapping one notification on screen 31 takes the dot away from that row
// only.
// Where it sits in the flow: authGuard has already run; another buyer's
// notification answers 404.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/notification_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Marks one notification read and returns it.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.patch) {
    return Response(statusCode: 405);
  }

  final user = context.read<Map<String, dynamic>>();
  final updated = await markNotificationRead(
    context.read<Db>(),
    user['_id'] as ObjectId,
    id,
  );
  return Response.json(body: updated);
}
