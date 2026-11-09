// WHY: All the money maths for the cart (and later the order) lives here, so
// the cart, the price preview and the order can never disagree.
// Everything is calculated in whole cents to avoid floating point errors and
// converted back to dollars only when the response is built.
// Chunk 2 passes the values from the settings document (screens 48 and 50)
// into calculateTotals, so the three defaults below are only a safety net.
// The cart screen shows `total` (subtotal minus discount, no delivery fee);
// the checkout screen shows `deliveryFee` and `grandTotal` on top of it.

/// Default total weight (kg) from which the bulk discount applies.
const bulkThresholdKg = 150;

/// Default bulk discount, in percent of the subtotal.
const bulkDiscountPercent = 10;

/// Default flat delivery fee in cents ($3.00) added once per cart.
const deliveryFeeCents = 300;

/// Converts a price in dollars (like 1.20) to whole cents (120).
int toCents(num dollars) => (dollars * 100).round();

/// Converts whole cents back to dollars for the JSON response (120 -> 1.2).
double toDollars(int cents) => cents / 100;

/// The money part of a cart, all in cents.
class CartTotals {
  /// Creates the totals.
  const CartTotals({
    required this.subtotalCents,
    required this.discountCents,
    required this.totalCents,
    required this.deliveryFeeCents,
    required this.grandTotalCents,
  });

  /// Sum of all line prices before the discount.
  final int subtotalCents;

  /// Bulk discount taken off the subtotal (0 when not eligible).
  final int discountCents;

  /// What the cart screen shows: subtotal minus discount, delivery not added.
  final int totalCents;

  /// Flat delivery fee (0 when the cart is empty).
  final int deliveryFeeCents;

  /// What the customer really pays: total plus the delivery fee.
  final int grandTotalCents;
}

/// Works out subtotal, bulk discount, total, delivery fee and grand total.
///
/// [thresholdKg], [discountPercent] and [flatFeeCents] have defaults, so the
/// callers do not change when chunk 2 starts passing the shop settings.
CartTotals calculateTotals({
  required List<int> lineCents,
  required num totalKg,
  int thresholdKg = bulkThresholdKg,
  int discountPercent = bulkDiscountPercent,
  int flatFeeCents = deliveryFeeCents,
  bool discountEnabled = true,
}) {
  final subtotal = lineCents.fold<int>(0, (sum, cents) => sum + cents);

  // An empty cart has nothing to discount and nothing to deliver, and the
  // admin can switch the whole rule off on screen 48.
  final getsDiscount =
      discountEnabled && subtotal > 0 && totalKg >= thresholdKg;
  final discount =
      getsDiscount ? (subtotal * discountPercent / 100).round() : 0;
  final fee = subtotal > 0 ? flatFeeCents : 0;
  final total = subtotal - discount;

  return CartTotals(
    subtotalCents: subtotal,
    discountCents: discount,
    totalCents: total,
    deliveryFeeCents: fee,
    grandTotalCents: total + fee,
  );
}
