// The admin's customer list, and the order history behind each customer.
// Collections: users, orders, addresses

import 'package:faheng_api/services/admin_order_service.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:mongo_dart/mongo_dart.dart';

const customerTypes = <String>['business', 'household'];

class CustomerTotals {
  const CustomerTotals({
    required this.orders,
    required this.totalSpentCents,
    required this.firstOrderAt,
    required this.lastOrderAt,
  });
  final int orders;
  final int totalSpentCents;
  final DateTime? firstOrderAt;
  final DateTime? lastOrderAt;

  int get averageOrderCents =>
      orders == 0 ? 0 : (totalSpentCents / orders).round();
}

CustomerTotals customerTotals(List<Map<String, dynamic>> orders) {
  var count = 0;
  var cents = 0;
  DateTime? first;
  DateTime? last;
  for (final order in orders) {
    if (order['status'] == 'cancelled') continue;
    count++;
    cents += ((order['grandTotalCents'] as num?) ?? 0).round();
    final created = order['createdAt'];
    if (created is DateTime) {
      if (first == null || created.isBefore(first)) first = created;
      if (last == null || created.isAfter(last)) last = created;
    }
  }
  return CustomerTotals(
    orders: count,
    totalSpentCents: cents,
    firstOrderAt: first,
    lastOrderAt: last,
  );
}

String? townOf(List<Map<String, dynamic>> addresses) {
  if (addresses.isEmpty) return null;
  for (final address in addresses) {
    if (address['isDefault'] == true) return address['town'] as String?;
  }
  return addresses.last['town'] as String?;
}

Map<String, dynamic> adminCustomerRow(
  Map<String, dynamic> user, {
  required CustomerTotals totals,
  required String? town,
}) {
  final joinedAt = user['createdAt'];
  return <String, dynamic>{
    'id': (user['_id'] as ObjectId).oid,
    'name': user['name'],
    'phone': user['phone'],
    'email': user['email'],
    'customerType': user['customerType'] ?? 'household',
    'town': town,
    'orders': totals.orders,
    'totalSpent': totals.totalSpentCents / 100,
    'lastOrderAt': totals.lastOrderAt?.toIso8601String(),
    if (joinedAt is DateTime) 'joinedAt': joinedAt.toIso8601String(),
  };
}

String? cleanCustomerType(Map<String, String> query) {
  final raw = (query['customerType'] ?? 'all').trim().toLowerCase();
  if (raw == 'all' || raw.isEmpty) return null;
  if (!customerTypes.contains(raw)) {
    throw const ApiError(
      400,
      'customerType must be all, business or household',
    );
  }
  return raw;
}

SelectorBuilder buildCustomerQuery(Map<String, String> query) {
  final selector = SelectorBuilder()..ne('role', 'admin');
  final type = cleanCustomerType(query);
  if (type != null) selector.eq('customerType', type);
  return selector;
}

Future<Map<String, List<Map<String, dynamic>>>> _addressesFor(
  Db db,
  List<ObjectId> userIds,
) async {
  if (userIds.isEmpty) return <String, List<Map<String, dynamic>>>{};
  final docs = await db
      .collection('addresses')
      .find(where.oneFrom('userId', userIds))
      .toList();
  final grouped = <String, List<Map<String, dynamic>>>{};
  for (final doc in docs) {
    final key = (doc['userId'] as ObjectId).oid;
    grouped.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(doc);
  }

  for (final list in grouped.values) {
    list.sort((a, b) {
      final left = a['createdAt'];
      final right = b['createdAt'];
      if (left is DateTime && right is DateTime) return left.compareTo(right);
      return 0;
    });
  }
  return grouped;
}

Future<Map<String, List<Map<String, dynamic>>>> _ordersFor(
  Db db,
  List<ObjectId> userIds,
) async {
  if (userIds.isEmpty) return <String, List<Map<String, dynamic>>>{};
  final docs = await db
      .collection('orders')
      .find(where.oneFrom('userId', userIds))
      .toList();
  final grouped = <String, List<Map<String, dynamic>>>{};
  for (final doc in docs) {
    final key = (doc['userId'] as ObjectId).oid;
    grouped.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(doc);
  }
  return grouped;
}

Future<Map<String, dynamic>> adminListCustomers(
  Db db,
  Map<String, String> query,
) async {
  final page = int.tryParse(query['page'] ?? '') ?? 1;
  final limit = int.tryParse(query['limit'] ?? '') ?? 20;
  if (page < 1 || limit < 1 || limit > 100) {
    throw const ApiError(400, 'page must be 1 or more and limit 1 to 100');
  }

  final users = db.collection('users');
  final selector = buildCustomerQuery(query);
  final term = (query['q'] ?? '').trim();
  if (term.isNotEmpty) {
    final pattern = RegExp.escape(term);
    final byName = await users
        .find(where.match('name', pattern, caseInsensitive: true))
        .toList();
    final byPhone = await users
        .find(where.match('phone', pattern, caseInsensitive: true))
        .toList();
    final ids = <ObjectId>{
      for (final doc in [...byName, ...byPhone]) doc['_id'] as ObjectId,
    }.toList();
    if (ids.isEmpty) {
      return <String, dynamic>{
        'items': const <Map<String, dynamic>>[],
        'total': 0,
        'page': page,
        'limit': limit,
        'summary': await _customerSummary(db),
      };
    }
    selector.oneFrom('_id', ids);
  }

  final total = await users.count(selector);
  final paged = buildCustomerQuery(query)
    ..sortBy('name')
    ..skip((page - 1) * limit)
    ..limit(limit);
  if (term.isNotEmpty) {
    final all = await users.find(selector).toList();
    paged.oneFrom(
      '_id',
      [for (final doc in all) doc['_id'] as ObjectId],
    );
  }
  final docs = await users.find(paged).toList();
  final ids = [for (final doc in docs) doc['_id'] as ObjectId];
  final orders = await _ordersFor(db, ids);
  final addresses = await _addressesFor(db, ids);

  return <String, dynamic>{
    'items': [
      for (final doc in docs)
        adminCustomerRow(
          doc,
          totals: customerTotals(
            orders[(doc['_id'] as ObjectId).oid] ??
                const <Map<String, dynamic>>[],
          ),
          town: townOf(
            addresses[(doc['_id'] as ObjectId).oid] ??
                const <Map<String, dynamic>>[],
          ),
        ),
    ],
    'total': total,
    'page': page,
    'limit': limit,
    'summary': await _customerSummary(db),
  };
}

