// In-app notifications. We store and list them; we never push them.
// Collections: notifications, quotes

import 'package:faheng_api/services/api_error.dart';
import 'package:mongo_dart/mongo_dart.dart';

const notificationTypes = <String>[
  'order_placed',
  'order_processing',
  'order_on_the_way',
  'order_delivered',
  'order_cancelled',
  'quote_ready',

  'payment_received',
];

String windowLabel(String? window) {
  switch (window) {
    case 'morning':
      return '8:00 – 11:00';
    case 'afternoon':
      return '13:00 – 17:00';
  }
  return '';
}

String moneyLabel(Object? cents) {
  final value = cents is num ? cents.toDouble() / 100 : 0.0;
  return '\$${value.toStringAsFixed(2)}';
}

const paymentLabels = <String, String>{
  'paypal': 'PayPal',
  'cod': 'Cash on delivery',
};

Map<String, dynamic>? orderNotification(Map<String, dynamic> order) {
  final number = order['orderNumber'] as String? ?? 'your order';
  final status = order['status'] as String? ?? '';
  final window = windowLabel(order['deliveryWindow'] as String?);
  switch (status) {
    case 'pending':
      return <String, dynamic>{
        'type': 'order_placed',
        'title': 'Order $number placed',
        'body':
            '${moneyLabel(order['grandTotalCents'])} · '
            '${paymentLabels[order['paymentMethod']] ?? 'Cash on delivery'}',
      };
    case 'processing':
      return <String, dynamic>{
        'type': 'order_processing',
        'title': 'Order $number is being packed',
        'body': 'We are weighing and packing your rice.',
      };
    case 'on_the_way':
      return <String, dynamic>{
        'type': 'order_on_the_way',
        'title': 'Order $number is on the way',
        'body': 'Arriving today, $window.',
      };
    case 'delivered':
      return <String, dynamic>{
        'type': 'order_delivered',
        'title': 'Order $number was delivered',
        'body': 'How was your rice?',
      };
    case 'cancelled':
      return <String, dynamic>{
        'type': 'order_cancelled',
        'title': 'Order $number was cancelled',
        'body': 'The rice went back on the shelf. Nothing was charged.',
      };
  }
  return null;
}

Future<void> addNotification(
  Db db, {
  required ObjectId userId,
  required String type,
  required String title,
  required String body,
  ObjectId? orderId,
  ObjectId? quoteId,
}) async {
  if (!notificationTypes.contains(type)) return;
  try {
    await db.collection('notifications').insertOne(<String, dynamic>{
      '_id': ObjectId(),
      'userId': userId,
      'type': type,
      'title': title,
      'body': body,
      if (orderId != null) 'orderId': orderId,
      if (quoteId != null) 'quoteId': quoteId,
      'read': false,
      'createdAt': DateTime.now().toUtc(),
    });
  } catch (_) {
  }
}

Future<void> notifyOrder(Db db, Map<String, dynamic> order) async {
  final wording = orderNotification(order);
  if (wording == null) return;
  final userId = order['userId'];
  if (userId is! ObjectId) return;
  await addNotification(
    db,
    userId: userId,
    type: wording['type']! as String,
    title: wording['title']! as String,
    body: wording['body']! as String,
    orderId: order['_id'] as ObjectId?,
  );
}

Map<String, dynamic> notificationView(
  Map<String, dynamic> doc, {
  String? quoteStatus,
}) {
  final createdAt = doc['createdAt'];
  final type = doc['type'] as String? ?? '';
  final isQuote = type == 'quote_ready';
  return <String, dynamic>{
    'id': (doc['_id'] as ObjectId).oid,
    'type': type,
    'title': doc['title'],
    'body': doc['body'],
    'read': doc['read'] == true,
    if (doc['orderId'] is ObjectId) 'orderId': (doc['orderId'] as ObjectId).oid,
    if (doc['quoteId'] is ObjectId) 'quoteId': (doc['quoteId'] as ObjectId).oid,

    if (isQuote) 'canRespond': quoteStatus == 'quoted',
    if (isQuote) 'quoteStatus': quoteStatus,
    if (createdAt is DateTime) 'createdAt': createdAt.toIso8601String(),
  };
}

Future<Map<String, dynamic>> listNotifications(
  Db db,
  ObjectId userId,
  Map<String, String> query,
) async {
  final page = int.tryParse(query['page'] ?? '') ?? 1;
  final limit = int.tryParse(query['limit'] ?? '') ?? 20;
  if (page < 1 || limit < 1 || limit > 100) {
    throw const ApiError(400, 'page must be 1 or more and limit 1 to 100');
  }

  final collection = db.collection('notifications');
  final selector = SelectorBuilder()..eq('userId', userId);
  final total = await collection.count(selector);
  final docs = await collection
      .find(
        SelectorBuilder()
          ..eq('userId', userId)
          ..sortBy('createdAt', descending: true)
          ..skip((page - 1) * limit)
          ..limit(limit),
      )
      .toList();

  final quoteIds = docs
      .where((doc) => doc['type'] == 'quote_ready')
      .map((doc) => doc['quoteId'])
      .whereType<ObjectId>()
      .toList();
  final quoteStatus = <String, String>{};
  if (quoteIds.isNotEmpty) {
    final quotes = await db
        .collection('quotes')
        .find(where.oneFrom('_id', quoteIds))
        .toList();
    for (final quote in quotes) {
      quoteStatus[(quote['_id'] as ObjectId).oid] = quote['status'] as String;
    }
  }

  final unread = await collection.count(
    SelectorBuilder()
      ..eq('userId', userId)
      ..eq('read', false),
  );

  return <String, dynamic>{
    'items': [
      for (final doc in docs)
        notificationView(
          doc,
          quoteStatus: quoteStatus[(doc['quoteId'] as ObjectId?)?.oid],
        ),
    ],
    'total': total,
    'unread': unread,
    'page': page,
    'limit': limit,
  };
}

Future<Map<String, dynamic>> unreadNotifications(Db db, ObjectId userId) async {
  final unread = await db
      .collection('notifications')
      .count(
        SelectorBuilder()
          ..eq('userId', userId)
          ..eq('read', false),
      );
  return <String, dynamic>{'unread': unread};
}

Future<Map<String, dynamic>> markAllNotificationsRead(
  Db db,
  ObjectId userId,
) async {
  final result = await db
      .collection('notifications')
      .updateMany(
        where.eq('userId', userId).eq('read', false),
        modify.set('read', true),
      );
  return <String, dynamic>{
    'unread': 0,
    'marked': result.nModified,
  };
}

Future<Map<String, dynamic>> markNotificationRead(
  Db db,
  ObjectId userId,
  String rawId,
) async {
  ObjectId id;
  try {
    id = ObjectId.parse(rawId);
  } catch (_) {
    throw const ApiError(404, 'Notification not found');
  }

  final collection = db.collection('notifications');
  final doc = await collection.findOne(where.id(id).eq('userId', userId));
  if (doc == null) throw const ApiError(404, 'Notification not found');

  if (doc['read'] != true) {
    await collection.updateOne(where.id(id), modify.set('read', true));
    doc['read'] = true;
  }

  String? quoteStatus;
  final quoteId = doc['quoteId'];
  if (quoteId is ObjectId) {
    final quote = await db.collection('quotes').findOne(where.id(quoteId));
    quoteStatus = quote?['status'] as String?;
  }
  return notificationView(doc, quoteStatus: quoteStatus);
}
