// WHY: Screen 31 (notifications) reads the list here, and the unread count that
// the bell on Home shows comes back in the same body.
// Where it sits in the flow: authGuard has already run.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/notification_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Lists this buyer's notifications, newest first.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }

  final user = context.read<Map<String, dynamic>>();
  final page = await listNotifications(
    context.read<Db>(),
    user['_id'] as ObjectId,
    context.request.uri.queryParameters,
  );
  return Response.json(body: page);
}
