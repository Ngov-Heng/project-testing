// WHY: Stops an unexpected crash from sending a Dart stack trace to the
// Flutter app, and keeps the error body the same shape as everywhere else.
// Where it sits in the flow: it is the outermost middleware, so it wraps
// every route under routes/ (health, /api and everything added later).

import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';

/// Catches everything the routes and services throw.
Handler middleware(Handler handler) {
  return (context) async {
    try {
      return await handler(context);
    } on ApiError catch (error) {
      // A rule we planned for (bad input, not found, no stock, ...).
      return jsonError(error.statusCode, error.message);
    } catch (error, stack) {
      // ignore: avoid_print
      print('UNHANDLED: $error\n$stack');
      return jsonError(500, 'Something went wrong');
    }
  };
}
