# FAHENG Rice Shop - backend handoff notes

Living file. Updated at the end of every chunk. If a chat is lost, paste this
file back and the work can continue.

Last updated: end of chunk 6 (products, categories, stock, seed).
Done so far: chunk 1 cart, chunk 2 settings and pricing, chunk 4 addresses and
profile, chunk 3 buyer orders, chunk 5 auth gaps, chunk 6 products. Next in
the work order: chunk 7 admin orders and dashboard.

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
| GET | `/api/products` | public | `?category=&q=&featured=&minPrice=&maxPrice=&inStock=true&sort=name\|price_asc\|price_desc&page=&limit=` (limit max 50) |
| GET | `/api/products/:id` | public | one product |
| GET | `/api/categories` | public | `{items:[{_id, name, sortOrder, productCount}], count}` |
| GET | `/api/admin/products` | admin | `?q=&category=&stockLevel=all\|in_stock\|low\|out&page=&limit=` -> items + `summary{products,totalKg,lowStock,outOfStock}` |
| POST | `/api/admin/products` | admin | 201, screen 42 fields |
| GET/PUT | `/api/admin/products/:id` | admin | one product / full replace of the editable fields |
| POST | `/api/admin/products/:id/restock` | admin | `{stock}` sets the counted level, keeps `restockHistory` |
| GET | `/api/admin/products/stock` | admin | screen 43: summary + every product, emptiest first |
| GET/POST | `/api/admin/categories` | admin | list with `productCount` / 201 add |
| GET/PUT/DELETE | `/api/admin/categories/:id` | admin | detail + its products / rename (cascades) / delete (409 while used) |
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
             stock (Int kg), image, description (<= 160 chars), isActive,
             isFeatured, createdAt, updatedAt?, restockedAt?,
             restockHistory: [{stock, at}] }
categories { _id, name (unique, case-insensitive), sortOrder, createdAt }
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

- Stock is told apart in one place: `>= 100 kg` in stock, `1 - 99 kg` low,
  `0` out. Screens 41 and 43 read `stockStatus` from the API instead of
  carrying their own threshold.
- A product's category must be one of the categories (400 otherwise), because
  screen 42 picks from a dropdown - a typo would create a category no screen
  can show.
- Renaming a category rewrites `category` on every product, since a product
  stores the name as a string. Deleting one is refused with 409 while products
  still use it, and the message says how many.
- Adding or renaming a category to a name that already exists (ignoring case)
  is a 409.
- Restock **sets** the level (the admin counts the bags) and appends to
  `restockHistory`; it does not add to the old number.

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

- The public product and category routes keep the raw document shape chunk 1
  shipped, but every document passes through `jsonSafe` first: a stored
  `createdAt` is a DateTime, and a DateTime cannot be put in JSON. Without
  that, adding a product turned the public list into a 500.
- No DELETE for a product: screen 41 only offers "Edit", and chunk 4's orders
  keep a snapshot anyway. `isActive: false` is the "remove from the shop"
  switch the screen actually has.
- `GET /api/admin/products/stock` has no paging: screen 43 shows every product
  and the shop has tens of them, not thousands.
- The seed script (`dart run tool/seed.dart`) only inserts what is missing by
  name, so it is safe to run twice and never deletes a product that a cart or
  an order points at. 4 categories, 12 products, 3 under 100 kg, 3 featured,
  5,880 kg in total.
- The admin sample screens name the four categories Fragrant / Sticky / Whole
  grain / Organic, while the buyer screens and the seed say Jasmine / Sticky /
  Brown / Bulk. The shop uses the buyer/seed names; the admin mock is a
  placeholder.

## Chunk 7 - admin orders, dashboard, delivery schedule

### Endpoints

| Method | Path | Screen | What it does |
|---|---|---|---|
| GET | `/api/admin/dashboard` | 37 | today's orders and revenue vs yesterday, pending, low stock, recent orders |
| GET | `/api/admin/orders` | 38 | paged list with search, status, date range, sort and status counts |
| GET | `/api/admin/orders/:id` | 39 | one order + the customer card + the statuses it may move to |
| PATCH | `/api/admin/orders/:id/status` | 39 | move an order along the pipeline, cancel puts the stock back |
| PATCH | `/api/admin/orders/:id/payment` | 39 | mark a cash order paid or unpaid by hand |
| POST | `/api/admin/orders/:id/schedule` | 40 | give an unscheduled order a delivery date and window |
| GET | `/api/admin/delivery-schedule` | 40 | the 7 day grid for a week + the orders still waiting for a slot |

