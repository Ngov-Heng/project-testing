import 'package:dart_frog/dart_frog.dart';
import 'package:mongo_dart/mongo_dart.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }

  final db = context.read<Db>();
  final docs = await db
      .collection('products')
      .find(where.eq('isActive', true))
      .toList();

  final items = docs.map((doc) {
    return {...doc, '_id': (doc['_id'] as ObjectId).toHexString()};
  }).toList();

  return Response.json(body: {'items': items, 'count': items.length});
}
