// WHY: Chunk 8 is the two review screens. Screen 17 (product reviews) needs
// the average, the number of reviews and the 1-5 star breakdown on top of the
// list, and screen 30 (rate your order) needs to know which products of a
// delivered order the buyer has not rated yet.
// Where it sits in the flow: the routes only read the query string and the
// body, call one function here, and return whatever it gives them. The rules
// that decide whether a review is allowed live in this file, so the buyer's
// screen and the lecturer's questions both have a single place to look.

import 'package:faheng_api/services/api_error.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// The lowest number of stars a review can have.
const reviewMinStars = 1;

/// The highest number of stars a review can have.
const reviewMaxStars = 5;

/// How long a comment may be. The box on screen 30 fits about this much and a
/// database full of essays helps nobody.
const reviewCommentMaxLength = 300;

/// One review the buyer just wrote, after the body has been checked.
class ReviewInput {
  /// Creates the checked review.
  const ReviewInput({required this.stars, required this.comment});

  /// 1 to 5.
  final int stars;

  /// The trimmed comment, or null when the buyer left the box empty.
  final String? comment;
}

/// Reads `stars` and `comment` out of a request body.
///
/// Screen 30 has five stars and a box marked "(optional)", so stars are
/// required and the comment is not. A number in a string is refused on
/// purpose: a client sending "5" is a bug that should show up in the test run,
/// not a favour to quietly accept.
ReviewInput cleanReviewInput(Object? body) {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }

  final rawStars = body['stars'];
  if (rawStars == null) {
    throw const ApiError(400, 'stars is required');
  }
  if (rawStars is! int) {
    throw const ApiError(400, 'stars must be a whole number from 1 to 5');
  }
  if (rawStars < reviewMinStars || rawStars > reviewMaxStars) {
    throw const ApiError(400, 'stars must be a whole number from 1 to 5');
  }

  final rawComment = body['comment'];
  if (rawComment != null && rawComment is! String) {
    throw const ApiError(400, 'comment must be text');
  }
  final text = (rawComment as String?)?.trim() ?? '';
  if (text.length > reviewCommentMaxLength) {
    throw const ApiError(
      400,
      'comment is longer than $reviewCommentMaxLength characters',
    );
  }

  return ReviewInput(
    stars: rawStars,
    comment: text.isEmpty ? null : text,
  );
}

/// The initials drawn in the round avatar on screen 17: "Dara Vuth" -> "DV".
///
/// Khmer names are often written the other way round, but two letters are two
/// letters either way, and the app shows what the customer typed.
String reviewInitials(String name) {
  final words = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.isEmpty) return '?';
  if (words.length == 1) {
    return words.first.substring(0, 1).toUpperCase();
  }
  return (words.first.substring(0, 1) + words[1].substring(0, 1))
      .toUpperCase();
}

/// One review as the app receives it.
///
/// `verifiedPurchase` is always true, because a review can only be written
/// from an order that was delivered. It is still sent as a field: screen 17
/// draws the tag from it, and the day a review can come from somewhere else
/// the field will already be there.
Map<String, dynamic> reviewView(Map<String, dynamic> doc) {
  final createdAt = doc['createdAt'];
  final author = (doc['authorName'] as String?) ?? 'Customer';
  final comment = doc['comment'] as String?;
  return <String, dynamic>{
    'id': (doc['_id'] as ObjectId).oid,
    'productId': (doc['productId'] as ObjectId).oid,
    'orderNumber': doc['orderNumber'],
    'authorName': author,
    'initials': reviewInitials(author),
    'stars': (doc['stars'] as num).toInt(),
    'comment': comment,
    'verifiedPurchase': doc['verifiedPurchase'] ?? true,
    if (createdAt is DateTime) 'createdAt': createdAt.toIso8601String(),
  };
}

