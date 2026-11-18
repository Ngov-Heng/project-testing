import 'package:faheng_api/services/address_service.dart';
import 'package:faheng_api/services/api_error.dart';
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

Map<String, dynamic> _body() => <String, dynamic>{
  'label': 'home',
  'receiverName': 'Sokha Chan',
  'phone': '+855 12 345 678',
  'street': 'House 14, Street 271, Tuek Thla',
  'town': 'Phnom Penh',
};

void main() {
  test('a valid address is trimmed, lowercased and its phone cleaned', () {
    final body = _body()
      ..['label'] = ' Home '
      ..['receiverName'] = '  Sokha Chan  ';
    final clean = cleanAddressInput(body);
    expect(clean.label, 'home');
    expect(clean.receiverName, 'Sokha Chan');
    expect(clean.phone, '+85512345678');
    expect(clean.town, 'Phnom Penh');
    expect(clean.lat, isNull);
    expect(clean.lng, isNull);
    expect(clean.isDefault, isFalse);
  });

  test('work and other are accepted as labels', () {
    expect(cleanAddressInput(_body()..['label'] = 'work').label, 'work');
    expect(cleanAddressInput(_body()..['label'] = 'other').label, 'other');
  });

  test('a label that is not in the list is refused', () {
    final error = _apiError(
      () => cleanAddressInput(_body()..['label'] = 'farm'),
    );
    expect(error.statusCode, 400);
    expect(error.message, contains('home, work or other'));
  });

  test('a missing label is refused', () {
    final body = _body()..remove('label');
    expect(
      _apiError(() => cleanAddressInput(body)).message,
      'label is required',
    );
  });

  test('a missing street is refused', () {
    final body = _body()..['street'] = '   ';
    expect(
      _apiError(() => cleanAddressInput(body)).message,
      'street is required',
    );
  });

  test('a town longer than 60 characters is refused', () {
    final body = _body()..['town'] = 'x' * 61;
    expect(
      _apiError(() => cleanAddressInput(body)).message,
      'town must be 60 characters or less',
    );
  });

  test('a phone that is not a phone number is refused', () {
    final body = _body()..['phone'] = 'abc';
    expect(
      _apiError(() => cleanAddressInput(body)).message,
      'phone is not valid',
    );
  });

  test('latitude above 90 is refused, -90 is accepted', () {
    final bad = _body()..['lat'] = 91;
    expect(
      _apiError(() => cleanAddressInput(bad)).message,
      'lat must be between -90 and 90',
    );
    final good = _body()
      ..['lat'] = -90
      ..['lng'] = 104.9;
    final clean = cleanAddressInput(good);
    expect(clean.lat, -90.0);
    expect(clean.lng, 104.9);
  });

  test('longitude outside -180..180 is refused', () {
    final body = _body()..['lng'] = 200;
    expect(_apiError(() => cleanAddressInput(body)).statusCode, 400);
  });

  test('isDefault must be a boolean', () {
    final body = _body()..['isDefault'] = 'yes';
    final error = _apiError(() => cleanAddressInput(body));
    expect(error.message, 'isDefault must be true or false');
  });

  test('isDefault true is kept', () {
    expect(cleanAddressInput(_body()..['isDefault'] = true).isDefault, isTrue);
  });

  test('a malformed address id answers 404, not a crash', () {
    final error = _apiError(() => parseAddressId('not-an-id'));
    expect(error.statusCode, 404);
    expect(error.message, 'Address not found');
  });

  test('a real hex id is parsed', () {
    final hex = ObjectId().oid;
    expect(parseAddressId(hex).oid, hex);
  });

  test('the response uses a hex id and a boolean default flag', () {
    final id = ObjectId();
    final view = addressView(<String, dynamic>{
      '_id': id,
      'userId': ObjectId(),
      'label': 'home',
      'receiverName': 'Sokha Chan',
      'phone': '+85512345678',
      'street': 'House 14',
      'town': 'Phnom Penh',
      'lat': 11.5,
      'lng': 104.9,
      'isDefault': true,
      'createdAt': DateTime.utc(2026, 11, 8, 3),
    });
    expect(view['id'], id.oid);
    expect(view['isDefault'], isTrue);
    expect(view.containsKey('userId'), isFalse);
    expect(view['createdAt'], '2026-11-08T03:00:00.000Z');
  });
}
