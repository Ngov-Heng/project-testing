/*
This is the store owner's backend control center. Every route under /api/admin runs adminGuard first and then calls these functions to power the owner's dashboard, filter/search orders, update delivery statuses, mark cash orders as paid, and manage the weekly delivery schedule.
*/

import 'package:faheng_api/services/api_error.dart';
import 'package:faheng_api/services/notification_service.dart';
import 'package:faheng_api/services/order_service.dart';
import 'package:faheng_api/services/product_service.dart';
import 'package:mongo_dart/mongo_dart.dart';

/*
Defines admin rules (150kg heavy order badge, valid order/payment statuses)
and date helpers converted to Phnom Penh time (UTC+7) so "today" and weekly
schedules match Cambodia local time instead of UTC.
*/

/// Screen 40 marks "Heavy: orders of 150 kg or more" with a badge.
const num heavyOrderKg = 150;

/// The two payment states the owner can set by hand (screen 39, cash orders).
const List<String> adminPaymentStatuses = <String>['unpaid', 'paid'];

/// The sort orders the "Newest first" dropdown on screen 38 offers.
const List<String> adminOrderSorts = <String>['newest', 'oldest'];

/// Every status an order can have, in the order the stepper on screen 39 uses.
const List<String> orderStatuses = <String>[
  'pending',
  'processing',
  'on_the_way',
  'delivered',
  'cancelled',
];

/// True when screen 40 should put the orange "Heavy" badge on the card.
bool isHeavyOrder(num totalWeightKg) => totalWeightKg >= heavyOrderKg;

/// Reads a "YYYY-MM-DD" day, or throws the message the filter can show.
DateTime cleanDay(Object? value, String field) {
  if (value is! String || value.trim().isEmpty) {
    throw ApiError(400, '$field is required as YYYY-MM-DD');
  }
  final text = value.trim();
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text);
  if (match == null) {
    throw ApiError(400, '$field must look like 2026-11-08');
  }
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day) {
    throw ApiError(400, '$field is not a real date');
  }
  return date;
}

/// The day part of a UTC timestamp, in Phnom Penh time (UTC+7), as
/// "YYYY-MM-DD". The owner's "today" is a Phnom Penh day, not a UTC one.
String phnomPenhDayKey(DateTime utc) {
  final local = utc.toUtc().add(const Duration(hours: 7));
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}

/// The Phnom Penh calendar date that contains [utc], as a UTC midnight. This
/// is the date a person would write down, which is what a week is built from.
DateTime phnomPenhDate(DateTime utc) {
  final local = utc.toUtc().add(const Duration(hours: 7));
  return DateTime.utc(local.year, local.month, local.day);
}

/// The instant the Phnom Penh day that contains [utc] begins, in UTC. Used as
/// the boundary when the dashboard counts orders. Do not use it as a date: at
/// 20:00 UTC it is still the previous UTC day.
///
DateTime phnomPenhDayStart(DateTime utc) {
  final local = utc.toUtc().add(const Duration(hours: 7));
  return DateTime.utc(
    local.year,
    local.month,
    local.day,
  ).subtract(const Duration(hours: 7));
}

/*
Parses URL query parameters (page, limit, status, date range, search term)
and builds MongoDB selectors. Resolves text search across order numbers,
receiver names, and the users collection before querying orders.
*/

/// The filters on screen 38: search, status, a date range and the sort order.
class AdminOrderFilters {
  /// Creates a checked filter set.
  const AdminOrderFilters({
    required this.page,
    required this.limit,
    required this.sort,
    this.status,
    this.search,
    this.from,
    this.to,
  });

  /// 1-based page number.
  final int page;

  /// Rows per page (the screen offers 8, 20, 50).
  final int limit;

  /// newest or oldest.
  final String sort;

  /// One status, or null for "All statuses".
  final String? status;

  /// Order number or customer name typed in the search box.
  final String? search;

  /// First day of the range, or null for no lower bound.
  final DateTime? from;

  /// Last day of the range, inclusive, or null for no upper bound.
  final DateTime? to;
}

