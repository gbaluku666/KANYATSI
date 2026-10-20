# KANYATSI RESTAURANT app

Flutter (Android) app + Google Sheets / Apps Script backend.

## How to update (in this order)

### 1. Backend
1. Apps Script: replace ALL of `Code.gs` with `backend/Code.gs`.
2. Run the function **`setupSheets`** once (accept permissions). It adds new columns and ~13 new tabs
   (Accounts, WalletTx, PaymentRequests, Events, EventTickets, SubPackages, Subscriptions, SubClaims,
   Attendance, StockRequests, Devices, ...). Your existing data stays.
3. **Deploy -> Manage deployments -> pencil -> New version -> Deploy.** (same URL)
4. Open the app as **admin** -> *Restaurant Settings* and fill in location, service numbers, social links,
   MTN / Airtel merchant codes and token ranges.

### 2. App
Upload everything in this folder to GitHub (keep folder names): `lib/ assets/ backend/ firebase/ pubspec.yaml .github/`.
Download the APK from Actions -> the run -> Artifacts. Uninstall the old app first.

### 3. Optional: push when the app is closed
Follow `firebase/README.txt`.

## What each role can do now

| Feature | Who |
|---|---|
| Orders grouped by payment method (All / Cash / MTN / Airtel / Wallet / Other) | Manager, Admin |
| Cash: waiter enters the customer's order code -> "MAKE SURE YOU HAVE COLLECTED CASH" -> recorded against the waiter; manager marks it received only by entering that order code | Waiter, Manager |
| Waiter desk: orders tied to the waiter, cash still to hand in, serve food, record walk-in orders | Waiter |
| Mobile money (MTN / Airtel): customer or waiter sends phone + transaction ID or screenshot; manager verifies and approves; receipt after completion | All |
| Serve flow: waiter presses *Serve food* -> customer presses *Receive food* -> 6-digit code -> waiter enters it -> order completed | Waiter, Customer |
| Check a code (order / event ticket / subscription meal): "Invalid code" if wrong | Waiter, Manager, Admin |
| Table codes: manager generates N six-digit codes (or switches codes off) | Manager, Admin |
| Today's Team: manager chooses who works today; ready orders go to the free worker with the fewest completed tasks; a worker is not free until the current order is finished | Manager, Admin |
| Staff Activity: tasks per worker, per day, per role; idle workers flagged | Manager, Admin |
| Kitchen requests items (from stock or typed) -> manager marks bought / approved / declined | Kitchen, Manager |
| Stock units: pick a unit or type your own (remembered) | Manager, Admin |
| Menu backgrounds per food category (slideshow; falls back to dish photos) | Manager, Admin |
| Location, service numbers, WhatsApp / Instagram / Email / X links; MTN & Airtel codes; token ranges | Admin |
| Customer profile (name, phone, password, picture), wallet, tokens, my orders | Customer |
| Reset a customer's forgotten password (6-digit temporary password valid 2 days, customer must change it) - tile **Customers** | Manager, Admin |
| Wallet top-up (cash to manager or mobile money) and paying with wallet | Customer |
| Tokens earned by bill range; meals can have a token price | Customer, Admin |
| Events with packages, pay in advance, entry code checked at the door | Customer, Manager, Waiter |
| Subscriptions: packages of meals for a period, daily meal code, skip days (end date moves) | Customer, Manager |

## Notes
* Waiter cash is a liability until the manager enters the order code. Mobile-money orders are never counted as cash the waiter holds.
* Manager order lists do not show order codes (only the customer holds them).
* Subscription meals are sent to the kitchen as normal orders with total UGX 0 (the package price is the revenue).
