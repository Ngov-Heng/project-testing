import 'package:faheng_api/services/pricing_service.dart';
import 'package:test/test.dart';

void main() {
  test('toCents avoids decimal errors', () {
    expect(toCents(1.20), 120);
    expect(toCents(1.10), 110);
    expect(toCents(0.95), 95);
  });

  test('toDollars turns cents back into dollars', () {
    expect(toDollars(120), 1.2);
    expect(toDollars(300), 3);
  });

  test('no discount below 150 kg, fee only in the grand total', () {
    final totals = calculateTotals(lineCents: [240, 5500], totalKg: 52);
    expect(totals.subtotalCents, 5740);
    expect(totals.discountCents, 0);
    expect(totals.totalCents, 5740);
    expect(totals.deliveryFeeCents, 300);
    expect(totals.grandTotalCents, 6040);
  });

  test('10% discount at exactly 150 kg, fee not inside the total', () {
    final totals = calculateTotals(lineCents: [16500], totalKg: 150);
    expect(totals.subtotalCents, 16500);
    expect(totals.discountCents, 1650);
    expect(totals.totalCents, 14850);
    expect(totals.deliveryFeeCents, 300);
    expect(totals.grandTotalCents, 15150);
  });

  test('no discount just under 150 kg', () {
    final totals = calculateTotals(lineCents: [16489], totalKg: 149.9);
    expect(totals.discountCents, 0);
  });

  test('empty cart is all zeros, and no delivery fee', () {
    final totals = calculateTotals(lineCents: [], totalKg: 0);
    expect(totals.subtotalCents, 0);
    expect(totals.discountCents, 0);
    expect(totals.deliveryFeeCents, 0);
    expect(totals.totalCents, 0);
    expect(totals.grandTotalCents, 0);
  });

  test('chunk 2 can pass the shop settings instead of the defaults', () {
    final totals = calculateTotals(
      lineCents: [10000],
      totalKg: 100,
      thresholdKg: 50,
      discountPercent: 20,
      flatFeeCents: 500,
    );
    expect(totals.discountCents, 2000);
    expect(totals.totalCents, 8000);
    expect(totals.deliveryFeeCents, 500);
    expect(totals.grandTotalCents, 8500);
  });
}