/// Reads the query string of screen 38.
AdminOrderFilters adminOrderFilters(Map<String, String> query) {
  final page = int.tryParse(query['page'] ?? '') ?? 1;
  final limit = int.tryParse(query['limit'] ?? '') ?? 20;
  if (page < 1 || limit < 1 || limit > 100) {
    throw const ApiError(400, 'page must be 1 or more and limit 1 to 100');
  }

  final statusRaw = (query['status'] ?? '').trim().toLowerCase();
  if (statusRaw.isNotEmpty &&
      statusRaw != 'all' &&
      !orderStatuses.contains(statusRaw)) {
    throw const ApiError(
      400,
      'status must be all, pending, processing, on_the_way, delivered '
      'or cancelled',
    );
  }

  final sort = (query['sort'] ?? 'newest').trim().toLowerCase();
  if (!adminOrderSorts.contains(sort)) {
    throw const ApiError(400, 'sort must be newest or oldest');
  }

  final fromRaw = query['from'];
  final toRaw = query['to'];
  final from = fromRaw == null || fromRaw.isEmpty
      ? null
      : cleanDay(fromRaw, 'from');
  final to = toRaw == null || toRaw.isEmpty ? null : cleanDay(toRaw, 'to');
  if (from != null && to != null && from.isAfter(to)) {
    throw const ApiError(400, 'from cannot be after to');
  }

  final search = query['q']?.trim();
  return AdminOrderFilters(
    page: page,
    limit: limit,
    sort: sort,
    status: (statusRaw.isEmpty || statusRaw == 'all') ? null : statusRaw,
    search: (search == null || search.isEmpty) ? null : search,
    from: from,
    to: to,
  );
}

/// Builds the filter half of screen 38's query: status and the date range.
/// The search box is added separately, because a customer name lives in
/// `users` and the order number and receiver live in the order itself, so the
/// text is resolved to a list of order ids first.
///
/// The builder is used directly by `count()` and `find()`. Never wrap it in
/// `where.raw(map)`: that call stores the map but drops it from the query, so
/// every filter would quietly return the whole table.
SelectorBuilder buildOrderQuery(AdminOrderFilters filters) {
  final selector = SelectorBuilder();
  if (filters.status != null) {
    selector.eq('status', filters.status);
  }
  if (filters.from != null) {
    selector.gte('createdAt', filters.from);
  }
  if (filters.to != null) {
    selector.lt('createdAt', filters.to!.add(const Duration(days: 1)));
  }
  return selector;
}

/// The orders whose number, receiver name or customer name contains [term].
/// The customer-name branch starts from `users`, which is why this is not one
/// regex on one field.
Future<List<ObjectId>> searchOrderIds(Db db, String term) async {
  final pattern = RegExp.escape(term);
  final orders = db.collection('orders');
  final byNumber = await orders
      .find(where.match('orderNumber', pattern, caseInsensitive: true))
      .toList();
  final byReceiver = await orders
      .find(where.match('address.receiverName', pattern, caseInsensitive: true))
      .toList();
  final users = await db
      .collection('users')
      .find(where.match('name', pattern, caseInsensitive: true))
      .toList();
  final ids = users.map((user) => user['_id']).whereType<ObjectId>().toList();
  final byCustomer = ids.isEmpty
      ? const <Map<String, dynamic>>[]
      : await orders.find(where.oneFrom('userId', ids)).toList();
  return <ObjectId>{
    for (final doc in [...byNumber, ...byReceiver, ...byCustomer])
      doc['_id'] as ObjectId,
  }.toList();
}

/*
Formats MongoDB order documents into clean table rows (attaching customer
names in a single batch query) and returns paginated results alongside
total status counts for the orders table header.
*/

/// How many orders sit in each status, for the line under the page title
/// ("48 orders in November - 6 pending, 3 on the way").
Map<String, int> statusCounts(Iterable<Map<String, dynamic>> docs) {
  final counts = <String, int>{for (final status in orderStatuses) status: 0};
  for (final doc in docs) {
    final status = doc['status'];
    if (status is String && counts.containsKey(status)) {
      counts[status] = counts[status]! + 1;
    }
  }
  return counts;
}

