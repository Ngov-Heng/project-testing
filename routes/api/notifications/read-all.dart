import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/notification_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

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
