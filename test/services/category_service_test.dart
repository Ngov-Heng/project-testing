import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/category_service.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:test/test.dart';

ApiError _apiError(void Function() action) {
  try {
    action();
  } on ApiError catch (error) {
    return error;
  }
  fail('expected an ApiError, but nothing was thrown');
}

void main() {
  group('the category name on screen 44', () {
    test('is trimmed', () {
      expect(cleanCategoryName('  Jasmine '), 'Jasmine');
    });

    test('may not be empty', () {
      expect(
        _apiError(() => cleanCategoryName('   ')).message,
        'name is required',
      );
    });

    test('is at most 40 characters', () {
      expect(cleanCategoryName('a' * 40).length, 40);
      expect(
        _apiError(() => cleanCategoryName('a' * 41)).message,
        'name must be 40 characters or less',
      );
    });

    test('a number instead of a name is refused', () {
      expect(_apiError(() => cleanCategoryName(4)).statusCode, 400);
    });
  });

  group('the category id in the URL', () {
    test('a hex id is parsed', () {
      final id = ObjectId();
      expect(parseCategoryId(id.oid).oid, id.oid);
    });

    test('a broken id answers 404, not a crash', () {
      expect(_apiError(() => parseCategoryId('jasmine')).statusCode, 404);
    });
  });
}
