import 'package:faheng_api/services/notification_service.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:test/test.dart';

/// One order document, cut down to the fields the notification text needs.
Map<String, dynamic> _order(
  String status, {
  String window = 'morning',
  String method = 'cod',
}) => <String, dynamic>{
  '_id': ObjectId(),
  'userId': ObjectId(),
  'orderNumber': 'FH-1042',
  'status': status,
  'deliveryWindow': window,
  'paymentMethod': method,
  'grandTotalCents': 17020,
};

void main() {
  group('the sentences on screen 31', () {
    test('a placed order says what it costs and how it is paid', () {
      final wording = orderNotification(_order('pending'))!;
      expect(wording['type'], 'order_placed');
      expect(wording['title'], 'Order FH-1042 placed');
      expect(wording['body'], r'$170.20 · Cash on delivery');
    });

    test('a PayPal order is not announced as cash on delivery', () {
      // Screen 23b prints "PayPal · Paid"; the bell must not disagree.
      final wording = orderNotification(_order('pending', method: 'paypal'))!;
      expect(wording['body'], r'$170.20 · PayPal');
      expect(wording['body'], isNot(contains('Cash on delivery')));
    });

    test('a packing order is being packed', () {
      final wording = orderNotification(_order('processing'))!;
      expect(wording['title'], 'Order FH-1042 is being packed');
    });

    test('an order on the way carries the morning hours', () {
      final wording = orderNotification(_order('on_the_way'))!;
      expect(wording['title'], 'Order FH-1042 is on the way');
      expect(wording['body'], 'Arriving today, 8:00 – 11:00.');
    });

    test('the afternoon window prints its own hours', () {
      final wording = orderNotification(
        _order('on_the_way', window: 'afternoon'),
      )!;
      expect(wording['body'], 'Arriving today, 13:00 – 17:00.');
    });

    test('a delivered order asks how the rice was', () {
      final wording = orderNotification(_order('delivered'))!;
      expect(wording['type'], 'order_delivered');
      expect(wording['body'], 'How was your rice?');
    });

    test('a cancelled order says nothing was charged', () {
      final wording = orderNotification(_order('cancelled'))!;
      expect(wording['type'], 'order_cancelled');
      expect(wording['body'], contains('Nothing was charged'));
    });

    test('a status nobody should be told about writes nothing', () {
      expect(orderNotification(_order('archived')), isNull);
    });
  });

  group('the small helpers', () {
    test('a missing window prints nothing at all', () {
      expect(windowLabel(null), '');
      expect(windowLabel('evening'), '');
    });

    test('money is printed with two decimals', () {
      expect(moneyLabel(17020), r'$170.20');
      expect(moneyLabel(108), r'$1.08');
      expect(moneyLabel(0), r'$0.00');
      expect(moneyLabel(null), r'$0.00');
    });
  });

  group('one notification as the app receives it', () {
    test('an unread order notification', () {
      final view = notificationView(<String, dynamic>{
        '_id': ObjectId(),
        'userId': ObjectId(),
        'type': 'order_on_the_way',
        'title': 'Order FH-1042 is on the way',
        'body': 'Arriving today, 8:00 – 11:00.',
        'orderId': ObjectId(),
        'read': false,
        'createdAt': DateTime.utc(2026, 11, 7, 7, 45),
      });
      expect((view['id']! as String).length, 24);
      expect(view['read'], isFalse);
      expect(view['type'], 'order_on_the_way');
      expect((view['orderId']! as String).length, 24);
      expect(view['createdAt'], '2026-11-07T07:45:00.000Z');
      // An order notification has no Accept button.
      expect(view.containsKey('canRespond'), isFalse);
    });

    test('a quote notification keeps its buttons while it is unanswered', () {
      final view = notificationView(
        <String, dynamic>{
          '_id': ObjectId(),
          'type': 'quote_ready',
          'title': 'Your quote is ready',
          'body': r'Jasmine rice, 200 kg at $1.08 per kg.',
          'quoteId': ObjectId(),
          'read': false,
        },
        quoteStatus: 'quoted',
      );
      expect(view['canRespond'], isTrue);
      expect(view['quoteStatus'], 'quoted');
    });

    test('the buttons go away once the buyer answered', () {
      final view = notificationView(
        <String, dynamic>{
          '_id': ObjectId(),
          'type': 'quote_ready',
          'title': 'Your quote is ready',
          'body': r'Jasmine rice, 200 kg at $1.08 per kg.',
          'quoteId': ObjectId(),
          'read': true,
        },
        quoteStatus: 'accepted',
      );
      expect(view['canRespond'], isFalse);
      expect(view['quoteStatus'], 'accepted');
    });
  });
}
