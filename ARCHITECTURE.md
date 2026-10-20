# Architecture (v4)
* `lib/main.dart` - original screens, API client, store (logic unchanged) + hooks for the new features.
* `lib/brand.dart` - theme, sliding backgrounds, logo header, notification service/watcher.
* `lib/stock.dart` - stock overview + graphs, add stock, items used, history, background gallery.
* `lib/delivery.dart` - delivery jobs and customer-code check-in.
* `lib/customer.dart` - customer profile, wallet, tokens, events, subscriptions, payment proof, receipts, contact links.
* `lib/staff2.dart` - waiter desk, payments desk, today's team, staff activity, table codes, kitchen requests,
  admin settings, events/packages admin, code checker.
* `lib/push.dart` - push off (stub). `lib/push_firebase.dart.txt` replaces it when `firebase/google-services.json` exists.
* `backend/Code.gs` - all server logic. Customer sessions are tokens starting with `C` (sheet `CustomerSessions`).
  Customer actions are named `me*`; the app sends the customer token for them and the staff token for everything else.
* Payment states: Unpaid -> With waiter (cash) -> Paid | Unpaid -> Proof submitted (mobile money) -> Paid | Wallet/Tokens/Subscription -> Paid.
* Order statuses: Pending, Approved, Cooking, Ready, Assigned, Serving, Completed (+ Rejected, Cancelled, Failed).