/// One row of the table on screen 38, and one card on screen 39/40.
Map<String, dynamic> adminOrderRow(
  Map<String, dynamic> order, {
  Map<String, dynamic>? customer,
}) {
  final items = ((order['items'] as List?) ?? const <dynamic>[])
      .map((raw) => Map<String, dynamic>.from(raw as Map))
      .toList();
  final weight = (order['totalWeightKg'] as num?) ?? 0;
  final address = (order['address'] as Map?) ?? const <String, dynamic>{};
  return <String, dynamic>{
    'id': (order['_id'] as ObjectId).oid,
    'orderNumber': order['orderNumber'],
    'customerName': customer?['name'] ?? address['receiverName'] ?? 'Buyer',
    'town': address['town'],
    'itemCount': items.length,
    'itemSummary': items.isEmpty
        ? null
        : '${items.first['name']}'
              '${items.length > 1 ? ' + ${items.length - 1} more' : ''}',
    'totalWeightKg': weight,
    'heavy': isHeavyOrder(weight),
    'total': ((order['grandTotalCents'] as num?) ?? 0) / 100,
    'status': order['status'],
    'paymentMethod': order['paymentMethod'],
    'paymentStatus': order['paymentStatus'],
    'deliveryDate': order['deliveryDate'],
    'deliveryWindow': order['deliveryWindow'],
    'scheduled': order['scheduledAt'] != null,
    'createdAt': order['createdAt'] is DateTime
        ? (order['createdAt'] as DateTime).toIso8601String()
        : order['createdAt'],
  };
}

/// Loads the users behind a page of orders in one query, so the table can show
/// names without asking Mongo once per row.
Future<Map<String, Map<String, dynamic>>> _customersFor(
  Db db,
  List<Map<String, dynamic>> orders,
) async {
  final ids = orders
      .map((order) => order['userId'])
      .whereType<ObjectId>()
      .toSet()
      .toList();
  if (ids.isEmpty) return <String, Map<String, dynamic>>{};
  final users = await db
      .collection('users')
      .find(where.oneFrom('_id', ids))
      .toList();
  return <String, Map<String, dynamic>>{
    for (final user in users) (user['_id'] as ObjectId).oid: user,
  };
}

/// Screen 38: the orders table with its header counts.
Future<Map<String, dynamic>> adminListOrders(
  Db db,
  Map<String, String> query,
) async {
  final filters = adminOrderFilters(query);
  final selector = buildOrderQuery(filters);
  final orders = db.collection('orders');

  if (filters.search != null) {
    final ids = await searchOrderIds(db, filters.search!);
    if (ids.isEmpty) {
      return <String, dynamic>{
        'items': const <Map<String, dynamic>>[],
        'total': 0,
        'page': filters.page,
        'limit': filters.limit,
        'summary': <String, dynamic>{'orders': 0, ...statusCounts(const [])},
      };
    }
    selector.oneFrom('_id', ids);
  }

  final total = await orders.count(selector);

  final paged = selector
      .sortBy('createdAt', descending: filters.sort == 'newest')
      .skip((filters.page - 1) * filters.limit)
      .limit(filters.limit);
  final docs = await orders.find(paged).toList();
  final customers = await _customersFor(db, docs);

  // The counts under the title are for the whole filter, not just this page,
  // so the same filter is asked again without the paging.
  final allInFilter = await orders.find(buildOrderQuery(filters)).toList();
  final counts = statusCounts(allInFilter);

  return <String, dynamic>{
    'items': [
      for (final doc in docs)
        adminOrderRow(
          doc,
          customer: customers[(doc['userId'] as ObjectId?)?.oid],
        ),
    ],
    'total': total,
    'page': filters.page,
    'limit': filters.limit,
    'summary': <String, dynamic>{
      'orders': allInFilter.length,
      ...counts,
    },
  };
}


/*
Handles single-order management: loads full order + customer profile,
advances order statuses using orderTransitions (restoring stock if cancelled
and notifying the buyer), and lets the owner mark cash orders as paid.
*/


/// Screen 39: one order, the customer card beside it, and the statuses the
/// dropdown may offer next (so the screen never shows a jump the server
/// would refuse).
Future<Map<String, dynamic>> adminOrderDetail(Db db, String rawId) async {
  final id = parseOrderId(rawId);
  final order = await db.collection('orders').findOne(where.id(id));
  if (order == null) throw const ApiError(404, 'Order not found');

  final userId = order['userId'];
  Map<String, dynamic>? user;
  var ordersCount = 0;
  if (userId is ObjectId) {
    user = await db.collection('users').findOne(where.id(userId));
    ordersCount = await db
        .collection('orders')
        .count(where.eq('userId', userId));
  }
  final status = order['status'] as String? ?? 'pending';
  final address = (order['address'] as Map?) ?? const <String, dynamic>{};

  return <String, dynamic>{
    'order': orderView(order),
    'customer': <String, dynamic>{
      if (user != null) 'id': (user['_id'] as ObjectId).oid,
      'name': user?['name'] ?? address['receiverName'],
      'phone': user?['phone'] ?? address['phone'],
      'customerType': user?['customerType'] ?? 'household',
      'ordersCount': ordersCount,
    },
    'allowedStatuses': orderTransitions[status] ?? const <String>[],
  };
}

