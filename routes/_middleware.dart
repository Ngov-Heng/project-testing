import 'package:dart_frog/dart_frog.dart';
import 'package:faheng_api/services/api_error.dart';

Handler middleware(Handler handler) {
  return (context) async {
    try {
      return await handler(context);
    } on ApiError catch (error) {
      return jsonError(error.statusCode, error.message);
    } catch (error, stack) {
      // ignore: avoid_print
      print('UNHANDLED: $error\n$stack');
      return jsonError(500, 'Something went wrong');
    }
  };
}
