import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/review_service.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:test/test.dart';

/// Runs [action] and returns the ApiError it throws.
ApiError _apiError(void Function() action) {
  try {
    action();
  } on ApiError catch (error) {
    return error;
  }
  fail('expected an ApiError, but nothing was thrown');
}

/// One review document, the shape the database holds.
Map<String, dynamic> _doc({
  required int stars,
  String? comment,
  String name = 'Dara Vuth',
}) =>
    <String, dynamic>{
      '_id': ObjectId(),
      'productId': ObjectId(),
      'userId': ObjectId(),
      'orderId': ObjectId(),
      'orderNumber': 'FH-1042',
      'authorName': name,
      'stars': stars,
      'comment': comment,
      'verifiedPurchase': true,
      'createdAt': DateTime.utc(2026, 11, 6, 9, 30),
    };

void main() {
  group('the five stars on screen 30', () {
    test('a review needs stars', () {
      final error = _apiError(() => cleanReviewInput(<String, dynamic>{}));
      expect(error.statusCode, 400);
      expect(error.message, 'stars is required');
    });

    test('zero stars is refused', () {
      final error = _apiError(
        () => cleanReviewInput(<String, dynamic>{'stars': 0}),
      );
      expect(error.statusCode, 400);
    });

    test('six stars is refused', () {
      final error = _apiError(
        () => cleanReviewInput(<String, dynamic>{'stars': 6}),
      );
      expect(error.message, 'stars must be a whole number from 1 to 5');
    });

    test('three and a half stars is refused', () {
      final error = _apiError(
        () => cleanReviewInput(<String, dynamic>{'stars': 3.5}),
      );
      expect(error.statusCode, 400);
    });

    test('stars sent as text is refused', () {
      final error = _apiError(
        () => cleanReviewInput(<String, dynamic>{'stars': '5'}),
      );
      expect(error.statusCode, 400);
    });

    test('five stars with no comment is fine', () {
      final input = cleanReviewInput(<String, dynamic>{'stars': 5});
      expect(input.stars, 5);
      expect(input.comment, isNull);
    });

    test('the comment is trimmed', () {
      final input = cleanReviewInput(<String, dynamic>{
        'stars': 4,
        'comment': '  Cooks soft.  ',
      });
      expect(input.comment, 'Cooks soft.');
    });

    test('an empty comment is stored as nothing, not as empty text', () {
      final input = cleanReviewInput(<String, dynamic>{
        'stars': 4,
        'comment': '   ',
      });
      expect(input.comment, isNull);
    });

    test('300 characters is allowed', () {
      final input = cleanReviewInput(<String, dynamic>{
        'stars': 4,
        'comment': 'a' * reviewCommentMaxLength,
      });
      expect(input.comment!.length, 300);
    });

    test('301 characters is refused', () {
      final error = _apiError(
        () => cleanReviewInput(<String, dynamic>{
          'stars': 4,
          'comment': 'a' * (reviewCommentMaxLength + 1),
        }),
      );
      expect(error.message, 'comment is longer than 300 characters');
    });

    test('a comment that is not text is refused', () {
      final error = _apiError(
        () => cleanReviewInput(<String, dynamic>{'stars': 4, 'comment': 7}),
      );
      expect(error.message, 'comment must be text');
    });

    test('a body that is not an object is refused', () {
      final error = _apiError(() => cleanReviewInput('stars=5'));
      expect(error.message, 'Body must be a JSON object');
    });
  });

  group('the round avatar on screen 17', () {
    test('two names give two letters', () {
      expect(reviewInitials('Dara Vuth'), 'DV');
    });

    test('one name gives one letter', () {
      expect(reviewInitials('Bopha'), 'B');
    });

    test('extra spaces do not matter', () {
      expect(reviewInitials('  rithy   kong  '), 'RK');
    });

    test('an empty name still gets something to draw', () {
      expect(reviewInitials('   '), '?');
    });
  });

  group('the rating block on screen 17', () {
    test('a product with no reviews shows zero everywhere', () {
      final summary = ratingSummary(const []);
      expect(summary['average'], 0.0);
      expect(summary['count'], 0);
      final breakdown = summary['breakdown']! as Map<String, int>;
      expect(breakdown.keys, ['5', '4', '3', '2', '1']);
      expect(breakdown.values.every((n) => n == 0), isTrue);
    });

    test('the mock numbers average 4.5 out of 18', () {
      // 12 five star, 4 four star, 1 three, 1 two, 0 one: the bars on the mock.
      final reviews = <Map<String, dynamic>>[
        for (var i = 0; i < 12; i++) _doc(stars: 5),
        for (var i = 0; i < 4; i++) _doc(stars: 4),
        _doc(stars: 3),
        _doc(stars: 2),
      ];
      final summary = ratingSummary(reviews);
      expect(summary['average'], 4.5);
      expect(summary['count'], 18);
      final breakdown = summary['breakdown']! as Map<String, int>;
      expect(breakdown['5'], 12);
      expect(breakdown['4'], 4);
      expect(breakdown['3'], 1);
      expect(breakdown['2'], 1);
      expect(breakdown['1'], 0);
    });

    test('the average keeps one decimal place', () {
      final summary = ratingSummary([
        _doc(stars: 4),
        _doc(stars: 4),
        _doc(stars: 5),
      ]);
      // 13 / 3 = 4.333... which the screen prints as 4.3.
      expect(summary['average'], 4.3);
    });

    test('a star value the database should never hold is ignored', () {
      final summary = ratingSummary([_doc(stars: 5), _doc(stars: 0)]);
      expect(summary['count'], 1);
      expect(summary['average'], 5.0);
    });
  });

  group('one review as the app receives it', () {
    test('it carries a hex id, the initials and the verified flag', () {
      final view = reviewView(_doc(stars: 5, comment: 'Fresh and fragrant.'));
      expect((view['id']! as String).length, 24);
      expect(view['initials'], 'DV');
      expect(view['stars'], 5);
      expect(view['comment'], 'Fresh and fragrant.');
      expect(view['verifiedPurchase'], isTrue);
      expect(view['orderNumber'], 'FH-1042');
      expect(view['createdAt'], '2026-11-06T09:30:00.000Z');
    });

    test('a review with no comment sends null, not an empty string', () {
      expect(reviewView(_doc(stars: 3))['comment'], isNull);
    });

    test('a review with no author name still has a name to print', () {
      final doc = _doc(stars: 3)..remove('authorName');
      expect(reviewView(doc)['authorName'], 'Customer');
    });
  });

  group('which order can be reviewed', () {
    test('a delivered order tells us when it arrived', () {
      final order = <String, dynamic>{
        'statusHistory': [
          {'status': 'pending', 'at': '2026-11-05T02:00:00.000Z'},
          {'status': 'delivered', 'at': '2026-11-08T05:00:00.000Z'},
        ],
      };
      expect(deliveredAt(order), '2026-11-08T05:00:00.000Z');
    });

    test('an order that never arrived has no delivery date', () {
      final order = <String, dynamic>{
        'statusHistory': [
          {'status': 'pending', 'at': '2026-11-05T02:00:00.000Z'},
        ],
      };
      expect(deliveredAt(order), isNull);
    });
  });

  group('the query string on screen 17', () {
    test('productId is required', () {
      final error = _apiError(() => cleanProductId(null));
      expect(error.statusCode, 400);
      expect(error.message, 'productId is required');
    });

    test('a productId that is not an id is a different mistake', () {
      final error = _apiError(() => cleanProductId('not-an-id'));
      expect(error.message, 'productId is not a valid id');
    });

    test('a real hex id parses', () {
      final id = ObjectId();
      expect(cleanProductId(id.oid).oid, id.oid);
    });

    test('paging defaults to page 1 and 20 rows', () {
      final query = <String, String>{};
      expect(cleanPage(query), 1);
      expect(cleanLimit(query), 20);
    });

    test('page 0 is refused', () {
      final error = _apiError(() => cleanPage(<String, String>{'page': '0'}));
      expect(error.message, 'page must be 1 or more and limit 1 to 100');
    });

    test('a limit over 100 is refused', () {
      final error = _apiError(
        () => cleanLimit(<String, String>{'limit': '500'}),
      );
      expect(error.statusCode, 400);
    });

    test('a limit of 100 is the largest allowed', () {
      expect(cleanLimit(<String, String>{'limit': '100'}), 100);
    });
  });
}
