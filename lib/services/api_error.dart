// WHY: One shared place for the API error shape.
// Where it sits in the flow: services throw ApiError when a business rule
// fails; the catch-all middleware in routes/_middleware.dart turns it into
// the {"error": "..."} body that every other route already returns.
// jsonError() is the route-side helper for input checks.

import 'package:dart_frog/dart_frog.dart';

/// Sends an error to the client in the same shape the whole API uses:
/// {"error": "a sentence a human can read"}.
Response jsonError(int status, String message) =>
    Response.json(statusCode: status, body: {'error': message});

/// Thrown inside a service when the request cannot be finished, for example
/// "not enough stock" or "product not found".
///
/// The catch-all middleware catches it and answers with [statusCode] and
/// [message], so a service never builds a Response itself.
class ApiError implements Exception {
  /// Creates the error that the middleware will send back.
  const ApiError(this.statusCode, this.message);

  /// HTTP status the client will receive (400, 404, 409, ...).
  final int statusCode;

  /// Short explanation shown in the "error" field of the response.
  final String message;
}