Future<Map<String, dynamic>> _customerSummary(Db db) async {
  final buyers = await db
      .collection('users')
      .find(SelectorBuilder()..ne('role', 'admin'))
      .toList();
  var businesses = 0;
  var households = 0;
  for (final user in buyers) {
    if (user['customerType'] == 'business') {
      businesses++;
    } else {
      households++;
    }
  }
  return <String, dynamic>{
    'customers': buyers.length,
    'businesses': businesses,
    'households': households,
  };
}

ObjectId _parseCustomerId(String raw) {
  try {
    return ObjectId.fromHexString(raw.trim());
  } catch (_) {
    throw const ApiError(404, 'Customer not found');
  }
}

Future<Map<String, dynamic>> _findCustomer(Db db, String rawId) async {
  final user = await db
      .collection('users')
      .findOne(where.id(_parseCustomerId(rawId)).ne('role', 'admin'));
  if (user == null) throw const ApiError(404, 'Customer not found');
  return user;
}

Future<Map<String, dynamic>> adminCustomerDetail(Db db, String rawId) async {
  final user = await _findCustomer(db, rawId);
  final userId = user['_id'] as ObjectId;

  final orders = await db
      .collection('orders')
      .find(where.eq('userId', userId))
      .toList();
  final totals = customerTotals(orders);
  final addresses = await _addressesFor(db, [userId]);
  final list = addresses[userId.oid] ?? const <Map<String, dynamic>>[];
  Map<String, dynamic>? chosen;
  for (final address in list) {
    if (address['isDefault'] == true) chosen = address;
  }
  chosen ??= list.isEmpty ? null : list.last;

  final recent =
      orders.where((order) => order['status'] != 'cancelled').toList()..sort((
        a,
        b,
      ) {
        final left = a['createdAt'];
        final right = b['createdAt'];
        if (left is DateTime && right is DateTime) return right.compareTo(left);
        return 0;
      });
  final joinedAt = user['createdAt'];

  return <String, dynamic>{
    'customer': <String, dynamic>{
      'id': userId.oid,
      'name': user['name'],
      'phone': user['phone'],
      'email': user['email'],
      'customerType': user['customerType'] ?? 'household',
      'town': townOf(list),
      'addressesCount': list.length,
      'address': chosen == null
          ? null
          : <String, dynamic>{
              'id': (chosen['_id'] as ObjectId).oid,
              'label': chosen['label'],
              'receiverName': chosen['receiverName'],
              'phone': chosen['phone'],
              'street': chosen['street'],
              'town': chosen['town'],
              'isDefault': chosen['isDefault'] == true,
            },
      if (joinedAt is DateTime) 'joinedAt': joinedAt.toIso8601String(),
    },
    'summary': <String, dynamic>{
      'orders': totals.orders,
      'totalSpent': totals.totalSpentCents / 100,
      'averageOrder': totals.averageOrderCents / 100,
      'firstOrderAt': totals.firstOrderAt?.toIso8601String(),
      'lastOrderAt': totals.lastOrderAt?.toIso8601String(),
    },
    'orders': [
      for (final order in recent.take(5)) adminOrderRow(order, customer: user),
    ],
    'showing': recent.take(5).length,
    'totalOrders': recent.length,
  };
}

Future<Map<String, dynamic>> adminCustomerOrders(
  Db db,
  String rawId,
  Map<String, String> query,
) async {
  final page = int.tryParse(query['page'] ?? '') ?? 1;
  final limit = int.tryParse(query['limit'] ?? '') ?? 20;
  if (page < 1 || limit < 1 || limit > 100) {
    throw const ApiError(400, 'page must be 1 or more and limit 1 to 100');
  }

  final user = await _findCustomer(db, rawId);
  final selector = SelectorBuilder()
    ..eq('userId', user['_id'] as ObjectId)
    ..ne('status', 'cancelled');
  final collection = db.collection('orders');
  final total = await collection.count(selector);
  final docs = await collection
      .find(
        SelectorBuilder()
          ..eq('userId', user['_id'] as ObjectId)
          ..ne('status', 'cancelled')
          ..sortBy('createdAt', descending: true)
          ..skip((page - 1) * limit)
          ..limit(limit),
      )
      .toList();

  return <String, dynamic>{
    'items': [
      for (final doc in docs) adminOrderRow(doc, customer: user),
    ],
    'total': total,
    'page': page,
    'limit': limit,
  };
}
