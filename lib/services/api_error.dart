/*
Standardizes error handling across the entire API. Services throw ApiError
without needing HTTP imports, and the root middleware catches it and converts
it into a consistent {"error": "..."} JSON response via jsonError().
*/

import 'package:dart_frog/dart_frog.dart';

/*
Helper used by routes and middleware to return a uniform HTTP status code
and {"error": "message"} JSON payload to the mobile app.
*/

/// Sends an error to the client in the same shape the whole API uses:
/// {"error": "a sentence a human can read"}.
Response jsonError(int status, String message) =>
    Response.json(statusCode: status, body: {'error': message});


/*
Custom exception thrown by service functions when a validation or business
rule fails (e.g. 400, 404, 409), separating database logic from HTTP responses.
*/

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
