// The money rules: cents everywhere, 10% off over 150 kg, one flat delivery
// fee.

const bulkThresholdKg = 150;
const bulkDiscountPercent = 10;
const deliveryFeeCents = 300;
int toCents(num dollars) => (dollars * 100).round();
double toDollars(int cents) => cents / 100;

class CartTotals {
  const CartTotals({
    required this.subtotalCents,
    required this.discountCents,
    required this.totalCents,
    required this.deliveryFeeCents,
    required this.grandTotalCents,
  });
  final int subtotalCents;
  final int discountCents;
  final int totalCents;
  final int deliveryFeeCents;
  final int grandTotalCents;
}

CartTotals calculateTotals({
  required List<int> lineCents,
  required num totalKg,
  int thresholdKg = bulkThresholdKg,
  int discountPercent = bulkDiscountPercent,
  int flatFeeCents = deliveryFeeCents,
  bool discountEnabled = true,
}) {
  final subtotal = lineCents.fold<int>(0, (sum, cents) => sum + cents);

  // Discount comes off the subtotal. The fee is added after, so it
  // never gets discounted.
  final getsDiscount =
      discountEnabled && subtotal > 0 && totalKg >= thresholdKg;
  final discount = getsDiscount
      ? (subtotal * discountPercent / 100).round()
      : 0;
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
