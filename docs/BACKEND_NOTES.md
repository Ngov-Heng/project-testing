# FAHENG Rice Shop - backend handoff notes

Living file. Updated at the end of every chunk. If a chat is lost, paste this
file back and the work can continue.

Last updated: end of chunk 5 (auth gaps).
Done so far: chunk 1 cart, chunk 2 settings and pricing, chunk 4 addresses and
profile, chunk 3 buyer orders, chunk 5 auth gaps. Next in the work order:
chunk 6 products, categories and the seed script.

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
| POST | `/api/auth/register` | public | name, email or phone, password (8+), `customerType` -> 201 `{user, verification}`; no token yet |
| POST | `/api/auth/verify-code` | public | `{identifier, code}` -> `{token, user}`; sets `isVerified` |
| POST | `/api/auth/resend-code` | public | `{identifier}`; 429 inside the 60 second wait |
| POST | `/api/auth/forgot-password` | public | `{identifier}`; always 200 + the same sentence |
| POST | `/api/auth/reset-password` | public | `{identifier, code, password}`; also marks the account verified |
| POST | `/api/auth/login` | public | `identifier` = email or phone + password -> `{token, user}`; 403 until verified |
| PATCH | `/api/users/me/password` | buyer | `{currentPassword, newPassword}` (screen 34) |
| GET | `/api/products` | public | `?category=&q=&featured=&sort=name\|price_asc\|price_desc&page=&limit=` |
| GET | `/api/products/:id` | public | one product |
| GET | `/api/categories` | public | `{items:[...]}` |
| GET | `/api/settings` | public | shop, paymentMethods, deliveryFee, bulkDiscount |
| GET | `/api/cart` | buyer | full cart with totals |
| POST | `/api/cart/items` | buyer | `{productId, quantityKg}` |
| PUT | `/api/cart/items/:productId` | buyer | `{quantityKg}` |
| DELETE | `/api/cart/items/:productId` | buyer | |
| DELETE | `/api/cart` | buyer | empty the cart |
| GET | `/api/cart/preview` | buyer | totals only |
| POST | `/api/orders` | buyer | `{addressId, deliveryDate, deliveryWindow, paymentMethod}` -> 201 |
| GET | `/api/orders` | buyer | `?tab=active\|past&page=&limit=` -> `{items,total,page,limit}` |
| GET | `/api/orders/:id` | buyer | own order only |
| PATCH | `/api/orders/:id/cancel` | buyer | `{reasonCode, note?}`, or `{reason}`; pending/processing only |
| POST | `/api/orders/:id/reorder` | buyer | `{cart, skipped:[{productId,name,reason}]}` |
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
             isVerified? (false until the code is typed), verifiedAt?,
             passwordChangedAt?,
             verification? { code "482913", purpose (signup|reset), issuedAt,
                            expiresAt, attempts },   // deleted once used
             createdAt, wishlist[] }
products   { _id, name, category (String = category name), pricePerKg (dollars),
             stock (Int kg), image, description, isActive, isFeatured }
categories { _id, name }
carts      { _id = user id, items: [{productId, quantityKg}] }
settings   { _id: "shop", bulkDiscount {enabled, thresholdKg, percent},
             deliveryFeeCents, shop {name, phone, address},
             paymentMethods {paypal, cod} }
addresses  { _id, userId, label (home|work|other), receiverName, phone, street,
             town, lat, lng, isDefault, createdAt, updatedAt? }
counters   { _id: "orders", seq }            // order number counter, seeded 1000
orders     { _id, userId, orderNumber "FH-1001", orderNumberValue 1001,
             items: [{productId, name, image, quantityKg, pricePerKgCents,
                      lineTotalCents}],
             totalWeightKg, subtotalCents, discountCents, deliveryFeeCents,
             totalCents, grandTotalCents,
             address: {label, receiverName, phone, street, town, lat, lng},
             deliveryDate "YYYY-MM-DD", deliveryWindow (morning|afternoon),
             paymentMethod (paypal|cod), paymentStatus (unpaid|paid|failed),
             status (pending|processing|on_the_way|delivered|cancelled),
             statusHistory: [{status, at}], cancelReason (text the screens
             show), cancelReasonCode?, cancelNote?, createdAt, updatedAt? }
