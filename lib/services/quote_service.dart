// WHY: Screen 25 lets a buyer ask for a price on 150 kg or more, screen 47 is
// the admin answering it, and the Accept / Decline buttons on screen 31 are the
// buyer answering back. All three are the same record moving through four
// statuses, so they live together here.
// Where it sits in the flow: the buyer creates a quote (status "new"), the
// admin sends a price (status "quoted", and the buyer gets a notification), the
// buyer accepts or declines (status "accepted" or "declined"). Nothing else
// moves it.

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/notification_service.dart';
import 'package:faheng_api/services/pricing_service.dart';
import 'package:faheng_api/services/settings_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// The four statuses of screen 47. "new" and "quoted" are the two that still
/// need somebody to do something.
const quoteStatuses = <String>['new', 'quoted', 'accepted', 'declined'];

/// Screen 25 says "Minimum 150 kg" under the quantity box.
const minimumQuoteKg = 150;

/// The note boxes on screens 25 and 47 are both small; one limit for both.
const quoteNoteMaxLength = 300;

/// Screen 47 shows QR-006, so the number is padded to three digits.
String quoteNumberFor(int value) => 'QR-${value.toString().padLeft(3, '0')}';

/// One quote request, after the body has been checked.
class QuoteInput {
  /// Creates the checked request.
  const QuoteInput({
    required this.productId,
    required this.quantityKg,
    required this.addressId,
    required this.note,
  });

  /// The product the buyer wants priced.
  final ObjectId productId;

  /// How many kg, at least [minimumQuoteKg].
  final double quantityKg;

  /// Where it should go. Copied onto the quote so the admin sees the address
  /// the buyer had chosen at the time.
  final ObjectId addressId;

  /// The optional "Anything we should know?" text.
  final String? note;
}

ObjectId _objectId(Object? raw, String field) {
  if (raw is! String || raw.trim().isEmpty) {
    throw ApiError(400, '$field is required');
  }
  try {
    return ObjectId.parse(raw.trim());
  } catch (_) {
    throw ApiError(400, '$field is not a valid id');
  }
}

/// Reads `productId`, `quantityKg`, `addressId` and `note` off screen 25.
QuoteInput cleanQuoteInput(Object? body) {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }

  final rawKg = body['quantityKg'];
  if (rawKg is! num) {
    throw const ApiError(400, 'quantityKg is required');
  }
  final kg = rawKg.toDouble();
  if (kg < minimumQuoteKg) {
    throw const ApiError(400, 'A quote starts at $minimumQuoteKg kg');
  }
  if (kg > 100000) {
    throw const ApiError(400, 'quantityKg is too large to quote');
  }

  final rawNote = body['note'];
  if (rawNote != null && rawNote is! String) {
    throw const ApiError(400, 'note must be text');
  }
  final note = (rawNote as String?)?.trim() ?? '';
  if (note.length > quoteNoteMaxLength) {
    throw const ApiError(
      400,
      'note is longer than $quoteNoteMaxLength characters',
    );
  }

  return QuoteInput(
    productId: _objectId(body['productId'], 'productId'),
    quantityKg: kg,
    addressId: _objectId(body['addressId'], 'addressId'),
    note: note.isEmpty ? null : note,
  );
}

/// Whole numbers of kg are stored as ints, so "200.0" never ends up in the
/// database as a float and prints as "200.0 kg" on screen 47.
num tidyKg(double kg) => kg == kg.roundToDouble() ? kg.round() : kg;

