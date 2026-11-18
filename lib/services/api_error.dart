// The one exception type the middleware turns into a JSON error.

import 'package:dart_frog/dart_frog.dart';

Response jsonError(int status, String message) =>
    Response.json(statusCode: status, body: {'error': message});

class ApiError implements Exception {
  const ApiError(this.statusCode, this.message);
  final int statusCode;
  final String message;
}
