// Sales reports over a bounded date range. All money already in cents.
// Collections: orders, users, addresses

import 'package:faheng_api/services/admin_order_service.dart';
import 'package:faheng_api/services/api_error.dart';
import 'package:mongo_dart/mongo_dart.dart';

const defaultReportDays = 7;
const maxReportDays = 366;

class ReportRange {
  const ReportRange({required this.from, required this.to});
  final DateTime from;
  final DateTime to;

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