/// Screen 39's "Update status" card. It walks orderTransitions and puts every
/// change in `statusHistory`, which is what the buyer's tracking screen reads.
/// Cancelling from here also puts the kg back, exactly like the buyer's cancel.
Future<Map<String, dynamic>> changeOrderStatus(
  Db db,
  String rawId,
  Object? body,
) async {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }
  final id = parseOrderId(rawId);
  final orders = db.collection('orders');
  final order = await orders.findOne(where.id(id));
  if (order == null) throw const ApiError(404, 'Order not found');

  final current = order['status'] as String? ?? 'pending';
  final statusRaw = body['status'];
  if (statusRaw is! String || statusRaw.trim().isEmpty) {
    throw const ApiError(400, 'status is required');
  }
  final next = statusRaw.trim().toLowerCase();
  if (!orderStatuses.contains(next)) {
    throw const ApiError(
      400,
      'status must be pending, processing, on_the_way, delivered '
      'or cancelled',
    );
  }
  if (next == current) {
    throw ApiError(409, 'The order is already $current');
  }
  if (!canChangeStatus(current, next)) {
    throw ApiError(
      409,
      'An order that is $current cannot become $next',
    );
  }
  if (next == 'cancelled') {
    if (!canCancel(current)) {
      throw const ApiError(
        409,
        'Only pending or processing orders can be cancelled',
      );
    }
    await restoreStockForOrder(db, order);
  }

  final now = DateTime.now().toUtc();
  final history = [
    ...((order['statusHistory'] as List?) ?? const <dynamic>[]),
    <String, dynamic>{'status': next, 'at': now.toIso8601String()},
  ];
  await orders.updateOne(
    where.id(id),
    modify
        .set('status', next)
        .set('statusHistory', history)
        .set('updatedAt', now),
  );

  // Screen 31 tells the buyer what happened: "Order FH-1042 is on the way".
  final moved = Map<String, dynamic>.from(order)
    ..['status'] = next
    ..['statusHistory'] = history;
  await notifyOrder(db, moved);

  return adminOrderDetail(db, rawId);
}

/// Screen 39's "mark cash as paid". PayPal is confirmed by the payment provider
/// in chunk 11, so a PayPal order cannot be flipped by hand here.
Future<Map<String, dynamic>> setAdminPaymentStatus(
  Db db,
  String rawId,
  Object? body,
) async {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }
  final id = parseOrderId(rawId);
  final orders = db.collection('orders');
  final order = await orders.findOne(where.id(id));
  if (order == null) throw const ApiError(404, 'Order not found');

  final raw = body['paymentStatus'];
  final asText = raw is String ? raw.trim().toLowerCase() : '';
  if (!adminPaymentStatuses.contains(asText)) {
    throw const ApiError(400, 'paymentStatus must be paid or unpaid');
  }
  final next = asText;
  if (order['paymentMethod'] == 'paypal') {
    throw const ApiError(
      400,
      'PayPal payments are confirmed by the provider, not by hand',
    );
  }
  if (order['status'] == 'cancelled') {
    throw const ApiError(409, 'A cancelled order cannot be paid');
  }

  final now = DateTime.now().toUtc();
  await orders.updateOne(
    where.id(id),
    modify
        .set('paymentStatus', next)
        .set('paidAt', next == 'paid' ? now : null)
        .set('updatedAt', now),
  );
  return adminOrderDetail(db, rawId);
}

/*
Assigns orders to a confirmed delivery date and morning/afternoon window,
and builds the Monday-to-Sunday delivery schedule grid separated from
unscheduled active orders.
*/