### Rules that only live here

- `heavy` means **150 kg or more** (screen 40: "Heavy: orders of 150 kg or
  more"). It is a display flag computed from `totalWeightKg`, never stored.
- Admin may only cancel a `pending` or `processing` order; anything already on
  the way has left the shop. Cancelling calls `restoreStockForOrder`, the same
  helper the buyer's own cancel uses, so the two can never drift apart.
- `paymentStatus` can be set by hand only for `cod`. PayPal is confirmed by the
  provider (chunk 11), so a hand edit answers 409 with a clear message. A
  cancelled order cannot be marked paid.
- A delivery date must be today up to 14 days ahead, in Phnom Penh days. A past
  day, a day three weeks out or a window that is not `morning`/`afternoon`
  answers 400.
- Scheduled orders never appear in the `unscheduled` panel of screen 40, and
  cancelled orders appear in neither the grid nor the panel.

### Time zones, and the bug this chunk found

`phnomPenhDayStart(utc)` is the **instant** a Phnom Penh day begins, which is
17:00 UTC the day before. Comparing it with `DateTime.difference().inDays` is
wrong for dates: at 12:00 UTC "yesterday" comes out as 0 days away, because the
gap is only 17 hours. Two different helpers now exist and each has one job:

- `phnomPenhDate(utc)` - the calendar date a person in Cambodia would write
  down, as a UTC midnight. Used for weeks and for "is this date in the past".
- `phnomPenhDayStart(utc)` - the instant, used as a `createdAt` boundary.

The week grid had the same fault: it fed `phnomPenhDayStart` into `weekMonday`
and therefore showed the previous week for the whole evening in Cambodia.

### The mongo_dart trap that cost the first test run

`where.raw(map)` **stores the map but drops it from the query**. Every filter
built that way returned the whole table while `sort`, `skip` and `limit` on the
same selector kept working, so the paging looked right and only the filters were
silently ignored. Chunk 6's product list had the same fault, so its totals were
right (they came from `count(map)` anyway) and its rows were not.

The rule from now on: never wrap a map in `where.raw`. Either pass the map
straight to `count(map)` / `find(map)`, or build a `SelectorBuilder` with the
fluent methods and use it directly. Both services now expose

- `buildOrderQuery(filters)` / `buildProductQuery(filters)` - the status, date
  and stock conditions, as a `SelectorBuilder`;
- `searchOrderIds(db, term)` / `searchProductIds(db, term)` - the text search,
  which has to look in two collections and therefore returns ids that are then
  added with `oneFrom('_id', ids)`.

### Decisions

- The dashboard keeps the **100 kg** reorder level that chunk 6 shipped. Screen
  37's mock says 600 kg and "3 under 20 kg cover"; those are placeholder numbers
  from a mock drawn before the seed existed, and one low-stock rule for the whole
  app beats two that disagree. The level is a constant (`reorderLevelKg`), so
  moving it to settings later touches one file.
- `ordersToday` counts by Phnom Penh day, not by UTC day, because the person
  reading the dashboard is in Kampot.
- The status list in the summary always carries all five statuses, zero
  included, so the screen's filter chips do not move around as orders arrive.
- A search that matches nothing returns an empty page with the real shop-wide
  summary, not a 404: "no results" is an answer.

## Chunk 8 - reviews

### Endpoints

| Method | Path | Screen | What it does |
|---|---|---|---|
| GET | `/api/reviews?productId=...&page&limit` | 17 | one product, its rating block and a page of reviews (public) |
| GET | `/api/orders/:id/reviews` | 30 | each item of the order, whether it can still be rated, the review it has |
| POST | `/api/orders/:id/reviews` | 30 | write one review, 201 |

### Rules that only live here

- A review can only be written from an order that is **delivered**, and only
  for a product that is **in that order**. Together those two checks are what
  make the "Verified purchase" tag true, so it is computed, not stored as an
  option: `verifiedPurchase` is always true on the way out.
- One review **per product per order**, not per product overall: a customer who
  buys the same rice twice can rate both deliveries, and re-sending the same
  one answers 409.
- Stars are a whole number 1 to 5. `"5"` as text is refused, and so is `3.5`:
  a client sending either is a bug worth seeing in the test run.
- The comment is optional, trimmed, at most 300 characters, and stored as
  `null` when empty. Empty string and null mean the same thing to a screen, so
  only one of them is ever written.
- The summary counts **every** review of the product, not the page: 18 reviews
  with `limit=20` and 30 reviews with `limit=20` both show the true average.
- The average is rounded to one decimal on the server, because the mock prints
  "4.5" and two clients rounding differently would disagree.
- `canReview` is per item, not per order, so screen 30 can show four filled
  stars for the rice that was rated and an empty row for the one that was not.

### The path that was not used

`/api/products/:id/reviews` is the prettier URL, and it is impossible here:
Dart Frog cannot hold `routes/api/products/[id].dart` and
`routes/api/products/[id]/` at the same time, and `[id].dart` has been the
product detail since chunk 6. Moving it would have changed a delivered file for
the sake of a URL, so the list lives at `/api/reviews?productId=...`. The
order side *is* nested, `/api/orders/:id/reviews`, because that folder was
already a directory with `cancel.dart` and `reorder.dart` in it.

### Decisions

- No admin moderation screen exists in the 57 frames, so there is no admin
  review route. Deleting or hiding a review would need a screen first.
- The product document is not given an `averageRating` field. The number is one
  query away, and a stored copy would be wrong the moment a review is added.
  Screen 12 can be fed from `/api/reviews` if a later chunk wants stars on the
  product page.
- No unique index is created on `(productId, orderId)`. The service checks
  first and answers 409; an index would only matter if two requests arrived in
  the same millisecond, and creating indexes belongs in a migration, not in a
  request.
- The review keeps `orderNumber`, `productName` and `authorName` copies. A
  review is a small historical record: renaming a product should not rewrite
  what a customer said about it.

## Chunk 9 - quotes and notifications

### Endpoints

| Method | Path | Screen | What it does |
|---|---|---|---|
| POST | `/api/quotes` | 25 | a buyer asks for a price on 150 kg or more, 201 |
| GET | `/api/quotes` | - | this buyer's requests, newest first |
| GET | `/api/quotes/:id` | 31 | one request, with its price once the admin answered |
| PATCH | `/api/quotes/:id/respond` | 31 | Accept or Decline a priced quote |
| GET | `/api/admin/quotes` | 47 | every request, with search, status filter and counts |
| PATCH | `/api/admin/quotes/:id` | 47 | send (or re-send) the price per kg, and tell the buyer |
| GET | `/api/notifications` | 31 | the list, newest first, plus the unread count |
| GET | `/api/notifications/unread-count` | Home bell | the number only |
| PATCH | `/api/notifications/read-all` | 31 | "Mark all as read" |
| PATCH | `/api/notifications/:id/read` | 31 | one row loses its dot |

### One record, four statuses

`new -> quoted -> accepted | declined`. Nothing else moves it:

- the buyer creates it (`new`);
- the admin sends a price (`quoted`) and the buyer gets a notification;
- the buyer accepts or declines. Only a `quoted` request can be answered: a
  `new` one answers 409 "This request has no price yet", an answered one says
  which status it already has.
- the admin may re-price while the request is `new` or `quoted` (a typo should
  be fixable), but not after the buyer answered (409).

### Rules that only live here

- 150 kg is the minimum, because screen 25 prints it under the quantity box.
- The product must be active (404) and the address must be the buyer's (404,
  never 403: a stranger learns nothing about somebody else's address).
- The note is optional, trimmed, at most 300 characters, `null` when empty.
- The shop price **at the moment of the request** is copied onto the quote, so
  screen 47 can print "Shop price $1.48 per kg, minus 10% bulk discount" and
  prefill the suggested price without another call, and a later price change
  never rewrites an old request.
- Money is stored in integer cents (`pricePerKgCents`, `quotedTotalCents`) and
  turned back into dollars only on the way out, like every chunk since 3. The
  total is `pricePerKgCents x quantityKg`, rounded once.
- Accepting a quote does **not** create an order: no screen or rule says it
  should, and inventing that would also invent stock checks, payment and a
  delivery slot.
- Request numbers use their own counter (`counters._id = "quotes"`) and the same
  atomic `$inc` as order numbers, so two buyers asking at once never share a
  number. QR-006 is three digits, then QR-1001 keeps growing.

### Notifications

Written in exactly one place, `addNotification`, so every notification in the
database came out of one function. Two producers today:

- **orders**: `createOrder` writes "Order FH-1042 placed", and every admin
  status change writes the next line of the story - being packed, on the way
  (with the window's hours), delivered ("How was your rice?"), cancelled
  ("Nothing was charged"). The wording is the pure function
  `orderNotification`, because the screen is judged on those sentences.
- **quotes**: `sendQuote` writes "Your quote is ready - Jasmine rice, 200 kg at
  $1.08 per kg. Total $216.00."

Three properties that matter:

1. `addNotification` swallows its own errors. A buyer who cannot be told about
   an order must not stop the order from being placed or moved.
2. The Accept / Decline buttons are **not** stored on the notification. The
   list joins the quote's status on every read (`canRespond`), so a quote
   answered on another device makes the buttons disappear here too.
3. The unread count comes back with the list, so screen 31 needs one request;
   the Home bell gets its own tiny endpoint and does not download the list.

### Decisions

- No push notifications, no email. The frames show an in-app list; the bell and
  the list are what the API can honestly serve. The push toggle on screen 33 is
  a device permission, not a column in this database.
- The admin is not notified of anything. No admin screen shows notifications;
  screen 47's "new" count already answers "is there work waiting?".
- The buyer is not told about their own cancellation, because they just did it.
- Notification wording is plain and stored as text, not stored as a template id.
  A template layer would be right for ten languages; there is one.
- `GET /api/quotes` exists although no frame draws the list: the notification
  links back to a single quote, and a buyer who has three open requests needs to
  find them somewhere.

## Chunk 10 - admin customers and reports

### Endpoints

| Method | Path | Screen | What it does |
|---|---|---|---|
| GET | `/api/admin/customers?q&customerType&page&limit` | 45 | one page of buyers plus the counts in the subtitle |
| GET | `/api/admin/customers/:id` | 46 | contact details, the three cards, the five newest orders |
| GET | `/api/admin/customers/:id/orders?page&limit` | 46 "View all" | the rest of that customer's history |
| GET | `/api/admin/reports?from&to` | 49 | revenue per day, top products, best customers |

### One rule that shapes both screens

**A cancelled order is not a purchase.** It is left out of the order count, the
money, the average, the last order date and the order history, so screen 45's
four columns, screen 46's three cards and screen 49's revenue card all tell the
same story. Screen 49 prints why: "Cancelled orders not counted". The report
still *reports* what it ignored (`summary.cancelled`, `summary.cancelledValue`),
because a report that hides the rows it dropped cannot be checked.

### Screen 45

- Only buyers are customers: `role != admin`. The owner never appears in the
  list, and opening the owner's own id answers 404.
- `customerType` is `all`, `business` or `household`; anything else is a 400.
- The subtitle counts the whole shop, not the filtered page.
- The page is ordered **by name**. The mock is ordered by last order date, but
  that value lives in another collection: sorting by it would mean loading
  every order in the shop to sort eight rows. Paginate first, then sort the
  page, is the honest version.
- Orders and addresses for a whole page are fetched in one query each and
  grouped in Dart, so eight rows do not become sixteen round trips.

### Screen 46

- `totalSpent` is the sum of `grandTotalCents`, `averageOrder` is that divided
  by the order count and rounded once in cents (the mock's 5126.80 / 11 =
  466.07).
- The address shown is the default one, falling back to the newest.
- The history shows the five newest and `showing` / `totalOrders` so the footer
  "Showing 5 of 11 orders" is not a guess.

### Screen 49

- No range means the last **seven Phnom Penh days, today included**, which is
  what the picker starts on. `from` alone or `to` alone also work.
- `from > to` is a 400, a fake date is a 400, and a range longer than a year is
  a 400.
- The chart is zero filled: every day of the range gets a point, otherwise the
  line would jump from Tuesday to Friday and lie about the week. The daily
  points always add up to the revenue card.
- Top products are by **kg sold**, best customers by **spend**, both top five.
- The whole report is one query for orders, one for users and one for addresses,
  grouped in Dart. Four aggregation pipelines would be faster on a million
  orders and much harder to explain; a rice shop has thousands.

### Decisions

- No export endpoint (the screen has no Export button on 49; screen 38's Export
  is a client-side CSV of a list it already has).
- The report has no "compare with last week" figures; the frames do not show
  one, and the dashboard already answers "vs yesterday".
- Customers are not given an admin-editable "notes" field: nothing on 45 or 46
  offers one.
- `GET /api/admin/customers/:id/orders` exists only so "View all orders" has
  somewhere to go; it returns the same row shape as screen 38.

## Chunk 11 - PayPal (sandbox)

### Endpoints

| Method | Path | Screen | What it does |
|---|---|---|---|
| POST | `/api/orders/:id/payments/paypal` | 21a "Pay with PayPal" | opens a payment, returns the approval link, 201 |
| GET | `/api/orders/:id/payments/paypal` | 21b waiting | has PayPal answered yet? |
| POST | `/api/orders/:id/payments/paypal/capture` | 23b / 24 | takes the money, or fails and frees the stock |

### What is real and what is not

There is no PayPal sandbox account in this project and there must never be a
secret in the repository, so the two calls that would reach PayPal's servers are
made locally against a `payments` collection. Everything around them is real:

- the order, the amount (the grand total the buyer saw on 21a), the delivery fee
  inside it;
- the state machine `created -> captured | failed`, with PayPal's own
  vocabulary (order id, approval link, capture);
- the guards: a cash order answers 400 "This order is paid on delivery", a
  cancelled order 409, a paid order 409, someone else's order 404;
- the stock: a failed payment puts the kg back on the shelf;
- the notification: "Payment received for FH-1042 - $170.20 paid with PayPal."

When real credentials exist, only `_sandboxCreate` and `_sandboxCapture` change.
The routes, the request bodies and the responses already speak PayPal's
language, which is why swapping the provider does not move a single screen.

### A failed payment cancels the order

Screen 24 says "Your order has not been placed". Leaving an unpaid order
`pending` forever would hold stock hostage and make that sentence a lie, so a
declined capture does exactly what a cancellation does: status `cancelled`,
`cancelReason: "Payment failed"`, `cancelReasonCode: "payment_failed"`,
`statusHistory` appended, and `restoreStockForOrder` returns the kg. "Try again"
therefore means placing the order again, from the cart the app still shows.

`order.paymentStatus` keeps its two old values (`unpaid`, `paid`), so chunks 3
and 7 did not have to change; the attempts live in `payments` with
`created | captured | failed`, and the order gains `paidAt` plus a small
`payment` summary. Both are additions, never replacements.

### Decisions

- Tapping "Pay with PayPal" twice re-uses the open payment instead of opening a
  second one; the buyer gets the same `SBX-...` id back.
- `approved` defaults to **true** in the capture body, because the app only gets
  there after the buyer pressed the button. Sending `approved: false` is how the
  failed-payment screen is reached without a real declined card.
- Dismissing the PayPal window is *not* a failure: the order stays unpaid and
  can be paid later, because nothing was declined.
- The capture path checks the payment's own state before the order's, so a
  double tap is answered "This payment was already captured" rather than the
  less useful "This order is already paid".
- The admin still cannot mark a PayPal order paid by hand (chunk 7's rule); the
  capture call is the only thing that writes `paid` for PayPal.
- Sandbox payment ids are prefixed `SBX-` so nobody mistakes one for a real
  PayPal order in a screenshot or a viva.

## Where the eleven chunks ended

| Chunk | Scope |
|---|---|
| 1 | done: skeleton, error shape, health, db_check |
| 2 | done: settings and the public settings view |
| 3 | done: cart, checkout, orders, cancel, reorder, invoice |
| 4 | done: profile, addresses, wishlist kept as it was |
| 5 | done: verified flag, 6-digit code, forgot/reset password, change password, admin login, customerType at sign-up |
| 6 | done: products/categories admin, stock and restock, seed |
| 7 | done: admin orders, dashboard, delivery schedule |
| 8 | done: reviews from delivered orders, rating block, one per product per order |
| 9 | done: bulk quotes through four statuses, notifications from orders and quotes |
| 10 | done: customers list, customer page, sales report |
| 11 | done: PayPal sandbox - create, capture, failed payment, stock back |

Left alone on purpose: `/health`, `/api/db_check`, wishlist, products route shape.