```

## Business rules implemented

- Pricing: line = kg x pricePerKg; bulk discount when total weight >= threshold
  (default 150 kg); flat delivery fee; all three come from `settings`.
  `total` = subtotal - discount (cart screen), `grandTotal` = total +
  deliveryFee (checkout/payment).
- Settings: one document `_id: "shop"`, auto-created with defaults, missing
  fields back-filled on read. Percent 0-100, threshold > 0, fee >= 0, shop name
  required, at least one payment method stays on.
- Addresses: max 10 per buyer; first becomes default; `isDefault: true` clears
  the old default; the current default cannot unset itself; deleting the default
  promotes the oldest remaining; every query filtered by `userId`.
- Profile: name required (<= 80); phone/email normalised and unique (409); an
  account must keep a phone or an email; `customerType`, `role`, `isVerified`
  are never changed by the profile route.
- Cancel reasons are the four radios on screen 28:
  `ordered_by_mistake`, `change_address_or_date`, `found_better_price`,
  `other`, plus an optional `note` (<= 200). `cancelReason` keeps the display
  text ("I found a better price - cheaper at the market").
- Orders: cart must be non-empty; address must belong to the buyer; delivery
  date from tomorrow to 7 days ahead in Phnom Penh time; window
  morning|afternoon; payment method must be switched on in settings; order
  number from the `counters` document via an atomic `$inc`; items and address
  are copied onto the order; stock is taken off with a conditional
  `{stock: {$gte: kg}}` update and rolled back if a later item fails; cart is
  emptied only after the order is saved; buyer may cancel only while
  pending/processing, with a reason, and the kg go back on the shelf; status
  transitions live in `orderTransitions` (shared with the admin chunk).
- Stock: cart refuses quantities above `stock` (409); a product with no `stock`
  field is treated as unlimited.

- Accounts must be verified before they can log in: register answers 201 with
  no token, and login answers 403 "Please verify your account first" until
  screen 10 is finished.
- One 6-digit code at a time per account, kept on the user document with a
  purpose: `signup` (screens 09/10) or `reset` (screens 11/12). A code cannot
  do the other job - `verify-code` with a reset code answers 400.
- A code lives 10 minutes, dies after 5 wrong tries (429), and a new one can be
  asked for once a minute (429) - the countdown on screen 10.
- Both new-password rules print "can't be the old one": screens 12 and 34
  refuse the same password, and the server enforces it with bcrypt.
- Forgot password answers the same sentence whether or not the account exists,
  so nobody can use it to find out who shops at FAHENG.

## Status changes

```
pending  -> processing | cancelled
processing -> on_the_way | cancelled
on_the_way -> delivered
delivered / cancelled -> (nothing)
```

## Decisions made (and why)

- Labels, enums and `town` are free text or lowercase strings; the app owns
  display casing. Alternative: server-side lists. Why: no list exists to use.
- Profile PUT is a full replace (missing phone/email = removed).
- Read-only profile fields are ignored, not rejected.
- `customerType` defaults to `household` when missing (old accounts).
- Deleting the default address promotes the oldest remaining.
- `DELETE /addresses/:id` returns the remaining list so the screen re-renders
  in one call.
- `deliveryDate` is stored as a "YYYY-MM-DD" string, not a Date. Alternative: a
  UTC timestamp. Why: a delivery *date* has no time-of-day, and a string can
  never shift across timezones. `createdAt`/`updatedAt` stay UTC timestamps.
- Orders store **both** `totalCents` (subtotal - discount) and `grandTotalCents`
  (total + fee) so the app reuses the cart field names everywhere.
- `paymentStatus` starts `unpaid` for both PayPal and COD; PayPal flips it to
  `paid` in the PayPal chunk, the admin flips COD (chunk 7).
- A payment method switched off in settings is refused at order time (400), not
  silently swapped.
- Reorder reuses `addCartItem`, so cart rules (active product, stock) are not
  duplicated; anything refused is reported in `skipped` with the cart’s own
  message.
- Cancelling stores a reason **code** plus an optional note, not just free
  text, because screen 28 is four fixed radios and reports (chunk 10) can then
  group them. A plain `reason` string is still accepted so nothing breaks.
- Stock deduction is check-then-`$inc` per item with rollback, because the
  single-node MongoDB has no multi-document transactions. A crash between the
  deductions and the insert could leave stock low; documented as a known limit.
- `routes/api/orders/[id]/index.dart` (not `[id].dart`) because Dart Frog
  refuses a route file and a folder with the same name.
- There is no SMS or email provider in this project, so every "we sent you a
  code" answer carries `devCode` and the server also prints it. Everything else
  (expiry, attempts, one code at a time) is the real thing, so swapping in a
  provider later means deleting one field. Alternative: a `codes` collection.
  Why the user document: one code per account is exactly one field, and
  deleting the account deletes its code.
- The 60 second resend wait is per account and not per purpose, so a brand new
  sign-up cannot ask for a reset code in its first minute. Simpler than two
  timers and it stops code spam.
- `reset-password` also sets `isVerified: true`: the code proves the buyer owns
  the phone or email, and without this somebody who skipped screen 10 could
  reset a password and still be locked out.
- Login now returns `role`, `customerType` and `isVerified` inside `user`
  (added fields, nothing removed) because screen 36 decides where to send the
  admin and screen 01 decides whether to show the verify step.
- Verifying a code returns a token, so the app goes from screen 10 straight to
  the home screen instead of asking for the password twice.

## What is left

| Chunk | Scope |
|---|---|
| 5 | done: verified flag, 6-digit code, forgot/reset password, change password, admin login, customerType at sign-up |
| 6 | products/categories admin + seed (12 products, 4 categories, 3 low stock, 3 featured) |
| 7 | admin orders + dashboard + delivery schedule (reuses `orderTransitions`) |
| 8 | reviews (one per product per delivered order) |
| 9 | quotes + notifications |
| 10 | admin customers + reports |
| 11 | PayPal sandbox (sets `paymentStatus: paid`) |

Left alone on purpose: `/health`, `/api/db_check`, wishlist, products route shape.