/// The block at the top of screen 17: the average, how many reviews there are
/// and how many gave each number of stars.
///
/// The breakdown always carries all five keys, 5 down to 1, with a zero where
/// nobody voted. The screen draws five bars; if a bar disappeared when nobody
/// picked that star, the rows would jump around as reviews arrive.
Map<String, dynamic> ratingSummary(List<Map<String, dynamic>> reviews) {
  final breakdown = <String, int>{'5': 0, '4': 0, '3': 0, '2': 0, '1': 0};
  var sum = 0;
  for (final review in reviews) {
    final stars = (review['stars'] as num?)?.toInt() ?? 0;
    if (stars < reviewMinStars || stars > reviewMaxStars) continue;
    breakdown['$stars'] = (breakdown['$stars'] ?? 0) + 1;
    sum += stars;
  }
  final count = breakdown.values.fold<int>(0, (total, n) => total + n);
  // One decimal, the way the mock prints "4.5". Rounding here and not in the
  // app means two clients can never disagree about the number.
  final average = count == 0 ? 0.0 : (sum * 10 / count).round() / 10;
  return <String, dynamic>{
    'average': average,
    'count': count,
    'breakdown': breakdown,
  };
}

/// Validates `page` and `limit` the same way every other list in this API does.
int cleanPage(Map<String, String> query) {
  final page = int.tryParse(query['page'] ?? '') ?? 1;
  final limit = int.tryParse(query['limit'] ?? '') ?? 20;
  if (page < 1 || limit < 1 || limit > 100) {
    throw const ApiError(400, 'page must be 1 or more and limit 1 to 100');
  }
  return page;
}

/// The same check for `limit`, kept separate so the caller reads the way the
/// route does.
int cleanLimit(Map<String, String> query) {
  cleanPage(query);
  return int.tryParse(query['limit'] ?? '') ?? 20;
}

/// The product a review list is about, from `?productId=`.
///
/// A malformed id is a 400 ("that is not an id") and a well formed id that
/// matches nothing is a 404 ("there is no such product"); the two are
/// different mistakes and deserve different answers.
ObjectId cleanProductId(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    throw const ApiError(400, 'productId is required');
  }
  try {
    return ObjectId.parse(raw.trim());
  } catch (_) {
    throw const ApiError(400, 'productId is not a valid id');
  }
}

/// Screen 17: the product line at the top, the rating summary and one page of
/// reviews, newest first.
Future<Map<String, dynamic>> listProductReviews(
  Db db,
  Map<String, String> query,
) async {
  final productId = cleanProductId(query['productId']);
  final page = cleanPage(query);
  final limit = cleanLimit(query);

  final product = await db
      .collection('products')
      .findOne(where.eq('_id', productId).eq('isActive', true));
  if (product == null) throw const ApiError(404, 'Product not found');

  final reviews = db.collection('reviews');
  final selector = SelectorBuilder()..eq('productId', productId);
  final total = await reviews.count(selector);
  final docs = await reviews
      .find(
        SelectorBuilder()
          ..eq('productId', productId)
          ..sortBy('createdAt', descending: true)
          ..skip((page - 1) * limit)
          ..limit(limit),
      )
      .toList();

  // The summary counts every review of the product, not just this page.
  final all = await reviews.find(where.eq('productId', productId)).toList();

  return <String, dynamic>{
    'product': <String, dynamic>{
      'id': (product['_id'] as ObjectId).oid,
      'name': product['name'],
      'category': product['category'],
      'pricePerKg': product['pricePerKg'],
    },
    'summary': ratingSummary(all),
    'items': [for (final doc in docs) reviewView(doc)],
    'total': total,
    'page': page,
    'limit': limit,
  };
}

/// The `deliveredAt` stamp of an order, taken from its status history.
///
/// Screen 30 prints "Delivered 8 Nov 2026"; the order document keeps the whole
/// history, so the date is read from the `delivered` entry instead of being
/// copied into a second field that could drift.
String? deliveredAt(Map<String, dynamic> order) {
  final history = (order['statusHistory'] as List?) ?? const <dynamic>[];
  String? found;
  for (final raw in history) {
    final entry = Map<String, dynamic>.from(raw as Map);
    if (entry['status'] == 'delivered') {
      found = entry['at'] as String?;
    }
  }
  return found;
}

