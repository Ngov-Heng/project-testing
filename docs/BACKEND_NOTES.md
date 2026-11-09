# FAHENG Rice Shop - backend handoff notes

Living file. Updated at the end of every chunk. If a chat is lost, paste this
file back and the work can continue.

Last updated: end of chunk 4 (addresses and profile).
Done so far: chunk 1 cart, chunk 2 settings and pricing, chunk 4 addresses and
profile. Next in the work order: chunk 3 orders.

## Conventions

- Errors: `{"error": "plain English sentence"}`. 400 bad input, 401 no/invalid
  token, 403 wrong role, 404 not found or someone else's data, 409 conflict.
- Money: stored as integer cents (`...Cents`), returned as dollars.
- Ids in responses: `id` (hex string), never `_id`.
- Lists: `{"items": [...]}`; orders/reports take `page` (default 1) and `limit`
  (default 20, max 100), newest first.
- Timestamps: stored UTC, returned ISO 8601. "Today" means Asia/Phnom Penh
  (UTC+7).
- Enums stored lowercase (`home`, `morning`, `cod`, `pending`...).
- Guards: `authGuard` = token -> user; `adminGuard` = authGuard + role `admin`.
  Missing `role` means buyer.

## Endpoints that exist

| Method | URL | Who | Notes |
|---|---|---|---|
| POST | `/api/auth/register` | public | name, email or phone, password (8+). No token returned yet. |
| POST | `/api/auth/login` | public | `identifier` = email or phone + password -> `{token, user}` |
| GET | `/api/products` | public | `?category=&q=&featured=&sort=name\|price_asc\|price_desc&page=&limit=` -> `{items,total,page,limit}` |
| GET | `/api/products/:id` | public | one product |
| GET | `/api/categories` | public | `{items:[...]}` |
| GET | `/api/settings` | public | shop, paymentMethods, deliveryFee, bulkDiscount |
| GET | `/api/cart` | buyer | full cart with totals |
| POST | `/api/cart/items` | buyer | `{productId, quantityKg}` |
| PUT | `/api/cart/items/:productId` | buyer | `{quantityKg}` |
| DELETE | `/api/cart/items/:productId` | buyer | |
| DELETE | `/api/cart` | buyer | empty the cart |
| GET | `/api/cart/preview` | buyer | totals only |
| GET | `/api/users/me` | buyer | profile + `customerType` |
| PUT | `/api/users/me` | buyer | `{name, phone?, email?}` |
| GET | `/api/users/me/addresses` | buyer | default first |
| POST | `/api/users/me/addresses` | buyer | 201, first address becomes default |
| PUT | `/api/users/me/addresses/:id` | buyer | full replace |
| DELETE | `/api/users/me/addresses/:id` | buyer | returns remaining list |
| GET | `/api/users/me/wishlist` | buyer | existing, unchanged |
| PUT/DELETE | `/api/users/me/wishlist/:productId` | buyer | existing, unchanged |
| GET | `/api/admin/settings` | admin | same shape as PUT |
| PUT | `/api/admin/settings` | admin | full replace, field-by-field validation |

## Collections

```
users      { _id, name, email?, phone?, passwordHash, role? (admin), customerType?
             (household|business, set at sign-up - read only afterwards),
             isVerified?, createdAt, wishlist[] }
products   { _id, name, category (String = category name), pricePerKg (dollars),
             stock (Int kg), image, description, isActive, isFeatured }
categories { _id, name }
carts      { _id = user id, items: [{productId, quantityKg}] }
settings   { _id: "shop", bulkDiscount {enabled, thresholdKg, percent},
             deliveryFeeCents, shop {name, phone, address},
             paymentMethods {paypal, cod} }
addresses  { _id, userId, label (home|work|other), receiverName, phone, street,
             town, lat, lng, isDefault, createdAt, updatedAt? }
```

## Business rules implemented

- Pricing: line = kg × pricePerKg; 10% discount when total weight >= threshold
  (default 150 kg); flat delivery fee $3.00; all three come from `settings`.
  `total` = subtotal - discount (cart screen), `grandTotal` = total +
  deliveryFee (checkout screen). Cart and checkout share `calculateTotals`.
- Settings: one document `_id: "shop"`, auto-created with defaults, missing
  fields back-filled on read. Percent 0-100, threshold > 0, fee >= 0, shop name
  required, at least one payment method must stay on.
- Addresses: max 10 per buyer; first address becomes default; setting
  `isDefault: true` clears the old default; the current default cannot unset
  itself; deleting the default promotes the oldest remaining. Every query is
  filtered by `userId`, so another buyer's id answers 404.
- Profile: name required (<= 80); phone/email normalised and unique across
  accounts (409); an account must keep a phone or an email; `customerType`,
  `role`, `isVerified` are never changed through the profile.
- Stock: cart refuses quantities above `stock` (409); a product with no `stock`
  field is treated as unlimited.

## Decisions made (and why)

- Labels, enums and `town` are free text or lowercase strings; the app owns
  display casing and the town dropdown list. Alternative: server-side list.
  Why: the screens show a dropdown the backend has no list for.
- Profile PUT is a full replace (phone/email missing = removed). Alternative:
  partial patch. Why: screen 32 saves all three fields at once.
- Read-only fields sent to the profile PUT are ignored, not rejected. Why:
  a lecturer may click around; silently ignoring keeps the response honest.
- `customerType` defaults to `household` when the field is missing, so old
  accounts still render.

## What is left

| Chunk | Scope |
|---|---|
| 3 (orders) | POST /api/orders, GET /api/orders?tab=active\|past, GET /api/orders/:id, POST /api/orders/:id/cancel {reason}, POST /api/orders/:id/reorder. Atomic counter for FH-1001. Cents on orders + lines. Stock deduct/rollback without transactions. |
| 5 | auth gaps: verified flag, 6-digit code, forgot/reset password, change password, admin login, customerType at sign-up |
| 6 | products/categories admin + seed (12 products, 4 categories, 3 low stock, 3 featured) |
| 7 | admin orders + dashboard + delivery schedule |
| 8 | reviews (one per product per delivered order) |
| 9 | quotes + notifications |
| 10 | admin customers + reports |
| 11 | PayPal sandbox |

Left alone on purpose: `/health`, `/api/db_check`, wishlist, products route shape.