/// One quote as the buyer's app receives it.
Map<String, dynamic> quoteView(Map<String, dynamic> doc) {
  final requestedAt = doc['requestedAt'];
  final quotedAt = doc['quotedAt'];
  final respondedAt = doc['respondedAt'];
  final priceCents = doc['pricePerKgCents'] as num?;
  return <String, dynamic>{
    'id': (doc['_id'] as ObjectId).oid,
    'requestNumber': doc['requestNumber'],
    'status': doc['status'],
    'product': <String, dynamic>{
      'id': (doc['productId'] as ObjectId).oid,
      'name': doc['productName'],
      'category': doc['productCategory'],
    },
    'quantityKg': doc['quantityKg'],
    'address': doc['address'],
    'note': doc['note'],
    // Dollars, like every other money field the app already reads.
    'pricePerKg': priceCents == null ? null : toDollars(priceCents.round()),
    'total': doc['quotedTotalCents'] == null
        ? null
        : toDollars((doc['quotedTotalCents'] as num).round()),
    'adminNote': doc['adminNote'],
    if (requestedAt is DateTime)
      'requestedAt': requestedAt.toIso8601String(),
    if (quotedAt is DateTime) 'quotedAt': quotedAt.toIso8601String(),
    if (respondedAt is DateTime) 'respondedAt': respondedAt.toIso8601String(),
  };
}

/// The next QR number, using the same `counters` collection and the same
/// atomic `$inc` as order numbers, so two requests at once never share a
/// number.
Future<int> nextQuoteNumber(Db db) async {
  final counters = db.collection('counters');
  final existing = await counters.findOne(where.eq('_id', 'quotes'));
  if (existing == null) {
    try {
      await counters.insertOne(<String, dynamic>{'_id': 'quotes', 'seq': 0});
    } catch (_) {
      // Another request created it in the same instant; that is fine.
    }
  }
  final result = await counters.modernFindAndModify(
    query: where.eq('_id', 'quotes'),
    update: modify.inc('seq', 1),
    returnNew: true,
  );
  final seq = result.value?['seq'];
  if (seq is! num) {
    throw const ApiError(500, 'Could not create a request number');
  }
  return seq.round();
}

/// The address copy stored on the quote: what the admin needs to answer, and
/// what the buyer chose at that moment.
Map<String, dynamic> quoteAddressCopy(Map<String, dynamic> address) =>
    <String, dynamic>{
      'label': address['label'],
      'receiverName': address['receiverName'],
      'phone': address['phone'],
      'street': address['street'],
      'town': address['town'],
    };

/// Screen 25: the buyer sends a request for a price.
Future<Map<String, dynamic>> createQuote(
  Db db,
  ObjectId userId,
  Object? body,
) async {
  final input = cleanQuoteInput(body);

  final product = await db
      .collection('products')
      .findOne(where.eq('_id', input.productId).eq('isActive', true));
  if (product == null) throw const ApiError(404, 'Product not found');

  final address = await db
      .collection('addresses')
      .findOne(where.eq('_id', input.addressId).eq('userId', userId));
  if (address == null) throw const ApiError(404, 'Address not found');

  final now = DateTime.now().toUtc();
  final seq = await nextQuoteNumber(db);
  final doc = <String, dynamic>{
    '_id': ObjectId(),
    'userId': userId,
    'requestNumber': quoteNumberFor(seq),
    'requestNumberValue': seq,
    'productId': input.productId,
    'productName': product['name'],
    'productCategory': product['category'],
    // The shop price at the moment of the request. Screen 47 prints it next to
    // the suggested bulk price, so it is copied here instead of being looked up
    // again: a price change tomorrow must not rewrite yesterday's request.
    'shopPricePerKgCents':
        (((product['pricePerKg'] as num?) ?? 0) * 100).round(),

    'quantityKg': tidyKg(input.quantityKg),
    'addressId': input.addressId,
    'address': quoteAddressCopy(address),
    'note': input.note,
    'status': 'new',
    'pricePerKgCents': null,
    'quotedTotalCents': null,
    'adminNote': null,
    'requestedAt': now,
    'createdAt': now,
  };
  await db.collection('quotes').insertOne(doc);
  return quoteView(doc);
}

