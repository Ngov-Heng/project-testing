import 'dart:math';

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/auth_service.dart';
import 'package:faheng_api/services/password_service.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:test/test.dart';

class _ZeroRandom implements Random {
  @override
  int nextInt(int max) => 0;

  @override
  double nextDouble() => 0;

  @override
  bool nextBool() => false;
}

ApiError _apiError(void Function() action) {
  try {
    action();
  } on ApiError catch (error) {
    return error;
  }
  fail('expected an ApiError, but nothing was thrown');
}

Map<String, dynamic> _user({
  String code = '482913',
  String purpose = signupPurpose,
  DateTime? issuedAt,
  DateTime? expiresAt,
  int attempts = 0,
  bool? isVerified,
}) {
  final now = issuedAt ?? DateTime.utc(2026, 11, 8, 3);
  return <String, dynamic>{
    '_id': ObjectId(),
    'name': 'Sokha Chan',
    'phone': '+85512345678',
    if (isVerified != null) 'isVerified': isVerified,
    'verification': <String, dynamic>{
      'code': code,
      'purpose': purpose,
      'issuedAt': now,
      'expiresAt': expiresAt ?? now.add(codeLifetime),
      'attempts': attempts,
    },
  };
}

void main() {
  final now = DateTime.utc(2026, 11, 8, 3);

  group('the six-digit code', () {
    test('is six digits long and only digits', () {
      for (var i = 0; i < 50; i++) {
        final code = generateCode();
        expect(code.length, 6);
        expect(RegExp(r'^[0-9]{6}$').hasMatch(code), isTrue, reason: code);
      }
    });

    test('a leading zero is kept, because 012345 is a real code', () {
      expect(generateCode(_ZeroRandom()), '000000');
    });

    test('does not repeat the same number every time', () {
      final seen = <String>{for (var i = 0; i < 20; i++) generateCode()};
      expect(seen.length, greaterThan(1));
    });

    test('a code with five digits is refused', () {
      expect(
        _apiError(() => cleanCode('12345')).message,
        'code must be 6 digits',
      );
    });

    test('letters are refused', () {
      expect(_apiError(() => cleanCode('12a45b')).statusCode, 400);
    });

    test('a missing code is refused by name', () {
      expect(_apiError(() => cleanCode(null)).message, 'code is required');
    });

    test('six digits pass and the spaces around them are trimmed', () {
      expect(cleanCode(' 482913 '), '482913');
    });
  });

  group('the email or phone field', () {
    test('finds an account by lower-case email', () {
      expect(
        identifierQuery(' Sokha@Example.COM '),
        <String, dynamic>{'email': 'sokha@example.com'},
      );
    });

    test('finds an account by phone with the spaces removed', () {
      expect(
        identifierQuery('+855 12 345 678'),
        <String, dynamic>{'phone': '+85512345678'},
      );
    });

    test('a broken email says so', () {
      expect(
        _apiError(() => identifierQuery('sokha.example.com')).message,
        'phone is not valid',
      );
    });

    test('an email without an @ is read as a phone and refused', () {
      expect(
        _apiError(() => identifierQuery('sokha@example')).message,
        'email is not valid',
      );
    });

    test('an empty identifier is refused', () {
      expect(
        _apiError(() => cleanIdentifier('   ')).message,
        'identifier is required',
      );
    });
  });

  group('the household or business choice from screen 09', () {
    test('defaults to household when the field is missing', () {
      expect(cleanCustomerType(null), 'household');
    });

    test('accepts Business typed with a capital letter', () {
      expect(cleanCustomerType(' Business '), 'business');
    });

    test('refuses a third value', () {
      expect(
        _apiError(() => cleanCustomerType('restaurant')).message,
        'customerType must be household or business',
      );
    });
  });

  group('the new password rule on screens 12 and 34', () {
    test('seven characters is too short', () {
      expect(
        _apiError(() => cleanNewPassword('1234567')).message,
        'password must be at least 8 characters',
      );
    });

    test('eight characters is enough', () {
      expect(cleanNewPassword('12345678'), '12345678');
    });

    test('reusing the old password is refused with the screen wording', () {
      final hash = hashPassword('password123');
      expect(
        _apiError(() => ensurePasswordChanged('password123', hash)).message,
        'New password must be different from your old one',
      );
    });

    test('a different password passes', () {
      final hash = hashPassword('password123');
      expect(() => ensurePasswordChanged('password456', hash), returnsNormally);
    });
  });

  group('the stored code', () {
    test('lives ten minutes and starts at zero wrong tries', () {
      final doc = verificationDoc('482913', signupPurpose, now);
      expect(doc['code'], '482913');
      expect(doc['purpose'], signupPurpose);
      expect(doc['attempts'], 0);
      expect(doc['expiresAt'], now.add(const Duration(minutes: 10)));
    });

    test('the countdown on screen 10 is 42 seconds after 18', () {
      final user = _user(issuedAt: now.subtract(const Duration(seconds: 18)));
      expect(resendWaitSeconds(user, now), 42);
    });

    test('the countdown is over after a minute', () {
      final user = _user(issuedAt: now.subtract(const Duration(minutes: 2)));
      expect(resendWaitSeconds(user, now), 0);
    });

    test('an account with no code may ask for one immediately', () {
      final user = <String, dynamic>{'_id': ObjectId()};
      expect(resendWaitSeconds(user, now), 0);
    });
  });

  group('checking a typed code', () {
    test('the right code passes', () {
      expect(
        () => checkVerification(_user(), '482913', signupPurpose, now),
        returnsNormally,
      );
    });

    test('a wrong code says so', () {
      expect(
        _apiError(
          () => checkVerification(_user(), '000000', signupPurpose, now),
        ).message,
        'That code is not correct',
      );
    });

    test('an expired code asks for a new one', () {
      final user = _user(issuedAt: now.subtract(const Duration(minutes: 11)));
      expect(
        _apiError(
          () => checkVerification(user, '482913', signupPurpose, now),
        ).message,
        'That code has expired. Ask for a new one',
      );
    });

    test('a sign-up code cannot reset a password', () {
      expect(
        _apiError(
          () => checkVerification(_user(), '482913', resetPurpose, now),
        ).message,
        'That code is not for this action',
      );
    });

    test('the sixth wrong try is refused with 429', () {
      final user = _user(attempts: 5);
      final error = _apiError(
        () => checkVerification(user, '482913', signupPurpose, now),
      );
      expect(error.statusCode, 429);
      expect(error.message, 'Too many wrong codes. Ask for a new one');
    });

    test('an account with no code is told to ask for one', () {
      final user = <String, dynamic>{'_id': ObjectId()};
      expect(
        _apiError(
          () => checkVerification(user, '482913', signupPurpose, now),
        ).message,
        'Ask for a code first',
      );
    });
  });

  group('the user object login returns', () {
    test('an old account with no role counts as a buyer', () {
      final view = authUserView(<String, dynamic>{
        '_id': ObjectId(),
        'name': 'Dara',
        'phone': '017123456',
      });
      expect(view['role'], 'buyer');
      expect(view['customerType'], 'household');
      expect(view['isVerified'], isTrue);
      expect(view['email'], isNull);
    });

    test('an admin keeps the admin role', () {
      final view = authUserView(<String, dynamic>{
        '_id': ObjectId(),
        'name': 'Sokha',
        'email': 'sokha@example.com',
        'role': 'admin',
        'customerType': 'business',
        'isVerified': true,
      });
      expect(view['role'], 'admin');
      expect(view['customerType'], 'business');
      expect(view['id'], matches(RegExp(r'^[0-9a-f]{24}$')));
    });

    test('an account that never typed its code says so', () {
      final view = authUserView(<String, dynamic>{
        '_id': ObjectId(),
        'name': 'New buyer',
        'isVerified': false,
      });
      expect(view['isVerified'], isFalse);
    });
  });

  group('reading screen 09', () {
    test('a phone-only sign up is fine and household is the default', () {
      final clean = cleanSignup(<String, dynamic>{
        'name': ' Sokha Chan ',
        'phone': '+855 12 345 678',
        'password': 'password123',
      });
      expect(clean.name, 'Sokha Chan');
      expect(clean.phone, '+85512345678');
      expect(clean.email, isNull);
      expect(clean.customerType, 'household');
    });

    test('an email-only sign up is lower-cased', () {
      final clean = cleanSignup(<String, dynamic>{
        'name': 'Dara',
        'email': 'Dara@Example.com',
        'password': 'password123',
        'customerType': 'business',
      });
      expect(clean.email, 'dara@example.com');
      expect(clean.customerType, 'business');
    });

    test('both contacts may be filled in', () {
      final clean = cleanSignup(<String, dynamic>{
        'name': 'Dara',
        'email': 'dara@example.com',
        'phone': '017123456',
        'password': 'password123',
      });
      expect(clean.email, 'dara@example.com');
      expect(clean.phone, '017123456');
    });

    test('a name is required', () {
      expect(
        _apiError(
          () => cleanSignup(<String, dynamic>{
            'phone': '017123456',
            'password': 'password123',
          }),
        ).message,
        'name is required',
      );
    });

    test('one contact is required', () {
      expect(
        _apiError(
          () => cleanSignup(<String, dynamic>{
            'name': 'Dara',
            'password': 'password123',
          }),
        ).message,
        'email or phone is required',
      );
    });
  });
}
