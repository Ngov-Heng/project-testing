// WHY: Screen 49 is one page that answers three questions about a date range:
// how much money came in each day, which rice sold the most kilos, and who
// spent the most.
// Where it sits in the flow: the /api/admin guard has already checked the role.
// Everything here is computed from `orders` and `users` on every request, so
// the report can never disagree with the order list: there is only one set of
// numbers in the shop.

import 'package:faheng_api/services/admin_order_service.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:mongo_dart/mongo_dart.dart';

/// How far back the report looks when no range is given: the last seven days,
/// today included, which is what the picker on screen 49 starts on.
const defaultReportDays = 7;

/// The longest range one request may ask for. A year of orders is a small
/// document; ten years would be a slow request on a laptop.
const maxReportDays = 366;

/// The date range of a report, both ends included.
class ReportRange {
  /// Creates the range.
  const ReportRange({required this.from, required this.to});

  /// The first day, as a UTC midnight.
  final DateTime from;

  /// The last day, as a UTC midnight. The whole day is counted.
  final DateTime to;

  /// Every day of the range, in order, as "YYYY-MM-DD".
  List<String> get days {
    final out = <String>[];
    var day = from;
    while (!day.isAfter(to)) {
      out.add(dayKey(day));
      day = day.add(const Duration(days: 1));
    }
    return out;
  }
}

/// Reads `from` and `to` off screen 49's picker.
///
/// Both are optional: no range means the last seven Phnom Penh days, so the
/// screen has something to draw before anybody touches the picker.
ReportRange reportRange(
  Map<String, String> query, {
  DateTime? nowUtc,
}) {
  final today = phnomPenhDate(nowUtc ?? DateTime.now().toUtc());
  final rawFrom = (query['from'] ?? '').trim();
  final rawTo = (query['to'] ?? '').trim();

  final to = rawTo.isEmpty ? today : cleanDay(rawTo, 'to');
  final from = rawFrom.isEmpty
      ? to.subtract(const Duration(days: defaultReportDays - 1))
      : cleanDay(rawFrom, 'from');

  if (from.isAfter(to)) {
    throw const ApiError(400, 'from cannot be after to');
  }
  if (to.difference(from).inDays + 1 > maxReportDays) {
    throw const ApiError(400, 'the range cannot be longer than a year');
  }
  return ReportRange(from: from, to: to);
}

/// The three cards at the top of screen 49.
///
/// Cancelled orders are not sales: the subtitle under the revenue card says so,
/// so they are dropped before anything is added up. `cancelled` is still
/// returned, because a report that hides what it ignored cannot be trusted.
Map<String, dynamic> reportSummary(List<Map<String, dynamic>> orders) {
  var revenue = 0;
  var counted = 0;
  var cancelled = 0;
  var cancelledCents = 0;
  var kg = 0.0;
  for (final order in orders) {
    if (order['status'] == 'cancelled') {
      cancelled++;
      cancelledCents += ((order['grandTotalCents'] as num?) ?? 0).round();
      continue;
    }
    counted++;
    revenue += ((order['grandTotalCents'] as num?) ?? 0).round();
    kg += ((order['totalWeightKg'] as num?) ?? 0).toDouble();
  }
  return <String, dynamic>{
    'revenue': revenue / 100,
    'orders': counted,
    'averageOrder': counted == 0 ? 0.0 : revenue / counted / 100,
    'totalKg': kg,
    'cancelled': cancelled,
    'cancelledValue': cancelledCents / 100,
  };
}

/// The line chart: one point per day of the range, zero filled.
///
/// A day with no orders still needs a point, otherwise the line would jump from
/// Tuesday straight to Friday and the chart would lie about the week.
List<Map<String, dynamic>> dailyRevenue(
  List<Map<String, dynamic>> orders,
  ReportRange range,
) {
  final revenue = <String, int>{};
  final counts = <String, int>{};
  for (final day in range.days) {
    revenue[day] = 0;
    counts[day] = 0;
  }
  for (final order in orders) {
    if (order['status'] == 'cancelled') continue;
    final created = order['createdAt'];
    if (created is! DateTime) continue;
    final key = phnomPenhDayKey(created);
    if (!revenue.containsKey(key)) continue;
    revenue[key] =
        revenue[key]! + ((order['grandTotalCents'] as num?) ?? 0).round();
    counts[key] = counts[key]! + 1;
  }
  return <Map<String, dynamic>>[
    for (final day in range.days)
      <String, dynamic>{
        'date': day,
        'revenue': revenue[day]! / 100,
        'orders': counts[day],
      },
  ];
}