/// The buyer's own quotes, newest first.
Future<Map<String, dynamic>> listMyQuotes(
  Db db,
  ObjectId userId,
  Map<String, String> query,
) async {
  final page = int.tryParse(query['page'] ?? '') ?? 1;
  final limit = int.tryParse(query['limit'] ?? '') ?? 20;
  if (page < 1 || limit < 1 || limit > 100) {
    throw const ApiError(400, 'page must be 1 or more and limit 1 to 100');
  }

  final collection = db.collection('quotes');
  final total = await collection.count(
    SelectorBuilder()..eq('userId', userId),
  );
  final docs = await collection
      .find(
        SelectorBuilder()
          ..eq('userId', userId)
          ..sortBy('createdAt', descending: true)
          ..skip((page - 1) * limit)
          ..limit(limit),
      )
      .toList();

  return <String, dynamic>{
    'items': [for (final doc in docs) quoteView(doc)],
    'total': total,
    'page': page,
    'limit': limit,
  };
}

ObjectId _parseQuoteId(String raw) {
  try {
    return ObjectId.parse(raw);
  } catch (_) {
    throw const ApiError(404, 'Quote not found');
  }
}

/// One of the buyer's quotes. Another buyer's quote answers 404, never 403.
Future<Map<String, dynamic>> findMyQuote(
  Db db,
  ObjectId userId,
  String rawId,
) async {
  final quote = await db
      .collection('quotes')
      .findOne(where.id(_parseQuoteId(rawId)).eq('userId', userId));
  if (quote == null) throw const ApiError(404, 'Quote not found');
  return quoteView(quote);
}

/// The Accept / Decline buttons on screen 31.
///
/// Only a quote that has a price can be answered; answering twice, or
/// answering a request the admin has not priced yet, is a conflict (409), not a
/// bad request, because both are about the state of the record.
Future<Map<String, dynamic>> respondToQuote(
  Db db,
  ObjectId userId,
  String rawId,
  Object? body,
) async {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }
  final raw = body['action'];
  final action = raw is String ? raw.trim().toLowerCase() : '';
  if (action != 'accept' && action != 'decline') {
    throw const ApiError(400, 'action must be accept or decline');
  }

  final id = _parseQuoteId(rawId);
  final collection = db.collection('quotes');
  final quote = await collection.findOne(where.id(id).eq('userId', userId));
  if (quote == null) throw const ApiError(404, 'Quote not found');

  final status = quote['status'] as String? ?? 'new';
  if (status != 'quoted') {
    throw ApiError(
      409,
      status == 'new'
          ? 'This request has no price yet'
          : 'This quote is already $status',
    );
  }

  final next = action == 'accept' ? 'accepted' : 'declined';
  final now = DateTime.now().toUtc();
  await collection.updateOne(
    where.id(id),
    modify.set('status', next).set('respondedAt', now),
  );
  quote['status'] = next;
  quote['respondedAt'] = now;
  return quoteView(quote);
}

/// The filter half of screen 47's query: status only. The search box is added
/// by id, because a customer name lives in `users`.
SelectorBuilder buildQuoteQuery(
  Map<String, String> query, {
  List<ObjectId>? ids,
}) {
  final status = (query['status'] ?? 'all').trim().toLowerCase();
  if (status != 'all' && !quoteStatuses.contains(status)) {
    throw const ApiError(
      400,
      'status must be all, new, quoted, accepted or declined',
    );
  }
  final selector = SelectorBuilder();
  if (status != 'all') selector.eq('status', status);
  if (ids != null) selector.oneFrom('_id', ids);
  return selector;
}

/// The counts under the title on screen 47: "6 requests · 2 new · 2 quoted".
Map<String, int> quoteStatusCounts(List<Map<String, dynamic>> quotes) {
  final counts = <String, int>{
    'all': quotes.length,
    for (final status in quoteStatuses) status: 0,
  };
  for (final quote in quotes) {
    final status = quote['status'] as String? ?? 'new';
    counts[status] = (counts[status] ?? 0) + 1;
  }
  return counts;
}

