import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/profile_service.dart';
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
  test('a valid profile is trimmed, phone cleaned, email lowercased', () {
    final clean = cleanProfileInput(<String, dynamic>{
      'name': '  Sokha Chan ',
      'phone': '+855 12 345 678',
      'email': 'Sokha@Example.COM',
    });
    expect(clean.name, 'Sokha Chan');
    expect(clean.phone, '+85512345678');
    expect(clean.email, 'sokha@example.com');
  });

  test('a missing name is refused', () {
    final error = _apiError(
      () => cleanProfileInput(<String, dynamic>{'name': '  '}),
    );
    expect(error.statusCode, 400);
    expect(error.message, 'name is required');
  });

  test('a name longer than 80 characters is refused', () {
    final error = _apiError(
      () => cleanProfileInput(<String, dynamic>{'name': 'x' * 81}),
    );
    expect(error.message, 'name must be 80 characters or less');
  });

  test('an invalid phone is refused', () {
    final error = _apiError(
      () => cleanProfileInput(<String, dynamic>{'name': 'A', 'phone': '123'}),
    );
    expect(error.message, 'phone is not valid');
  });

  test('an invalid email is refused', () {
    final error = _apiError(
      () => cleanProfileInput(<String, dynamic>{
        'name': 'A',
        'email': 'not-an-email',
      }),
    );
    expect(error.message, 'email is not valid');
  });

  test('an empty phone or email means "remove it"', () {
    final clean = cleanProfileInput(<String, dynamic>{
      'name': 'A',
      'phone': '   ',
      'email': '',
    });
    expect(clean.phone, isNull);
    expect(clean.email, isNull);
  });

  test('the profile view hides empty fields and defaults customerType', () {
    final id = ObjectId();
    final view = profileView(<String, dynamic>{
      '_id': id,
      'name': 'Sokha Chan',
      'phone': '017123456',
      'passwordHash': r'$2a$10$secret',
      'role': 'admin',
      'createdAt': DateTime.utc(2026, 10, 27, 7, 51),
    });
    expect(view['id'], id.oid);
    expect(view['customerType'], 'household');
    expect(view.containsKey('email'), isFalse);
    expect(view.containsKey('passwordHash'), isFalse);
    expect(view.containsKey('role'), isFalse);
    expect(view['createdAt'], '2026-10-27T07:51:00.000Z');
  });

  test('a business customer keeps its customerType', () {
    final view = profileView(<String, dynamic>{
      '_id': ObjectId(),
      'name': 'Dara',
      'customerType': 'business',
    });
    expect(view['customerType'], 'business');
  });
}