/// Screen 40's Schedule button: the order gets a confirmed slot. Until the
/// owner does this the order sits in "Unscheduled orders", which is why the
/// panel and the week grid never show the same order twice.
Future<Map<String, dynamic>> scheduleOrder(
  Db db,
  String rawId,
  Object? body,
) async {
  if (body is! Map<String, dynamic>) {
    throw const ApiError(400, 'Body must be a JSON object');
  }
  final id = parseOrderId(rawId);
  final orders = db.collection('orders');
  final order = await orders.findOne(where.id(id));
  if (order == null) throw const ApiError(404, 'Order not found');

  final status = order['status'] as String? ?? 'pending';
  if (status == 'delivered' || status == 'cancelled') {
    throw ApiError(409, 'A $status order has no delivery left to schedule');
  }

  final date = cleanDay(body['deliveryDate'], 'deliveryDate');
  // Compare calendar days, not instants: phnomPenhToday() is a UTC midnight
  // that stands for today's date in Cambodia.
  final days = date.difference(phnomPenhToday()).inDays;
  if (days < 0 || days > 14) {
    throw const ApiError(
      400,
      'deliveryDate must be today or within the next 14 days',
    );
  }
  final windowRaw = body['deliveryWindow'];
  final window = windowRaw is String ? windowRaw.trim().toLowerCase() : '';
  if (!deliveryWindows.contains(window)) {
    throw const ApiError(400, 'deliveryWindow must be morning or afternoon');
  }

  final now = DateTime.now().toUtc();
  await orders.updateOne(
    where.id(id),
    modify
        .set('deliveryDate', dayKey(date))
        .set('deliveryWindow', window)
        .set('scheduledAt', now)
        .set('updatedAt', now),
  );
  return adminOrderDetail(db, rawId);
}

/// The owner's chosen week is the Monday to Sunday that contains the day the
/// screen asked for, which is what screen 40's "This week" header shows.
DateTime weekMonday(DateTime day) {
  final weekday = day.weekday; // 1 = Monday ... 7 = Sunday
  return DateTime.utc(
    day.year,
    day.month,
    day.day,
  ).subtract(Duration(days: weekday - 1));
}