/// The admin row of screen 47, and the right hand panel behind it.
///
/// `shopPricePerKg` and `suggestedPricePerKg` are there so the panel can print
/// "Shop price $1.48 per kg, minus 10% bulk discount" and prefill $1.33
/// without asking the API a second time.
Map<String, dynamic> adminQuoteView(
  Map<String, dynamic> doc,
  Map<String, dynamic>? customer,
  PricingRules rules,
) {
  final shopCents = doc['shopPricePerKgCents'] as num?;
  final priceCents = doc['pricePerKgCents'] as num?;
  final suggestedCents = shopCents == null
      ? null
      : (shopCents * (100 - rules.percent) / 100).round();
  final requestedAt = doc['requestedAt'];
  return <String, dynamic>{
    'id': (doc['_id'] as ObjectId).oid,
    'requestNumber': doc['requestNumber'],
    'status': doc['status'],
    'customer': <String, dynamic>{
      'id': (doc['userId'] as ObjectId).oid,
      'name': customer?['name'],
      'phone': customer?['phone'],
      'customerType': customer?['customerType'],
      'town': (doc['address'] as Map?)?['town'],
    },
    'product': <String, dynamic>{
      'id': (doc['productId'] as ObjectId).oid,
      'name': doc['productName'],
      'category': doc['productCategory'],
    },
    'quantityKg': doc['quantityKg'],
    'address': doc['address'],
    'note': doc['note'],
    'shopPricePerKg': shopCents == null ? null : toDollars(shopCents.round()),
    'suggestedPricePerKg':
        suggestedCents == null ? null : toDollars(suggestedCents),
    'bulkDiscountPercent': rules.percent,
    'pricePerKg': priceCents == null ? null : toDollars(priceCents.round()),
    'total': doc['quotedTotalCents'] == null
        ? null
        : toDollars((doc['quotedTotalCents'] as num).round()),
    'adminNote': doc['adminNote'],
    if (requestedAt is DateTime)
      'requestedAt': requestedAt.toIso8601String(),
  };
}

/// Screen 47: one page of requests, plus the counts above the table.
Future<Map<String, dynamic>> adminListQuotes(
  Db db,
  Map<String, String> query,
) async {
  final page = int.tryParse(query['page'] ?? '') ?? 1;
  final limit = int.tryParse(query['limit'] ?? '') ?? 20;
  if (page < 1 || limit < 1 || limit > 100) {
    throw const ApiError(400, 'page must be 1 or more and limit 1 to 100');
  }
  final collection = db.collection('quotes');

  // The search box matches the request number or the customer's name, which
  // lives in `users`, so it is turned into a list of ids first.
  List<ObjectId>? ids;
  final term = (query['q'] ?? '').trim();
  if (term.isNotEmpty) {
    final pattern = RegExp.escape(term);
    final byNumber = await collection
        .find(where.match('requestNumber', pattern, caseInsensitive: true))
        .toList();
    final users = await db
        .collection('users')
        .find(where.match('name', pattern, caseInsensitive: true))
        .toList();
    final userIds = users.map((user) => user['_id']).whereType<ObjectId>();
    final byCustomer = userIds.isEmpty
        ? const <Map<String, dynamic>>[]
        : await collection
            .find(where.oneFrom('userId', userIds.toList()))
            .toList();
    ids = <ObjectId>{
      for (final doc in [...byNumber, ...byCustomer])
        doc['_id'] as ObjectId,
    }.toList();
    if (ids.isEmpty) {
      return <String, dynamic>{
        'items': const <Map<String, dynamic>>[],
        'total': 0,
        'page': page,
        'limit': limit,
        'summary': quoteStatusCounts(const []),
      };
    }
  }

  final total = await collection.count(buildQuoteQuery(query, ids: ids));
  final paged = buildQuoteQuery(query, ids: ids)
    ..sortBy('createdAt', descending: true)
    ..skip((page - 1) * limit)
    ..limit(limit);
  final docs = await collection.find(paged).toList();

  final rules = rulesFrom(await loadSettings(db));
  final customers = await _customersFor(db, docs);
  final allInFilter = await collection.find(buildQuoteQuery(query)).toList();

  return <String, dynamic>{
    'items': [
      for (final doc in docs)
        adminQuoteView(
          doc,
          customers[(doc['userId'] as ObjectId).oid],
          rules,
        ),
    ],
    'total': total,
    'page': page,
    'limit': limit,
    'summary': quoteStatusCounts(allInFilter),
  };
}