/// "Top selling products - By kg sold" on screen 49.
///
/// The kg are what was actually weighed, not what was ordered: a cancelled
/// order never reached a shelf, and this list shares the same "no sales"
/// filter as the revenue card.
List<Map<String, dynamic>> topSellingProducts(
  List<Map<String, dynamic>> orders, {
  int limit = 5,
}) {
  final kg = <String, double>{};
  final name = <String, String>{};
  final cents = <String, int>{};
  for (final order in orders) {
    if (order['status'] == 'cancelled') continue;
    final items = (order['items'] as List?) ?? const <dynamic>[];
    for (final raw in items) {
      final item = Map<String, dynamic>.from(raw as Map);
      final productId = item['productId'];
      if (productId is! ObjectId) continue;
      final key = productId.oid;
      name[key] = (item['name'] as String?) ?? name[key] ?? 'Product';
      kg[key] = (kg[key] ?? 0) + ((item['quantityKg'] as num?) ?? 0).toDouble();
      cents[key] =
          (cents[key] ?? 0) + ((item['lineTotalCents'] as num?) ?? 0).round();
    }
  }
  final rows = kg.keys
      .map(
        (key) => <String, dynamic>{
          'productId': key,
          'name': name[key],
          'kgSold': kg[key],
          'revenue': (cents[key] ?? 0) / 100,
        },
      )
      .toList()
    ..sort(
      (a, b) => (b['kgSold']! as double).compareTo(a['kgSold']! as double),
    );
  return rows.take(limit).toList();
}

/// "Best customers - By spend in this period" on screen 49.
List<Map<String, dynamic>> bestCustomers(
  List<Map<String, dynamic>> orders,
  Map<String, Map<String, dynamic>> users, {
  int limit = 5,
}) {
  final totals = <String, int>{};
  final counts = <String, int>{};
  final ids = <String, ObjectId>{};
  for (final order in orders) {
    if (order['status'] == 'cancelled') continue;
    final userId = order['userId'];
    if (userId is! ObjectId) continue;
    final key = userId.oid;
    ids[key] = userId;
    totals[key] =
        (totals[key] ?? 0) + ((order['grandTotalCents'] as num?) ?? 0).round();
    counts[key] = (counts[key] ?? 0) + 1;
  }
  final rows = totals.keys.map((key) {
    final user = users[key];
    return <String, dynamic>{
      'id': key,
      'name': user?['name'] ?? 'Customer',
      'customerType': user?['customerType'] ?? 'household',
      'town': user?['town'],
      'orders': counts[key] ?? 0,
      'spent': (totals[key] ?? 0) / 100,
    };
  }).toList()
    ..sort((a, b) => (b['spent']! as double).compareTo(a['spent']! as double));
  return rows.take(limit).toList();
}

/// Screen 49, all of it, in one request.
///
/// The orders are fetched once and grouped in Dart: a shop with thousands of
/// orders in a month is still small enough for that, and one query is easier to
/// explain than four aggregation pipelines.
Future<Map<String, dynamic>> salesReport(
  Db db,
  Map<String, String> query, {
  DateTime? nowUtc,
}) async {
  final range = reportRange(query, nowUtc: nowUtc);

  final orders = await db
      .collection('orders')
      .find(
        SelectorBuilder()
          ..gte('createdAt', range.from)
          ..lt('createdAt', range.to.add(const Duration(days: 1))),
      )
      .toList();

  final userIds = orders
      .map((order) => order['userId'])
      .whereType<ObjectId>()
      .toSet()
      .toList();
  final userDocs = userIds.isEmpty
      ? const <Map<String, dynamic>>[]
      : await db
          .collection('users')
          .find(where.oneFrom('_id', userIds))
          .toList();

  // Screen 49 shows the customers' town, which lives on their address.
  final addressDocs = userIds.isEmpty
      ? const <Map<String, dynamic>>[]
      : await db
          .collection('addresses')
          .find(where.oneFrom('userId', userIds))
          .toList();
  final towns = <String, String>{};
  for (final address in addressDocs) {
    final key = (address['userId'] as ObjectId).oid;
    if (address['isDefault'] == true || !towns.containsKey(key)) {
      towns[key] = (address['town'] as String?) ?? '';
    }
  }

  final users = <String, Map<String, dynamic>>{
    for (final user in userDocs)
      (user['_id'] as ObjectId).oid: <String, dynamic>{
        ...user,
        'town': towns[(user['_id'] as ObjectId).oid],
      },
  };

  return <String, dynamic>{
    'from': dayKey(range.from),
    'to': dayKey(range.to),
    'summary': reportSummary(orders),
    'daily': dailyRevenue(orders, range),
    'topProducts': topSellingProducts(orders),
    'bestCustomers': bestCustomers(orders, users),
  };
}