/// Formats a UTC midnight as "YYYY-MM-DD".
String dayKey(DateTime date) {
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

/// Reads `?weekStart=YYYY-MM-DD` (any day inside the wanted week) and returns
/// the Monday. Without it, the current Phnom Penh week.
DateTime cleanWeekStart(Map<String, String> query, {DateTime? nowUtc}) {
  final raw = query['weekStart'];
  if (raw == null || raw.isEmpty) {
    return weekMonday(phnomPenhDate(nowUtc ?? DateTime.now().toUtc()));
  }
  return weekMonday(cleanDay(raw, 'weekStart'));
}

/// Seven day keys from [monday].
List<String> weekDays(DateTime monday) => <String>[
  for (var i = 0; i < 7; i++)
    monday.add(Duration(days: i)).toIso8601String().substring(0, 10),
];

/// Screen 40: the week grid and the "Unscheduled orders" panel.
Future<Map<String, dynamic>> deliverySchedule(
  Db db,
  Map<String, String> query,
) async {
  final monday = cleanWeekStart(query);
  final days = weekDays(monday);
  final from = monday;
  final to = monday.add(const Duration(days: 7));

  final orders = db.collection('orders');
  // deliveryDate is a plain "YYYY-MM-DD" string, so a range on strings is the
  // range on days: from the Monday up to (not including) the day after Sunday.
  final scheduledSelector = where
      .gte('deliveryDate', days.first)
      .lte('deliveryDate', days.last)
      .ne('status', 'cancelled');
  final scheduled = await orders.find(scheduledSelector).toList();
  final unscheduledSelector = where
      .oneFrom('status', activeOrderStatuses)
      .eq('scheduledAt', null)
      .sortBy('deliveryDate');
  final unscheduledDocs = await orders.find(unscheduledSelector).toList();
  final customers = await _customersFor(db, [
    ...scheduled,
    ...unscheduledDocs,
  ]);

  Map<String, dynamic> card(Map<String, dynamic> doc) => adminOrderRow(
    doc,
    customer: customers[(doc['userId'] as ObjectId?)?.oid],
  );

  final byDate = <String, List<Map<String, dynamic>>>{};
  for (final doc in scheduled) {
    final date = doc['deliveryDate'] as String? ?? '';
    if (!days.contains(date)) continue;
    byDate.putIfAbsent(date, () => <Map<String, dynamic>>[]).add(card(doc));
  }

  var totalKg = 0;
  var deliveries = 0;
  final grid = <Map<String, dynamic>>[];
  for (final date in days) {
    final list = byDate[date] ?? const <Map<String, dynamic>>[];
    final morning = <Map<String, dynamic>>[];
    final afternoon = <Map<String, dynamic>>[];
    for (final item in list) {
      final weight = (item['totalWeightKg'] as num?) ?? 0;
      totalKg += weight.toInt();
      deliveries++;
      if (item['deliveryWindow'] == 'afternoon') {
        afternoon.add(item);
      } else {
        morning.add(item);
      }
    }
    final dayKg =
        [
          for (final item in [...morning, ...afternoon]) item,
        ].fold<int>(
          0,
          (sum, item) => sum + ((item['totalWeightKg'] as num).toInt()),
        );
    grid.add(<String, dynamic>{
      'date': date,
      'morning': morning,
      'afternoon': afternoon,
      'totalKg': dayKg,
    });
  }

  return <String, dynamic>{
    'weekStart': days.first,
    'weekEnd': days.last,
    'days': grid,
    'summary': <String, dynamic>{
      'deliveries': deliveries,
      'totalKg': totalKg,
      'heavyKg': heavyOrderKg,
    },
    'unscheduled': unscheduledDocs.map(card).toList(),
    'heavyOrders': scheduled
        .where((doc) => isHeavyOrder((doc['totalWeightKg'] as num?) ?? 0))
        .length,
    'rangeFrom': from.toIso8601String(),
    'rangeTo': to.toIso8601String(),
  };
}

/*
Calculates daily dashboard KPIs (today vs. yesterday orders and revenue
percentage change, pending order count, recent orders, and low-stock alerts).
*/

/// A simple percentage change for the dashboard arrows ("+12.4% vs
/// yesterday"). A jump from nothing is reported as null, because dividing by
/// zero is not a percentage anybody can act on.
double? percentChange(num today, num yesterday) {
  if (yesterday == 0) return today == 0 ? 0 : null;
  return double.parse(
    (((today - yesterday) / yesterday) * 100).toStringAsFixed(1),
  );
}

/// Screen 37: the four cards, the recent orders and the low stock list.
Future<Map<String, dynamic>> adminDashboard(Db db, {DateTime? nowUtc}) async {
  final now = (nowUtc ?? DateTime.now().toUtc()).toUtc();
  final todayStart = phnomPenhDayStart(now);
  final yesterdayStart = todayStart.subtract(const Duration(days: 1));

  final orders = db.collection('orders');
  final todaySelector = where
      .gte('createdAt', todayStart)
      .lt('createdAt', todayStart.add(const Duration(days: 1)))
      .sortBy('createdAt', descending: true);
  final todayDocs = await orders.find(todaySelector).toList();
  final yesterdayDocs = await orders
      .find(where.gte('createdAt', yesterdayStart).lt('createdAt', todayStart))
      .toList();

  num revenueOf(Iterable<Map<String, dynamic>> docs) => docs.fold<num>(
    0,
    (sum, doc) =>
        sum +
        (doc['status'] == 'cancelled'
            ? 0
            : ((doc['grandTotalCents'] as num?) ?? 0)),
  );

  final pending = await orders
      .find(where.oneFrom('status', <String>['pending', 'processing']))
      .toList();
  final products = await db.collection('products').find().toList();
  final lowStock =
      products.where((doc) {
        final stock = (doc['stock'] as num?)?.toInt() ?? 0;
        return stock < lowStockKg;
      }).toList()..sort(
        (a, b) => ((a['stock'] as num?) ?? 0).compareTo(
          (b['stock'] as num?) ?? 0,
        ),
      );

  final customers = await _customersFor(db, todayDocs.take(5).toList());
  final revenueToday = revenueOf(todayDocs) / 100;
  final revenueYesterday = revenueOf(yesterdayDocs) / 100;

  return <String, dynamic>{
    'date': phnomPenhDayKey(now),
    'ordersToday': todayDocs.length,
    'ordersYesterday': yesterdayDocs.length,
    'ordersChange': todayDocs.length - yesterdayDocs.length,
    'revenueToday': revenueToday,
    'revenueYesterday': revenueYesterday,
    'revenueChangePercent': percentChange(revenueToday, revenueYesterday),
    'pendingOrders': pending.length,
    'lowStockItems': lowStock.length,
    'recentOrders': [
      for (final doc in todayDocs.take(5))
        adminOrderRow(
          doc,
          customer: customers[(doc['userId'] as ObjectId?)?.oid],
        ),
    ],
    'lowStock': [
      for (final doc in lowStock.take(5))
        <String, dynamic>{
          'id': (doc['_id'] as ObjectId).oid,
          'name': doc['name'],
          'stock': (doc['stock'] as num?)?.toInt() ?? 0,
          'stockStatus': stockStatus((doc['stock'] as num?)?.toInt() ?? 0),
        },
    ],
    'reorderLevelKg': lowStockKg,
  };
}
