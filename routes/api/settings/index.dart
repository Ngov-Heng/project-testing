// WHY: The buyer app needs the shop details and the pricing rule before the
// buyer logs in: screen 02 writes the "Save 10% on 150kg+" banner from it, and
// screens 29 (invoice) and 35 (help and contact) print the shop name, phone
// and address. So this route is public and needs no token.
// Where it sits in the flow: the app calls it on startup; settings_service
// reads the single settings document and hides the admin-only parts.

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/settings_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// Public shop info, the payment methods that are switched on, and the
/// discount rule the home banner needs.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  final settings = await loadSettings(context.read<Db>());
  return Response.json(body: publicSettingsView(settings));
}