/// Screen 30, read side: every item of this order with the review the buyer
/// already wrote, if any.
///
/// `canReview` is per item, not per order: a buyer may rate one product today
/// and the other one next week, and the screen shows a filled star row for the
/// one that is done.
Future<Map<String, dynamic>> orderReviewState(
  Db db,
  ObjectId userId,
  ObjectId orderId,
) async {
  final order = await db
      .collection('orders')
      .findOne(where.eq('_id', orderId).eq('userId', userId));
  if (order == null) throw const ApiError(404, 'Order not found');

  final reviews = await db
      .collection('reviews')
      .find(where.eq('orderId', orderId).eq('userId', userId))
      .toList();
  final byProduct = <String, Map<String, dynamic>>{
    for (final review in reviews) (review['productId'] as ObjectId).oid: review,
  };

  final delivered = order['status'] == 'delivered';
  final items = ((order['items'] as List?) ?? const <dynamic>[])
      .map((raw) => Map<String, dynamic>.from(raw as Map))
      .toList();

  return <String, dynamic>{
    'orderNumber': order['orderNumber'],
    'status': order['status'],
    'deliveredAt': deliveredAt(order),
    'canReview': delivered,
    'items': [for (final item in items) _itemState(item, delivered, byProduct)],
  };
}

/// One row of screen 30: the product, whether it can still be rated and the
/// review it already has.
Map<String, dynamic> _itemState(
  Map<String, dynamic> item,
  bool delivered,
  Map<String, Map<String, dynamic>> byProduct,
) {
  final productId = (item['productId'] as ObjectId).oid;
  final review = byProduct[productId];
  return <String, dynamic>{
    'productId': productId,
    'name': item['name'],
    'image': item['image'],
    'quantityKg': item['quantityKg'],
    'canReview': delivered && review == null,
    'review': review == null ? null : reviewView(review),
  };
}

/// Screen 30, write side: one review for one product of a delivered order.
///
/// The rules, in the order they are checked, because the first failure is the
/// one the buyer is shown:
/// 1. the order must be this buyer's (404 for anyone else's, never 403: the
///    app must not confirm that an order exists);
/// 2. it must be delivered (400 - nothing to rate before the rice arrives);
/// 3. the product must really be in that order (400 - otherwise anyone could
///    review any rice in the shop);
/// 4. one review per product per order (409 - not per product overall, so a
///    customer who buys the same rice twice may rate both deliveries).
Future<Map<String, dynamic>> placeReview(
  Db db,
  Map<String, dynamic> user,
  ObjectId orderId,
  Object? body,
) async {
  final userId = user['_id'] as ObjectId;
  final order = await db
      .collection('orders')
      .findOne(where.eq('_id', orderId).eq('userId', userId));
  if (order == null) throw const ApiError(404, 'Order not found');

  if (order['status'] != 'delivered') {
    throw const ApiError(400, 'You can review an order once it is delivered');
  }

  final input = cleanReviewInput(body);
  final rawBody = body! as Map<String, dynamic>;
  final productId = cleanProductId(rawBody['productId'] as String?);

  final items = ((order['items'] as List?) ?? const <dynamic>[])
      .map((raw) => Map<String, dynamic>.from(raw as Map))
      .toList();
  Map<String, dynamic>? ordered;
  for (final item in items) {
    if ((item['productId'] as ObjectId) == productId) ordered = item;
  }
  if (ordered == null) {
    throw const ApiError(400, 'That product is not in this order');
  }

  final reviews = db.collection('reviews');
  final existing = await reviews.findOne(
    where
        .eq('orderId', orderId)
        .eq('productId', productId)
        .eq('userId', userId),
  );
  if (existing != null) {
    throw const ApiError(
      409,
      'You already reviewed this product for this order',
    );
  }

  final name = (user['name'] as String?)?.trim();
  final doc = <String, dynamic>{
    '_id': ObjectId(),
    'productId': productId,
    'userId': userId,
    'orderId': orderId,
    'orderNumber': order['orderNumber'],
    'productName': ordered['name'],
    'authorName': name == null || name.isEmpty ? 'Customer' : name,
    'stars': input.stars,
    'comment': input.comment,
    'verifiedPurchase': true,
    'createdAt': DateTime.now().toUtc(),
  };
  await reviews.insertOne(doc);

  return <String, dynamic>{'review': reviewView(doc)};
}