/// The customers of a page of quotes in one query.
Future<Map<String, Map<String, dynamic>>> _customersFor(
  Db db,
  List<Map<String, dynamic>> docs,
) async {
  final ids = docs.map((doc) => doc['userId']).whereType<ObjectId>().toList();
  if (ids.isEmpty) return <String, Map<String, dynamic>>{};
  final users = await db
      .collection('users')
      .find(where.oneFrom('_id', ids))
      .toList();
  return <String, Map<String, dynamic>>{
    for (final user in users) (user['_id'] as ObjectId).oid: user,
  };
}

/// Screen 47's "Send quote": the admin types a price per kg and an optional
/// note, and the buyer is told about it on screen 31.
///
/// Re-quoting is allowed while the request is still `new` or `quoted`, because
/// a wrong price should be fixable without asking the buyer to start again.
/// Once the buyer has answered, the price is history.
Future<Map<String, dynamic>> sendQuote(
  Db db,
  String rawId,
  Object? body,
) async {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }

  final rawPrice = body['pricePerKg'];
  if (rawPrice is! num) {
    throw const ApiError(400, 'pricePerKg is required');
  }
  if (rawPrice <= 0 || rawPrice > 1000) {
    throw const ApiError(400, 'pricePerKg must be more than 0');
  }
  final rawNote = body['note'];
  if (rawNote != null && rawNote is! String) {
    throw const ApiError(400, 'note must be text');
  }
  final note = (rawNote as String?)?.trim() ?? '';
  if (note.length > quoteNoteMaxLength) {
    throw const ApiError(
      400,
      'note is longer than $quoteNoteMaxLength characters',
    );
  }

  final id = _parseQuoteId(rawId);
  final collection = db.collection('quotes');
  final quote = await collection.findOne(where.id(id));
  if (quote == null) throw const ApiError(404, 'Quote not found');

  final status = quote['status'] as String? ?? 'new';
  if (status == 'accepted' || status == 'declined') {
    throw ApiError(409, 'This quote is already $status');
  }

  final priceCents = (rawPrice * 100).round();
  final kg = (quote['quantityKg'] as num).toDouble();
  final totalCents = (priceCents * kg).round();
  final now = DateTime.now().toUtc();

  await collection.updateOne(
    where.id(id),
    modify
        .set('status', 'quoted')
        .set('pricePerKgCents', priceCents)
        .set('quotedTotalCents', totalCents)
        .set('adminNote', note.isEmpty ? null : note)
        .set('quotedAt', now),
  );
  quote
    ..['status'] = 'quoted'
    ..['pricePerKgCents'] = priceCents
    ..['quotedTotalCents'] = totalCents
    ..['adminNote'] = note.isEmpty ? null : note
    ..['quotedAt'] = now;

  // Screen 31: "Your quote is ready — Jasmine rice, 200 kg at $1.08 per kg."
  await addNotification(
    db,
    userId: quote['userId'] as ObjectId,
    type: 'quote_ready',
    title: 'Your quote is ready',
    body: '${quote['productName']}, ${quote['quantityKg']} kg at '
        '${moneyLabel(priceCents)} per kg. Total ${moneyLabel(totalCents)}.',
    quoteId: id,
  );

  final customer = await db
      .collection('users')
      .findOne(where.id(quote['userId'] as ObjectId));
  return adminQuoteView(quote, customer, rulesFrom(await loadSettings(db)));
}
