/**
 * KANYATSI RESTAURANT - Google Sheets backend (Google Apps Script) v3
 *
 * The Google Sheet this script is attached to IS the database.
 * The Flutter app talks to this script as a JSON web API.
 *
 * SETUP (once):
 *  1. Create a Google Sheet. Open Extensions > Apps Script.
 *  2. Paste this whole file into Code.gs and save.
 *  3. Select the function  setupSheets  and press Run. Accept ALL permission
 *     prompts (Sheets, Drive for food pictures, Gmail for password-reset emails).
 *     It creates the tabs and a first admin:  admin / Admin@1234
 *     (the app forces a password change at first sign-in).
 *  4. Deploy > New deployment > type "Web app"
 *       Execute as: Me      Who has access: Anyone
 *     Copy the Web app URL (ends in /exec) into lib/main.dart (kApiUrl).
 *  5. After changing this script later: run setupSheets again (adds any new
 *     tabs/columns), then Deploy > Manage deployments > pencil > New version.
 *
 * ORDER FLOW
 *   Pending -> Approved (manager) -> Cooking -> Ready (kitchen)
 *           -> Assigned (manager picks waiter / delivery man) -> Completed
 *   Side exits: Rejected (manager, from Pending), Cancelled, Failed (delivery).
 */

var SESSION_SECONDS = 21600; // 6 hours (maximum for the cache)
var TIMEZONE = 'Africa/Kampala';
var MAX_LOGIN_FAILS = 5;
var LOCKOUT_SECONDS = 600;
var HASH_ROUNDS = 1000;
var IMAGE_FOLDER = 'Kanyatsi Menu Images';
var MAX_IMAGE_BYTES = 1500000;

var SHEETS = {
  Menu: ['id', 'name', 'category', 'price', 'description', 'available', 'imageUrl', 'tokenPrice'],
  Combos: ['id', 'name', 'description', 'price', 'available', 'imageUrl', 'itemsJson'],
  Stations: ['id', 'name', 'fee'],
  Settings: ['key', 'value'],
  Orders: ['id', 'createdAt', 'mode', 'table', 'stationId', 'stationName', 'customer',
           'phone', 'note', 'status', 'rejectReason', 'paymentMethod', 'paymentStatus',
           'subtotal', 'deliveryFee', 'total', 'channel', 'approvedBy', 'approvedAt',
           'cookedBy', 'readyAt', 'assignedToId', 'assignedToName', 'completedBy',
           'completedAt', 'updatedAt',
           'code', 'codeUsed', 'codeUsedAt', 'deliveryNote', 'amountCollected',
           'source', 'createdById', 'createdByName', 'customerId', 'payProvider', 'payPhone',
           'txnId', 'proofUrl', 'proofAt', 'cashById', 'cashByName', 'cashAt', 'cashHandedAt',
           'cashReceivedBy', 'serveCode', 'servedAt', 'tokensUsed', 'tokensEarned'],
  OrderItems: ['orderId', 'kind', 'itemId', 'name', 'qty', 'unitPrice', 'lineTotal', 'servings'],
  Inventory: ['id', 'name', 'unit', 'stock', 'minimum', 'packName', 'packSize', 'packPrice',
              'unitPrice', 'fullLevel', 'lowPct', 'updatedAt'],
  StockMovements: ['timestamp', 'itemId', 'name', 'change', 'reason', 'by', 'kind', 'unit', 'cost', 'balance'],
  Notifications: ['id', 'timestamp', 'roles', 'userId', 'title', 'body', 'orderId', 'kind'],
  Users: ['id', 'name', 'username', 'email', 'role', 'salt', 'passHash', 'active', 'mustChange'],
  Customers: ['phone', 'name', 'whatsappOptIn', 'optInDate'],
  Accounts: ['id', 'name', 'phone', 'salt', 'passHash', 'photoUrl', 'wallet', 'tokens', 'active', 'createdAt'],
  CustomerSessions: ['token', 'customerId', 'createdAt'],
  WalletTx: ['id', 'timestamp', 'customerId', 'change', 'reason', 'refId', 'balance'],
  PaymentRequests: ['id', 'createdAt', 'kind', 'refId', 'customerId', 'customerName', 'amount', 'method',
                    'provider', 'phone', 'txnId', 'proofUrl', 'status', 'handledBy', 'handledAt', 'note'],
  Events: ['id', 'title', 'date', 'time', 'imageUrl', 'details', 'packagesJson', 'active', 'createdAt'],
  EventTickets: ['id', 'eventId', 'eventTitle', 'packageName', 'amount', 'customerId', 'customerName',
                 'phone', 'method', 'status', 'code', 'paidAt', 'usedAt', 'usedBy'],
  SubPackages: ['id', 'name', 'description', 'days', 'price', 'itemsJson', 'active', 'imageUrl'],
  Subscriptions: ['id', 'customerId', 'customerName', 'packageId', 'packageName', 'startDate', 'endDate',
                  'balancesJson', 'status', 'paidAt', 'pausedDays'],
  SubClaims: ['id', 'subId', 'customerId', 'dishId', 'dishName', 'code', 'date', 'status', 'redeemedBy', 'redeemedAt'],
  Attendance: ['date', 'userId', 'name', 'role'],
  StockRequests: ['id', 'createdAt', 'by', 'byId', 'itemId', 'itemName', 'qty', 'unit', 'note', 'status',
                  'handledBy', 'handledAt'],
  Devices: ['token', 'userId', 'role', 'updatedAt'],
  Audit: ['timestamp', 'user', 'role', 'action', 'details']
};

// Columns kept as text (phone numbers keep their leading 0, hashes never become numbers).
var TEXT_COLUMNS = {
  Orders: ['createdAt', 'phone', 'approvedAt', 'readyAt', 'completedAt', 'updatedAt', 'code', 'codeUsedAt',
           'payPhone', 'txnId', 'proofAt', 'cashAt', 'cashHandedAt', 'serveCode', 'servedAt'],
  StockMovements: ['timestamp'],
  Notifications: ['timestamp'],
  Inventory: ['updatedAt'],
  Users: ['username', 'email', 'salt', 'passHash'],
  Customers: ['phone', 'optInDate'],
  Accounts: ['phone', 'salt', 'passHash', 'createdAt'],
  CustomerSessions: ['token', 'createdAt'],
  WalletTx: ['timestamp'],
  PaymentRequests: ['createdAt', 'phone', 'handledAt'],
  Events: ['date', 'time', 'createdAt'],
  EventTickets: ['phone', 'code', 'paidAt', 'usedAt'],
  Subscriptions: ['startDate', 'endDate', 'paidAt'],
  SubClaims: ['code', 'date', 'redeemedAt'],
  Attendance: ['date'],
  StockRequests: ['createdAt', 'handledAt'],
  Devices: ['token', 'updatedAt'],
  Audit: ['timestamp']
};

var ROLES = ['admin', 'manager', 'kitchen', 'waiter', 'delivery'];
var MODES = ['Indoor', 'Takeaway', 'Delivery'];
var CUSTOMER_PAYMENTS = {
  Indoor: ['Cash', 'MTN', 'Airtel', 'Wallet', 'Tokens'],
  Takeaway: ['Cash', 'MTN', 'Airtel', 'Wallet', 'Tokens'],
  Delivery: ['MTN', 'Airtel', 'Pay on Delivery', 'Wallet']
};
var MANAGER_PAYMENTS = ['Cash', 'MTN', 'Airtel', 'Pay on Delivery'];
var OPEN_STATUSES = ['Pending', 'Approved', 'Cooking', 'Ready', 'Assigned', 'Serving'];

// ---------------------------------------------------------------- entry points

function doGet() {
  return json_({ ok: true, message: 'Kanyatsi Restaurant API is running.', version: 'v4.2' });
}

// Requests that only READ data never queue behind writers (much faster when many people use the app).
var READ_ONLY_ = {};
['getMenu', 'listOrders', 'listKitchen', 'listMine', 'listMyDone', 'listCompleted', 'listInventory',
 'listNotifications', 'meNotifications', 'listStockMovements', 'stockReport', 'stats', 'paymentsDesk',
 'waiterDesk', 'getAttendance', 'workerStats', 'listTableCodes', 'listEvents', 'listEventsAdmin',
 'listSubPackages', 'listSubscriptionsAdmin', 'meProfile', 'meOrders', 'meTickets', 'trackOrder',
 'listStaff', 'listUsers', 'listCustomers', 'listStockRequests', 'myStockRequests', 'listUnits'
].forEach(function (a) { READ_ONLY_[a] = true; });

function doPost(e) {
  TCACHE_ = {}; SHEETOBJ_ = {};
  var lock = LockService.getScriptLock();
  try {
    var req = JSON.parse(e.postData.contents);
    var handler = HANDLERS[String(req.action || '')];
    if (!handler) throw new Error('Unknown action');

    var user = null;
    if (handler.roles !== 'public') {
      user = sessionUser_(req.token);
      if (!user) throw new Error('SESSION_EXPIRED');
      if (handler.roles === 'any') {
        if (user.role === 'customer') throw new Error('FORBIDDEN');
      } else if (handler.roles.indexOf(user.role) < 0) {
        throw new Error('FORBIDDEN');
      }
    }
    if (!READ_ONLY_[String(req.action)]) lock.waitLock(20000);
    return json_({ ok: true, data: handler.run(req, user) });
  } catch (err) {
    return json_({ ok: false, error: String(err.message || err) });
  } finally {
    try { lock.releaseLock(); } catch (x) {}
  }
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
      .setMimeType(ContentService.MimeType.JSON);
}

var MGR = ['admin', 'manager'];

var HANDLERS = {
  // ----- public (customers)
  login:         { roles: 'public', run: login_ },
  requestReset:  { roles: 'public', run: requestReset_ },
  resetPassword: { roles: 'public', run: resetPassword_ },
  getMenu:       { roles: 'public', run: getMenu_ },
  createOrder:   { roles: 'public', run: createOrder_ },
  trackOrder:    { roles: 'public', run: trackOrder_ },
  cancelMyOrder: { roles: 'public', run: cancelMyOrder_ },

  // ----- any signed-in staff
  logout:         { roles: 'any', run: logout_ },
  listNotifications: { roles: 'any', run: listNotifications_ },
  changePassword: { roles: 'any', run: changePassword_ },

  // ----- manager / admin: orders
  listOrders:     { roles: MGR, run: listOrders_ },
  listCompleted:  { roles: MGR, run: listCompleted_ },
  approveOrder:   { roles: MGR, run: approveOrder_ },
  rejectOrder:    { roles: MGR, run: rejectOrder_ },
  allocateOrder:  { roles: MGR, run: allocateOrder_ },
  cancelOrder:    { roles: MGR, run: cancelOrder_ },
  markPaid:       { roles: MGR, run: markPaid_ },
  recordOrder:    { roles: ['admin', 'manager', 'waiter'], run: recordOrder_ },
  listTableCodes: { roles: MGR, run: listTableCodes_ },
  generateTableCodes: { roles: MGR, run: generateTableCodes_ },
  setTableCodesRequired: { roles: MGR, run: setTableCodesRequired_ },
  paymentsDesk:   { roles: MGR, run: paymentsDesk_ },
  confirmPayment: { roles: MGR, run: confirmPayment_ },
  rejectPayment:  { roles: MGR, run: rejectPayment_ },
  receiveCash:    { roles: MGR, run: receiveCash_ },
  confirmPaymentRequest: { roles: MGR, run: confirmPaymentRequest_ },
  rejectPaymentRequest:  { roles: MGR, run: rejectPaymentRequest_ },
  getAttendance:  { roles: MGR, run: getAttendance_ },
  setAttendance:  { roles: MGR, run: setAttendance_ },
  assignNow:      { roles: MGR, run: assignNow_ },
  workerStats:    { roles: MGR, run: workerStats_ },
  listStockRequests:   { roles: MGR, run: listStockRequests_ },
  resolveStockRequest: { roles: MGR, run: resolveStockRequest_ },
  addUnit:        { roles: MGR, run: addUnit_ },
  saveCategoryImages: { roles: MGR, run: saveCategoryImages_ },
  saveEvent:      { roles: MGR, run: saveEvent_ },
  deleteEvent:    { roles: MGR, run: deleteEvent_ },
  listEventsAdmin: { roles: MGR, run: listEventsAdmin_ },
  saveSubPackage: { roles: MGR, run: saveSubPackage_ },
  deleteSubPackage: { roles: MGR, run: deleteSubPackage_ },
  listSubscriptionsAdmin: { roles: MGR, run: listSubscriptionsAdmin_ },
  saveRestaurantInfo: { roles: ['admin'], run: saveRestaurantInfo_ },
  saveMomoSettings:   { roles: ['admin'], run: saveMomoSettings_ },
  saveTokenRules:     { roles: ['admin'], run: saveTokenRules_ },

  // ----- waiter, manager, admin
  checkCode:        { roles: ['waiter', 'admin', 'manager'], run: checkCode_ },
  admitEventCode:   { roles: ['waiter', 'admin', 'manager'], run: admitEventCode_ },
  redeemSubscriptionCode: { roles: ['waiter', 'admin', 'manager'], run: redeemSubscriptionCode_ },
  staffPaymentProof: { roles: ['waiter', 'admin', 'manager'], run: staffPaymentProof_ },
  waiterDesk:       { roles: ['waiter'], run: waiterDesk_ },
  collectCash:      { roles: ['waiter'], run: collectCash_ },
  serveOrder:       { roles: ['waiter'], run: serveOrder_ },
  completeServe:    { roles: ['waiter', 'admin', 'manager'], run: completeServe_ },
  listUnits:        { roles: ['admin', 'manager', 'kitchen'], run: listUnits_ },
  createStockRequest: { roles: ['kitchen', 'admin', 'manager'], run: createStockRequest_ },
  myStockRequests:  { roles: ['kitchen'], run: myStockRequests_ },
  registerDevice:   { roles: ['customer', 'admin', 'manager', 'kitchen', 'waiter', 'delivery'], run: registerDevice_ },
  unregisterDevice: { roles: ['customer', 'admin', 'manager', 'kitchen', 'waiter', 'delivery'], run: unregisterDevice_ },

  // ----- customers (public)
  listEvents:       { roles: 'public', run: listEvents_ },
  listSubPackages:  { roles: 'public', run: listSubPackages_ },
  verifyTableCode:  { roles: 'public', run: verifyTableCode_ },
  submitPaymentProof: { roles: 'public', run: submitPaymentProof_ },
  receiveFood:      { roles: 'public', run: receiveFood_ },
  meRegister:       { roles: 'public', run: meRegister_ },
  meLogin:          { roles: 'public', run: meLogin_ },

  // ----- customers (signed in)
  meProfile:        { roles: ['customer'], run: meProfile_ },
  meUpdate:         { roles: ['customer'], run: meUpdate_ },
  meChangePassword: { roles: ['customer'], run: meChangePassword_ },
  meLogout:         { roles: ['customer'], run: meLogout_ },
  meCreateOrder:    { roles: ['customer'], run: meCreateOrder_ },
  meOrders:         { roles: ['customer'], run: meOrders_ },
  meTopUp:          { roles: ['customer'], run: meTopUp_ },
  meBuyTicket:      { roles: ['customer'], run: meBuyTicket_ },
  meTickets:        { roles: ['customer'], run: meTickets_ },
  meBuyPackage:     { roles: ['customer'], run: meBuyPackage_ },
  meSubscriptions:  { roles: ['customer'], run: meSubscriptions_ },
  meSkipDays:       { roles: ['customer'], run: meSkipDays_ },
  meClaimMeal:      { roles: ['customer'], run: meClaimMeal_ },
  meNotifications:  { roles: ['customer'], run: meNotifications_ },
  meRegisterDevice: { roles: ['customer'], run: registerDevice_ },
  listCustomers:    { roles: MGR, run: listCustomers_ },
  resetCustomerPassword: { roles: MGR, run: resetCustomerPassword_ },
  meUnregisterDevice: { roles: ['customer'], run: unregisterDevice_ },
  listStaff:      { roles: MGR, run: listStaff_ },

  // ----- manager / admin: menu, combos, stations, tables
  saveDish:         { roles: MGR, run: saveDish_ },
  deleteDish:       { roles: MGR, run: deleteDish_ },
  setAvailability:  { roles: MGR, run: setAvailability_ },
  saveCombo:        { roles: MGR, run: saveCombo_ },
  deleteCombo:      { roles: MGR, run: deleteCombo_ },
  setComboAvailability: { roles: MGR, run: setComboAvailability_ },
  uploadImage:      { roles: MGR, run: uploadImage_ },
  saveStation:      { roles: MGR, run: saveStation_ },
  deleteStation:    { roles: MGR, run: deleteStation_ },
  saveTableCount:   { roles: MGR, run: saveTableCount_ },

  // ----- manager / admin: inventory, statistics, promotions
  listInventory:     { roles: ['admin', 'manager', 'kitchen'], run: listInventory_ },
  adjustStock:       { roles: MGR, run: adjustStock_ },
  saveInventoryItem: { roles: MGR, run: saveInventoryItem_ },
  deleteInventoryItem: { roles: MGR, run: deleteInventoryItem_ },
  addStock:          { roles: MGR, run: addStock_ },
  useStock:          { roles: ['kitchen', 'admin', 'manager'], run: useStock_ },
  stockReport:       { roles: MGR, run: stockReport_ },
  listStockMovements: { roles: MGR, run: listStockMovements_ },
  saveHeroImages:    { roles: MGR, run: saveHeroImages_ },
  sendNotification:  { roles: MGR, run: sendNotification_ },
  stats:             { roles: MGR, run: stats_ },
  listSubscribers:   { roles: MGR, run: listSubscribers_ },

  // ----- kitchen
  listKitchen:  { roles: ['kitchen', 'admin', 'manager'], run: listKitchen_ },
  startCooking: { roles: ['kitchen', 'admin', 'manager'], run: startCooking_ },
  markReady:    { roles: ['kitchen', 'admin', 'manager'], run: markReady_ },

  // ----- waiter / delivery man
  listMine:      { roles: ['waiter', 'delivery'], run: listMine_ },
  listMyDone:    { roles: ['waiter', 'delivery'], run: listMyDone_ },
  lookupDeliveryCode: { roles: ['delivery'], run: lookupDeliveryCode_ },
  confirmDelivery:    { roles: ['delivery'], run: confirmDelivery_ },
  completeOrder: { roles: ['waiter', 'delivery', 'admin', 'manager'], run: completeOrder_ },
  failOrder:     { roles: ['delivery', 'admin', 'manager'], run: failOrder_ },

  // ----- admin only
  listUsers:         { roles: ['admin'], run: listUsers_ },
  saveUser:          { roles: ['admin'], run: saveUser_ },
  updateUser:        { roles: ['admin'], run: updateUser_ },
  setUserActive:     { roles: ['admin'], run: setUserActive_ },
  resetUserPassword: { roles: ['admin'], run: resetUserPassword_ },
  deleteUser:        { roles: ['admin'], run: deleteUser_ },
  listAudit:         { roles: ['admin'], run: listAudit_ }
};

// ------------------------------------------------------------------------ auth

function sha256hex_(str) {
  var bytes = Utilities.computeDigest(
      Utilities.DigestAlgorithm.SHA_256, str, Utilities.Charset.UTF_8);
  return bytes.map(function (b) {
    return ('0' + (b < 0 ? b + 256 : b).toString(16)).slice(-2);
  }).join('');
}

function hashPassword_(salt, password) {
  var h = String(salt) + ':' + String(password);
  for (var i = 0; i < HASH_ROUNDS; i++) h = sha256hex_(h + salt);
  return h;
}

function validatePassword_(pw) {
  pw = String(pw || '');
  if (pw.length < 6 || pw.length > 64) throw new Error('Password must be 6 to 64 characters');
}

function login_(req) {
  var username = String(req.username || '').trim().toLowerCase();
  var password = String(req.password || '');
  if (!username || !password) throw new Error('Enter your username and password');

  var cache = CacheService.getScriptCache();
  var failKey = 'fails_' + username;
  var fails = Number(cache.get(failKey) || 0);
  if (fails >= MAX_LOGIN_FAILS) {
    throw new Error('Too many wrong attempts. Try again in 10 minutes.');
  }
  var found = findUserByUsername_(username);
  var ok = found && toBool_(found.active) &&
           hashPassword_(found.salt, password) === String(found.passHash);
  if (!ok) {
    cache.put(failKey, String(fails + 1), LOCKOUT_SECONDS);
    throw new Error('Wrong username or password');
  }
  cache.remove(failKey);

  var token = Utilities.getUuid() + Utilities.getUuid();
  var session = { id: Number(found.id), name: String(found.name),
                  username: String(found.username), role: String(found.role) };
  cache.put('t_' + token, JSON.stringify(session), SESSION_SECONDS);
  audit_(session, 'Login', '');
  return { token: token, role: session.role, name: session.name,
           mustChange: toBool_(found.mustChange) };
}

function logout_(req, user) {
  CacheService.getScriptCache().remove('t_' + req.token);
  audit_(user, 'Logout', '');
  return true;
}

function sessionUser_(token) {
  if (!token) return null;
  if (String(token).charAt(0) === 'C') return customerSession_(String(token));
  var raw = CacheService.getScriptCache().get('t_' + String(token));
  if (!raw) return null;
  var s = JSON.parse(raw);
  // Re-check the account every time, so disabling a user takes effect at once.
  var u = findRow_('Users', 'id', s.id);
  if (!u || !toBool_(u.active)) return null;
  s.role = String(u.role);
  s.name = String(u.name);
  return s;
}

function findUserByUsername_(username) {
  var users = readTable_('Users');
  for (var i = 0; i < users.length; i++) {
    if (String(users[i].username).toLowerCase() === username) return users[i];
  }
  return null;
}

function changePassword_(req, user) {
  validatePassword_(req.newPassword);
  var u = findRow_('Users', 'id', user.id);
  if (!u) throw new Error('User not found');
  if (hashPassword_(u.salt, req.oldPassword) !== String(u.passHash)) {
    throw new Error('Current password is wrong');
  }
  if (String(req.newPassword) === String(req.oldPassword)) {
    throw new Error('Choose a different password');
  }
  setPassword_(user.id, req.newPassword, false);
  audit_(user, 'Password changed', '');
  return true;
}

function setPassword_(userId, password, mustChange) {
  var salt = Utilities.getUuid();
  updateRow_('Users', 'id', userId, {
    salt: salt, passHash: hashPassword_(salt, password), mustChange: !!mustChange
  });
}

// Forgot password: a 6-digit code is emailed to the address the admin saved.
function requestReset_(req) {
  var username = String(req.username || '').trim().toLowerCase();
  var generic = { message: 'If this username has an email address saved, a code has been sent. ' +
                           'Otherwise ask the administrator to reset your password.' };
  if (!username) throw new Error('Enter your username');
  var cache = CacheService.getScriptCache();
  var rlKey = 'resetreq_' + username;
  var count = Number(cache.get(rlKey) || 0);
  if (count >= 3) throw new Error('Too many requests. Try again in an hour.');
  cache.put(rlKey, String(count + 1), 3600);

  var u = findUserByUsername_(username);
  if (u && toBool_(u.active) && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(String(u.email))) {
    var code = String(Math.floor(100000 + Math.random() * 900000));
    cache.put('reset_' + username,
              JSON.stringify({ h: sha256hex_(code + ':' + u.salt), tries: 0 }), 900);
    MailApp.sendEmail(String(u.email), 'Kanyatsi Restaurant - password reset code',
        'Hello ' + u.name + ',\n\nYour password reset code is ' + code +
        '.\nIt works for 15 minutes. If you did not ask for it, ignore this email.');
    audit_({ name: String(u.name), role: String(u.role) }, 'Password reset requested', '');
  }
  return generic;
}

function resetPassword_(req) {
  var username = String(req.username || '').trim().toLowerCase();
  validatePassword_(req.newPassword);
  var cache = CacheService.getScriptCache();
  var raw = cache.get('reset_' + username);
  var u = findUserByUsername_(username);
  if (!raw || !u) throw new Error('The code is wrong or has expired');
  var rec = JSON.parse(raw);
  if (rec.tries >= 5) { cache.remove('reset_' + username); throw new Error('Too many attempts. Request a new code.'); }
  if (sha256hex_(String(req.code || '').trim() + ':' + u.salt) !== rec.h) {
    rec.tries++;
    cache.put('reset_' + username, JSON.stringify(rec), 900);
    throw new Error('The code is wrong or has expired');
  }
  cache.remove('reset_' + username);
  cache.remove('fails_' + username);
  setPassword_(u.id, req.newPassword, false);
  audit_({ name: String(u.name), role: String(u.role) }, 'Password reset by code', '');
  return true;
}

// ----------------------------------------------------------------- users (admin)

function publicUser_(u) {
  return { id: Number(u.id), name: String(u.name), username: String(u.username),
           email: String(u.email || ''), role: String(u.role), active: toBool_(u.active) };
}

function listUsers_() {
  return readTable_('Users').map(publicUser_);
}

function listStaff_() {
  return readTable_('Users').filter(function (u) { return toBool_(u.active); })
      .map(function (u) { return { id: Number(u.id), name: String(u.name), role: String(u.role) }; });
}

function validEmail_(email) {
  email = String(email || '').trim();
  if (email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new Error('Enter a valid email or leave it empty');
  return email;
}

function activeAdminCount_(exceptId) {
  return readTable_('Users').filter(function (u) {
    return u.role === 'admin' && toBool_(u.active) && String(u.id) !== String(exceptId);
  }).length;
}

function saveUser_(req, user) {
  var name = String(req.name || '').trim();
  var username = String(req.username || '').trim().toLowerCase();
  var role = String(req.role || '');
  var email = validEmail_(req.email);
  if (!name || !/^[a-z0-9._-]{3,30}$/.test(username)) {
    throw new Error('Name is required; username needs 3-30 letters/numbers');
  }
  if (ROLES.indexOf(role) < 0) throw new Error('Choose a role');
  validatePassword_(req.password);
  if (findUserByUsername_(username)) throw new Error('That username is already taken');
  var id = nextId_('Users', 'id', 1);
  var salt = Utilities.getUuid();
  appendRow_('Users', { id: id, name: name, username: username, email: email, role: role,
                        salt: salt, passHash: hashPassword_(salt, req.password),
                        active: true, mustChange: true });
  audit_(user, 'User created', username + ' (' + role + ')');
  return { id: id };
}

function updateUser_(req, user) {
  var u = findRow_('Users', 'id', req.id);
  if (!u) throw new Error('User not found');
  var name = String(req.name || '').trim();
  var role = String(req.role || '');
  if (!name) throw new Error('Name is required');
  if (ROLES.indexOf(role) < 0) throw new Error('Choose a role');
  if (u.role === 'admin' && role !== 'admin' && activeAdminCount_(u.id) === 0) {
    throw new Error('There must be at least one active administrator');
  }
  updateRow_('Users', 'id', req.id, { name: name, email: validEmail_(req.email), role: role });
  audit_(user, 'User edited', u.username + ' -> ' + role);
  return true;
}

function setUserActive_(req, user) {
  var u = findRow_('Users', 'id', req.id);
  if (!u) throw new Error('User not found');
  if (!req.active && u.role === 'admin' && activeAdminCount_(u.id) === 0) {
    throw new Error('There must be at least one active administrator');
  }
  if (String(u.id) === String(user.id) && !req.active) {
    throw new Error('You cannot disable your own account');
  }
  updateRow_('Users', 'id', req.id, { active: !!req.active });
  audit_(user, req.active ? 'User enabled' : 'User disabled', u.username);
  return true;
}

function resetUserPassword_(req, user) {
  var u = findRow_('Users', 'id', req.id);
  if (!u) throw new Error('User not found');
  validatePassword_(req.password);
  setPassword_(u.id, req.password, true);
  CacheService.getScriptCache().remove('fails_' + String(u.username).toLowerCase());
  audit_(user, 'Password reset by admin', u.username);
  return true;
}

function deleteUser_(req, user) {
  var u = findRow_('Users', 'id', req.id);
  if (!u) throw new Error('User not found');
  if (String(u.id) === String(user.id)) throw new Error('You cannot delete your own account');
  if (u.role === 'admin' && toBool_(u.active) && activeAdminCount_(u.id) === 0) {
    throw new Error('There must be at least one active administrator');
  }
  deleteRow_('Users', 'id', req.id);
  audit_(user, 'User deleted', u.username);
  return true;
}

function listAudit_() {
  var rows = readTable_('Audit').map(function (a) {
    return { timestamp: String(a.timestamp), user: String(a.user), role: String(a.role),
             action: String(a.action), details: String(a.details) };
  });
  return rows.reverse().slice(0, 150);
}

// ------------------------------------------------------------ menu / combos / info

function dishView_(m) {
  return { id: Number(m.id), name: String(m.name), category: String(m.category),
           price: Number(m.price), description: String(m.description || ''),
           available: toBool_(m.available), imageUrl: String(m.imageUrl || ''),
           tokenPrice: Number(m.tokenPrice) || 0 };
}

function parseItems_(json) {
  try {
    var arr = JSON.parse(String(json || '[]'));
    return Array.isArray(arr) ? arr : [];
  } catch (e) { return []; }
}

function getMenu_() {
  var cache = CacheService.getScriptCache();
  var hit = cache.get('menu_json');
  if (hit) { try { return JSON.parse(hit); } catch (e) {} }
  var m = buildMenu_();
  try { cache.put('menu_json', JSON.stringify(m), 120); } catch (e2) {}
  return m;
}

function buildMenu_() {
  var dishes = readTable_('Menu');
  var byId = {};
  dishes.forEach(function (d) { byId[String(d.id)] = d; });

  var combos = readTable_('Combos').map(function (c) {
    var items = parseItems_(c.itemsJson).map(function (it) {
      var d = byId[String(it.id)];
      return { id: Number(it.id), name: d ? String(d.name) : '(removed dish)', qty: Number(it.qty) };
    });
    var allThere = items.length > 0 && items.every(function (it) {
      var d = byId[String(it.id)];
      return d && toBool_(d.available);
    });
    var itemsTotal = 0;
    items.forEach(function (it) {
      var d = byId[String(it.id)];
      if (d) itemsTotal += Number(d.price) * it.qty;
    });
    return { id: Number(c.id), name: String(c.name), description: String(c.description || ''),
             price: Number(c.price), available: toBool_(c.available) && allThere,
             enabled: toBool_(c.available), imageUrl: String(c.imageUrl || ''),
             items: items, itemsTotal: itemsTotal };
  });

  var stations = readTable_('Stations').map(function (s) {
    return { id: Number(s.id), name: String(s.name), fee: Number(s.fee) };
  });
  return { dishes: dishes.map(dishView_), combos: combos, stations: stations,
           tableCount: Number(getSetting_('tableCount', 10)),
           heroImages: parseItems_(getSetting_('heroImages', '[]')),
           categoryImages: parseObj_(getSetting_('categoryImages', '{}')),
           tableCodesRequired: toBool_(getSetting_('tableCodesRequired', false)),
           info: getInfo_(), momo: getMomo_(), tokenRules: getTokenRules_() };
}

function saveDish_(req, user) {
  var it = req.item || {};
  var name = String(it.name || '').trim();
  var category = String(it.category || '').trim();
  var price = Number(it.price);
  if (!name || !category) throw new Error('Name and category are required');
  if (!(price >= 0)) throw new Error('Enter a valid price');
  var row = { name: name, category: category, price: price,
              description: String(it.description || '').trim(),
              available: it.available === false ? false : true,
              imageUrl: String(it.imageUrl || ''), tokenPrice: Math.max(0, Math.floor(Number(it.tokenPrice) || 0)) };
  if (it.id) {
    var old = findRow_('Menu', 'id', it.id);
    if (!old) throw new Error('Dish not found');
    updateRow_('Menu', 'id', it.id, row);
    audit_(user, Number(old.price) !== price ? 'Price change' : 'Dish edited',
           Number(old.price) !== price ? name + ': ' + old.price + ' -> ' + price : name);
    return { id: Number(it.id) };
  }
  row.id = nextId_('Menu', 'id', 1);
  appendRow_('Menu', row);
  audit_(user, 'Dish added', name + ' @ ' + price);
  return { id: row.id };
}

function deleteDish_(req, user) {
  var d = findRow_('Menu', 'id', req.id);
  if (!d) throw new Error('Dish not found');
  var inCombo = readTable_('Combos').filter(function (c) {
    return parseItems_(c.itemsJson).some(function (it) { return String(it.id) === String(req.id); });
  });
  if (inCombo.length) throw new Error('This dish is part of the combo "' + inCombo[0].name + '". Edit the combo first.');
  deleteRow_('Menu', 'id', req.id);
  audit_(user, 'Dish deleted', String(d.name));
  return true;
}

function setAvailability_(req, user) {
  var d = findRow_('Menu', 'id', req.id);
  if (!d) throw new Error('Dish not found');
  updateRow_('Menu', 'id', req.id, { available: !!req.available });
  audit_(user, 'Availability', d.name + ' -> ' + (req.available ? 'available' : 'unavailable'));
  return true;
}

function saveCombo_(req, user) {
  var c = req.item || {};
  var name = String(c.name || '').trim();
  var price = Number(c.price);
  if (!name) throw new Error('Name is required');
  if (!(price >= 0)) throw new Error('Enter a valid price');
  var items = Array.isArray(c.items) ? c.items : [];
  var clean = [];
  items.forEach(function (it) {
    var qty = Math.floor(Number(it.qty));
    if (qty >= 1) {
      if (!findRow_('Menu', 'id', it.id)) throw new Error('A selected dish no longer exists');
      clean.push({ id: Number(it.id), qty: qty });
    }
  });
  if (clean.length < 2 && !(clean.length === 1 && clean[0].qty >= 2)) {
    throw new Error('A combo needs at least two servings of food');
  }
  var row = { name: name, description: String(c.description || '').trim(), price: price,
              available: c.available === false ? false : true,
              imageUrl: String(c.imageUrl || ''), itemsJson: JSON.stringify(clean) };
  if (c.id) {
    if (!findRow_('Combos', 'id', c.id)) throw new Error('Combo not found');
    updateRow_('Combos', 'id', c.id, row);
    audit_(user, 'Combo edited', name + ' @ ' + price);
    return { id: Number(c.id) };
  }
  row.id = nextId_('Combos', 'id', 1);
  appendRow_('Combos', row);
  audit_(user, 'Combo added', name + ' @ ' + price);
  return { id: row.id };
}

function deleteCombo_(req, user) {
  var c = findRow_('Combos', 'id', req.id);
  if (!c) throw new Error('Combo not found');
  deleteRow_('Combos', 'id', req.id);
  audit_(user, 'Combo deleted', String(c.name));
  return true;
}

function setComboAvailability_(req, user) {
  var c = findRow_('Combos', 'id', req.id);
  if (!c) throw new Error('Combo not found');
  updateRow_('Combos', 'id', req.id, { available: !!req.available });
  audit_(user, 'Combo availability', c.name + ' -> ' + (req.available ? 'available' : 'unavailable'));
  return true;
}

// Food pictures are stored in Google Drive; only the link is kept in the sheet.
function storeImage_(data, mime, size, prefix) {
  mime = String(mime || 'image/jpeg');
  if (['image/jpeg', 'image/png'].indexOf(mime) < 0) throw new Error('Use a JPG or PNG picture');
  var bytes = Utilities.base64Decode(String(data || ''));
  if (!bytes.length) throw new Error('No picture received');
  if (bytes.length > MAX_IMAGE_BYTES) throw new Error('Picture is too large. Choose a smaller one.');
  var folders = DriveApp.getFoldersByName(IMAGE_FOLDER);
  var folder = folders.hasNext() ? folders.next() : DriveApp.createFolder(IMAGE_FOLDER);
  var ext = mime === 'image/png' ? '.png' : '.jpg';
  var file = folder.createFile(Utilities.newBlob(bytes, mime, (prefix || 'food') + '_' + new Date().getTime() + ext));
  file.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW);
  var width = Math.max(400, Math.min(1600, Math.floor(Number(size || 800))));
  return 'https://drive.google.com/thumbnail?id=' + file.getId() + '&sz=w' + width;
}

function uploadImage_(req, user) {
  var url = storeImage_(req.data, req.mime, req.size, 'food');
  audit_(user, 'Picture uploaded', '');
  return { url: url };
}

function saveStation_(req, user) {
  var name = String(req.name || '').trim();
  var fee = Number(req.fee);
  if (!name) throw new Error('Station name is required');
  if (!(fee >= 0)) throw new Error('Enter a valid delivery fee');
  var dup = readTable_('Stations').filter(function (s) {
    return String(s.name).toLowerCase() === name.toLowerCase() && String(s.id) !== String(req.id || '');
  });
  if (dup.length) throw new Error('A station with that name already exists');
  if (req.id) {
    var old = findRow_('Stations', 'id', req.id);
    if (!old) throw new Error('Station not found');
    updateRow_('Stations', 'id', req.id, { name: name, fee: fee });
    audit_(user, 'Station edited', name + ' fee ' + old.fee + ' -> ' + fee);
    return { id: Number(req.id) };
  }
  var id = nextId_('Stations', 'id', 1);
  appendRow_('Stations', { id: id, name: name, fee: fee });
  audit_(user, 'Station added', name + ' fee ' + fee);
  return { id: id };
}

function deleteStation_(req, user) {
  var s = findRow_('Stations', 'id', req.id);
  if (!s) throw new Error('Station not found');
  deleteRow_('Stations', 'id', req.id);
  audit_(user, 'Station removed', String(s.name));
  return true;
}

function saveTableCount_(req, user) {
  var n = Math.floor(Number(req.tableCount));
  if (!(n >= 1 && n <= 200)) throw new Error('Tables must be between 1 and 200');
  setSetting_('tableCount', n);
  audit_(user, 'Table count', String(n));
  return { tableCount: n };
}

// -------------------------------------------------------------------- orders

function cleanPhone_(p) { return String(p || '').replace(/[^0-9]/g, ''); }
function last9_(p) { return cleanPhone_(p).slice(-9); }

// Builds and stores an order. Used by customers (createOrder / meCreateOrder) and staff (recordOrder).
function buildOrder_(req, opts) {
  var items = req.items;
  if (!Array.isArray(items) || items.length === 0) throw new Error('Nothing selected');
  if (items.length > 60) throw new Error('Too many items');
  var acct = opts.customer || null;
  var role = opts.user ? opts.user.role : '';

  var mode = String(req.mode || '');
  if (MODES.indexOf(mode) < 0) throw new Error('Choose Indoor, Takeaway or Delivery');
  var payment = String(req.payment || '');
  var allowed = opts.subscription ? ['Subscription'] : (opts.staff ? MANAGER_PAYMENTS : CUSTOMER_PAYMENTS[mode]);
  if (allowed.indexOf(payment) < 0) throw new Error('Choose how you will pay');
  if ((payment === 'Wallet' || payment === 'Tokens') && !acct) {
    throw new Error('Sign in to your profile to pay with your ' + (payment === 'Wallet' ? 'wallet' : 'tokens'));
  }

  var name = String(req.customer || (acct ? acct.name : '')).trim().slice(0, 60);
  var phone = cleanPhone_(req.phone || (acct ? acct.phone : ''));
  var note = String(req.note || '').trim().slice(0, 200);
  var phoneNeeded = !opts.staff || mode === 'Delivery';
  if (phoneNeeded && phone.length < 9) throw new Error('Enter a valid phone number');
  if (!opts.staff && mode !== 'Indoor' && !name) throw new Error('Enter your name');

  var table = '', stationId = '', stationName = '', fee = 0;
  if (mode === 'Indoor') {
    table = Math.floor(Number(req.table));
    var count = Number(getSetting_('tableCount', 10));
    if (!(table >= 1 && table <= count)) throw new Error('Choose your table number');
    if (!opts.staff) checkTableCode_(table, req.tableCode);
  } else if (mode === 'Delivery') {
    var st = findRow_('Stations', 'id', req.stationId);
    if (!st) throw new Error('Choose a delivery pick-up station');
    stationId = Number(st.id); stationName = String(st.name); fee = Number(st.fee);
  }

  if (!opts.staff && phone) {
    var pending = readTable_('Orders').filter(function (o) {
      return o.status === 'Pending' && last9_(o.phone) === last9_(phone);
    }).length;
    if (pending >= 3) throw new Error('You already have orders waiting for confirmation. Please wait for our call.');
  }

  // Prices ALWAYS come from the sheet, never from the app.
  var menu = getMenu_();
  var dishes = {}, combos = {};
  menu.dishes.forEach(function (d) { dishes[String(d.id)] = d; });
  menu.combos.forEach(function (c) { combos[String(c.id)] = c; });

  var lines = [], subtotal = 0, tokensUsed = 0;
  items.forEach(function (x) {
    var qty = Math.floor(Number(x.qty));
    if (!(qty >= 1 && qty <= 50)) throw new Error('Invalid quantity');
    if (x.kind === 'combo') {
      if (payment === 'Tokens') throw new Error('Combos cannot be paid with tokens');
      var c = combos[String(x.id)];
      if (!c) throw new Error('A combo on your order no longer exists');
      if (!c.available) throw new Error(c.name + ' is not available right now');
      var per = c.items.reduce(function (s, it) { return s + it.qty; }, 0);
      lines.push({ kind: 'combo', itemId: c.id, name: c.name, qty: qty, unitPrice: c.price,
                   lineTotal: c.price * qty, servings: per * qty });
      subtotal += c.price * qty;
    } else {
      var d = dishes[String(x.id)];
      if (!d) throw new Error('A dish on your order no longer exists');
      if (!d.available) throw new Error(d.name + ' is not available right now');
      if (payment === 'Tokens') {
        if (!(d.tokenPrice > 0)) throw new Error(d.name + ' cannot be bought with tokens');
        tokensUsed += d.tokenPrice * qty;
      }
      lines.push({ kind: 'dish', itemId: d.id, name: d.name, qty: qty, unitPrice: d.price,
                   lineTotal: d.price * qty, servings: qty });
      subtotal += d.price * qty;
    }
  });

  var total = subtotal + fee;
  if (payment === 'Tokens') {
    if (mode === 'Delivery') throw new Error('Tokens can be used for indoor and takeaway orders');
    if ((Number(acct.tokens) || 0) < tokensUsed) {
      throw new Error('You need ' + tokensUsed + ' tokens. You have ' + (Number(acct.tokens) || 0) + '.');
    }
    total = 0;
  }
  if (payment === 'Subscription') total = 0;
  if (payment === 'Wallet' && (Number(acct.wallet) || 0) < total) {
    throw new Error('Not enough money in your wallet. Top up first.');
  }

  var orderId = nextId_('Orders', 'id', 1001);
  var now = now_();
  var payStatus = 'Unpaid', cash = { cashById: '', cashByName: '', cashAt: '' };
  if (payment === 'Wallet' || payment === 'Tokens' || payment === 'Subscription') payStatus = 'Paid';
  else if (opts.staff && role !== 'waiter' && req.paid) payStatus = 'Paid';
  else if (opts.staff && role === 'waiter' && payment === 'Cash' && req.paid) {
    payStatus = 'With waiter';
    cash = { cashById: opts.user.id, cashByName: opts.user.name, cashAt: now };
  }
  var order = {
    id: orderId, createdAt: now, mode: mode, table: table, stationId: stationId,
    stationName: stationName, customer: name || (opts.staff ? 'Walk-in Customer' : 'Guest'),
    phone: phone, note: note, status: opts.staff ? 'Approved' : 'Pending',
    rejectReason: '', paymentMethod: payment, paymentStatus: payStatus,
    subtotal: subtotal, deliveryFee: fee, total: total,
    channel: opts.staff ? (role === 'waiter' ? 'Waiter' : 'Manager') : 'App',
    approvedBy: opts.staff ? opts.user.name : '', approvedAt: opts.staff ? now : '',
    cookedBy: '', readyAt: '', assignedToId: '', assignedToName: '',
    completedBy: '', completedAt: '', updatedAt: now,
    code: newDeliveryCode_(), codeUsed: false, codeUsedAt: '',
    deliveryNote: '', amountCollected: '',
    source: opts.staff ? 'staff' : 'app',
    createdById: opts.staff ? opts.user.id : '', createdByName: opts.staff ? opts.user.name : '',
    customerId: acct ? acct.id : (opts.linkCustomerId || ''), payProvider: '', payPhone: '', txnId: '', proofUrl: '', proofAt: '',
    cashById: cash.cashById, cashByName: cash.cashByName, cashAt: cash.cashAt, cashHandedAt: '',
    cashReceivedBy: '', serveCode: '', servedAt: '', tokensUsed: tokensUsed, tokensEarned: ''
  };
  appendRow_('Orders', order);
  lines.forEach(function (l) {
    appendRow_('OrderItems', { orderId: orderId, kind: l.kind, itemId: l.itemId, name: l.name,
      qty: l.qty, unitPrice: l.unitPrice, lineTotal: l.lineTotal, servings: l.servings });
  });
  if (payment === 'Wallet') debitWallet_(acct.id, total, 'Order #' + orderId, orderId);
  if (payment === 'Tokens') addTokens_(acct.id, -tokensUsed);
  if (phone.length >= 9) saveCustomer_(phone, name, !opts.staff && !!req.whatsappOptIn);
  audit_(opts.user || { name: acct ? acct.name : 'Customer', role: 'customer' },
         opts.staff ? 'Order recorded' : 'Order placed', '#' + orderId + ' UGX ' + total + ' ' + payment);
  if (opts.staff) {
    notify_(['kitchen'], '', 'New order to cook', '#' + orderId + ' - ' + mode, orderId, 'order');
    if ((payment === 'MTN' || payment === 'Airtel') && (req.txnId || req.proofData)) {
      applyProof_(findRow_('Orders', 'id', orderId), req, opts.user);
    }
  } else {
    notify_(['manager', 'admin'], '', 'New order #' + orderId,
            mode + ' - ' + (name || 'Guest') + ' - ' + (payment === 'Tokens' ? tokensUsed + ' tokens' : 'UGX ' + total) + ' - ' + payment, orderId, 'order');
  }
  return { orderId: orderId, total: total, deliveryFee: fee, code: String(order.code), tokensUsed: tokensUsed };
}

function createOrder_(req) { return buildOrder_(req, { staff: false, user: null, customer: null }); }

function meCreateOrder_(req, acct) { return buildOrder_(req, { staff: false, user: null, customer: acct }); }

function recordOrder_(req, user) { return buildOrder_(req, { staff: true, user: user, customer: null }); }

function orderView_(o, itemsByOrder, includeCode) {
  var lines = itemsByOrder[String(o.id)] || [];
  return {
    id: Number(o.id), createdAt: String(o.createdAt), mode: String(o.mode),
    table: o.table === '' ? 0 : Number(o.table), stationName: String(o.stationName || ''),
    customer: String(o.customer), phone: String(o.phone), note: String(o.note || ''),
    status: String(o.status), rejectReason: String(o.rejectReason || ''),
    payment: String(o.paymentMethod), paymentStatus: String(o.paymentStatus),
    subtotal: Number(o.subtotal), deliveryFee: Number(o.deliveryFee), total: Number(o.total),
    channel: String(o.channel), approvedBy: String(o.approvedBy || ''),
    assignedToId: o.assignedToId === '' ? 0 : Number(o.assignedToId),
    assignedToName: String(o.assignedToName || ''), completedBy: String(o.completedBy || ''),
    completedAt: String(o.completedAt || ''), lines: lines,
    code: includeCode ? String(o.code || '') : '',
    hasCode: String(o.code || '') !== '',
    codeUsed: toBool_(o.codeUsed), codeUsedAt: String(o.codeUsedAt || ''),
    deliveryNote: String(o.deliveryNote || ''),
    amountCollected: o.amountCollected === '' ? 0 : Number(o.amountCollected),
    source: String(o.source || ''), createdByName: String(o.createdByName || ''),
    payProvider: String(o.payProvider || ''), payPhone: String(o.payPhone || ''),
    txnId: String(o.txnId || ''), proofUrl: String(o.proofUrl || ''), proofAt: String(o.proofAt || ''),
    cashByName: String(o.cashByName || ''), cashAt: String(o.cashAt || ''),
    cashHandedAt: String(o.cashHandedAt || ''), cashReceivedBy: String(o.cashReceivedBy || ''),
    tokensUsed: Number(o.tokensUsed) || 0, tokensEarned: Number(o.tokensEarned) || 0,
    servedAt: String(o.servedAt || '')
  };
}

function itemsByOrder_() {
  var map = {};
  readTable_('OrderItems').forEach(function (x) {
    (map[String(x.orderId)] = map[String(x.orderId)] || []).push(x.qty + ' x ' + x.name);
  });
  return map;
}

function viewOrders_(filterFn, limit, newestFirst, includeCode) {
  var items = itemsByOrder_();
  var rows = readTable_('Orders').filter(filterFn).map(function (o) { return orderView_(o, items, !!includeCode); });
  rows.sort(function (a, b) { return newestFirst ? b.id - a.id : a.id - b.id; });
  return rows.slice(0, limit);
}

function listOrders_() { return viewOrders_(function () { return true; }, 300, true, false); }

function listCompleted_(req) {
  var days = Math.max(0, Math.floor(Number(req.days || 0)));
  var cutoff = days > 0 ? daysAgoStr_(days - 1) : '';
  return viewOrders_(function (o) {
    return o.status === 'Completed' && (!cutoff || String(o.completedAt).slice(0, 10) >= cutoff);
  }, 300, true, false);
}

function listKitchen_() {
  return viewOrders_(function (o) { return o.status === 'Approved' || o.status === 'Cooking'; }, 100, false);
}

function listMine_(req, user) {
  return viewOrders_(function (o) {
    return o.status === 'Assigned' && String(o.assignedToId) === String(user.id);
  }, 100, false);
}

function getOrder_(id) {
  var o = findRow_('Orders', 'id', id);
  if (!o) throw new Error('Order not found');
  return o;
}

function expect_(o, statuses, message) {
  if (statuses.indexOf(o.status) < 0) throw new Error(message || ('Order #' + o.id + ' is ' + o.status));
}

function setStatus_(o, changes) {
  changes.updatedAt = now_();
  updateRow_('Orders', 'id', o.id, changes);
}

function approveOrder_(req, user) {
  var o = getOrder_(req.id);
  expect_(o, ['Pending'], 'Only pending orders can be approved');
  setStatus_(o, { status: 'Approved', approvedBy: user.name, approvedAt: now_() });
  audit_(user, 'Order approved', '#' + o.id);
  notify_(['kitchen'], '', 'New order to cook', '#' + o.id + ' - ' + o.mode, o.id, 'order');
  if (String(o.customerId) !== '') notifyCustomer_(o.customerId, 'Order #' + o.id + ' confirmed', 'It has been sent to the kitchen.', o.id, 'order');
  return true;
}

function rejectOrder_(req, user) {
  var o = getOrder_(req.id);
  expect_(o, ['Pending'], 'Only pending orders can be rejected');
  var reason = String(req.reason || '').trim().slice(0, 150);
  if (!reason) throw new Error('Give a reason for the customer');
  setStatus_(o, { status: 'Rejected', rejectReason: reason });
  refundOrder_(o);
  audit_(user, 'Order rejected', '#' + o.id + ': ' + reason);
  if (String(o.customerId) !== '') notifyCustomer_(o.customerId, 'Order #' + o.id + ' not accepted', reason, o.id, 'alert');
  return true;
}

function startCooking_(req, user) {
  var o = getOrder_(req.id);
  expect_(o, ['Approved'], 'This order is not waiting for the kitchen');
  setStatus_(o, { status: 'Cooking', cookedBy: user.name });
  audit_(user, 'Cooking started', '#' + o.id);
  return true;
}

function markReady_(req, user) {
  var o = getOrder_(req.id);
  expect_(o, ['Cooking', 'Approved'], 'This order is not being cooked');
  setStatus_(o, { status: 'Ready', readyAt: now_(), cookedBy: o.cookedBy || user.name });
  audit_(user, 'Order ready', '#' + o.id);
  notify_(['manager', 'admin'], '', 'Order #' + o.id + ' is ready',
          'Give it to a ' + (o.mode === 'Delivery' ? 'delivery man' : 'waiter') + '.', o.id, 'order');
  if (String(o.customerId) !== '') notifyCustomer_(o.customerId, 'Order #' + o.id + ' is ready', 'Your food is ready.', o.id, 'order');
  autoAssign_();
  return true;
}

function assignOrder_(o, staff, note, by) {
  note = String(note || '').trim().slice(0, 300);
  if (!note && o.mode === 'Delivery' && o.paymentStatus !== 'Paid' &&
      (o.paymentMethod === 'Pay on Delivery' || o.paymentMethod === 'Cash')) {
    note = 'Collect UGX ' + o.total + ' from the customer on delivery.';
  }
  setStatus_(o, { status: 'Assigned', assignedToId: Number(staff.id), assignedToName: String(staff.name),
                  deliveryNote: note });
  audit_(by, 'Order allocated', '#' + o.id + ' -> ' + staff.name);
  var cashHint = (o.mode !== 'Delivery' && o.paymentMethod === 'Cash' && o.paymentStatus === 'Unpaid')
    ? ' - COLLECT CASH UGX ' + o.total : '';
  notify_([], staff.id, 'Order #' + o.id + ' assigned to you',
          (o.mode === 'Delivery' ? 'Deliver to ' + o.stationName : 'Serve: ' + o.mode +
           (o.table !== '' ? ' table ' + o.table : '')) + cashHint + (note ? ' - ' + note : ''), o.id, 'assignment');
}

function allocateOrder_(req, user) {
  var o = getOrder_(req.id);
  expect_(o, ['Ready', 'Assigned'], 'Only ready orders can be allocated');
  var staff = findRow_('Users', 'id', req.staffId);
  if (!staff || !toBool_(staff.active)) throw new Error('Choose an active staff member');
  var needed = o.mode === 'Delivery' ? 'delivery' : 'waiter';
  if (staff.role !== needed) {
    throw new Error(o.mode === 'Delivery' ? 'Choose a delivery man' : 'Choose a waiter');
  }
  assignOrder_(o, staff, req.note, user);
  return true;
}

function isAssignee_(o, user) {
  return String(o.assignedToId) === String(user.id);
}

// Everything that happens when an order is finished (any way).
function finishOrder_(o, user, detail) {
  awardTokens_(o);
  notify_(['manager', 'admin'], '', 'Order #' + o.id + ' completed', detail || ('By ' + user.name), o.id, 'order');
  if (String(o.customerId) !== '') {
    notifyCustomer_(o.customerId, 'Order #' + o.id + ' complete', 'Enjoy your meal. Thank you!', o.id, 'order');
  }
  autoAssign_();
}

function completeOrder_(req, user) {
  var o = getOrder_(req.id);
  expect_(o, ['Assigned', 'Serving'], 'This order has not been allocated yet');
  if (user.role !== 'admin' && user.role !== 'manager' && !isAssignee_(o, user)) {
    throw new Error('FORBIDDEN');
  }
  if (o.mode === 'Delivery' && String(o.code || '') !== '' && !toBool_(o.codeUsed) &&
      user.role === 'delivery') {
    throw new Error('Enter the customer\'s delivery code to complete this delivery.');
  }
  if (user.role === 'waiter' && o.source === 'app' && o.mode !== 'Delivery') {
    throw new Error('Press "Serve food", then enter the code the customer receives.');
  }
  var done = { status: 'Completed', completedBy: user.name, completedAt: now_() };
  if (o.mode === 'Delivery' && String(o.code || '') !== '' && !toBool_(o.codeUsed)) {
    done.codeUsed = true; done.codeUsedAt = now_();   // manager override also closes the code
  }
  setStatus_(o, done);
  audit_(user, 'Order completed', '#' + o.id);
  finishOrder_(o, user);
  return true;
}

function failOrder_(req, user) {
  var o = getOrder_(req.id);
  expect_(o, ['Assigned'], 'This order is not out for delivery');
  if (o.mode !== 'Delivery') throw new Error('Only deliveries can fail');
  if (user.role !== 'admin' && user.role !== 'manager' && !isAssignee_(o, user)) {
    throw new Error('FORBIDDEN');
  }
  var reason = String(req.reason || '').trim().slice(0, 150);
  if (!reason) throw new Error('Give the reason the delivery failed');
  setStatus_(o, { status: 'Failed', rejectReason: reason, codeUsed: true, codeUsedAt: now_() });
  audit_(user, 'Delivery failed', '#' + o.id + ': ' + reason);
  notify_(['manager', 'admin'], '', 'Delivery failed #' + o.id, reason, o.id, 'alert');
  autoAssign_();
  return true;
}

function cancelOrder_(req, user) {
  var o = getOrder_(req.id);
  expect_(o, OPEN_STATUSES, 'This order can no longer be cancelled');
  var reason = String(req.reason || '').trim().slice(0, 150);
  if (!reason) throw new Error('Give a reason');
  setStatus_(o, { status: 'Cancelled', rejectReason: reason, codeUsed: true });
  refundOrder_(o);
  audit_(user, 'Order cancelled', '#' + o.id + ': ' + reason);
  if (String(o.customerId) !== '') notifyCustomer_(o.customerId, 'Order #' + o.id + ' cancelled', reason, o.id, 'alert');
  autoAssign_();
  return true;
}

// Money paid from the customer's wallet / tokens goes back when the order does not happen.
function refundOrder_(o) {
  if (String(o.customerId) === '' || o.paymentStatus !== 'Paid') return;
  if (o.paymentMethod === 'Wallet') {
    creditWallet_(o.customerId, Number(o.total), 'Refund order #' + o.id, o.id);
    updateRow_('Orders', 'id', o.id, { paymentStatus: 'Refunded' });
  } else if (o.paymentMethod === 'Tokens') {
    addTokens_(o.customerId, Number(o.tokensUsed) || 0);
    updateRow_('Orders', 'id', o.id, { paymentStatus: 'Refunded' });
  }
}

function markPaid_(req, user) {
  var o = getOrder_(req.id);
  if (['Rejected', 'Cancelled', 'Failed'].indexOf(o.status) >= 0) throw new Error('This order was not completed');
  if (o.paymentStatus === 'With waiter') throw new Error('The waiter has this cash. Use Cash hand-in and enter the order code.');
  if (o.paymentStatus === 'Proof submitted') throw new Error('Check the mobile money details and press Approve payment.');
  setStatus_(o, { paymentStatus: 'Paid' });
  audit_(user, 'Payment recorded', '#' + o.id + ' UGX ' + o.total + ' via ' + o.paymentMethod);
  return true;
}

// Customer follow-up with order number + phone.
function findCustomerOrder_(req) {
  var o = findRow_('Orders', 'id', req.orderId);
  var phone = cleanPhone_(req.phone);
  if (!o || phone.length < 9 || last9_(o.phone) !== last9_(phone)) {
    throw new Error('Order not found. Check the order number and phone number.');
  }
  return o;
}

function receiptFor_(o) {
  var lines = readTable_('OrderItems').filter(function (x) { return String(x.orderId) === String(o.id); })
    .map(function (x) {
      return { name: String(x.name), qty: Number(x.qty), unitPrice: Number(x.unitPrice), lineTotal: Number(x.lineTotal) };
    });
  return { orderId: Number(o.id), date: String(o.completedAt || o.createdAt), customer: String(o.customer),
           mode: String(o.mode), lines: lines, subtotal: Number(o.subtotal), deliveryFee: Number(o.deliveryFee),
           total: Number(o.total), method: String(o.paymentMethod), txnId: String(o.txnId || ''),
           tokensUsed: Number(o.tokensUsed) || 0 };
}

function trackView_(o) {
  var v = {
    id: Number(o.id), status: String(o.status), mode: String(o.mode),
    table: o.table === '' ? 0 : Number(o.table), stationName: String(o.stationName || ''),
    total: Number(o.total), paymentMethod: String(o.paymentMethod),
    paymentStatus: String(o.paymentStatus), rejectReason: String(o.rejectReason || ''),
    assignedToName: String(o.assignedToName || ''), updatedAt: String(o.updatedAt),
    code: String(o.code || ''), codeUsed: toBool_(o.codeUsed),
    payProvider: String(o.payProvider || ''), hasProof: String(o.proofAt || '') !== '',
    tokensUsed: Number(o.tokensUsed) || 0, tokensEarned: Number(o.tokensEarned) || 0,
    source: String(o.source || ''),
    serveCode: o.status === 'Serving' ? String(o.serveCode || '') : '',
    receipt: null
  };
  if (o.status === 'Completed') v.receipt = receiptFor_(o);
  return v;
}

function trackOrder_(req) { return trackView_(findCustomerOrder_(req)); }

function cancelMyOrder_(req) {
  var o = findCustomerOrder_(req);
  expect_(o, ['Pending'], 'This order has already been approved. Please call the restaurant to cancel.');
  setStatus_(o, { status: 'Cancelled', rejectReason: 'Cancelled by customer', codeUsed: true });
  refundOrder_(o);
  audit_({ name: 'Customer', role: 'customer' }, 'Order cancelled', '#' + o.id);
  notify_(['manager', 'admin'], '', 'Order #' + o.id + ' cancelled', 'Cancelled by the customer', o.id, 'alert');
  return true;
}

// ---------------- serving with a code (customer presses "Receive food")
function serveOrder_(req, user) {
  var o = getOrder_(req.id);
  expect_(o, ['Assigned'], 'This order is not waiting to be served');
  if (!isAssignee_(o, user)) throw new Error('FORBIDDEN');
  if (o.mode === 'Delivery') throw new Error('Deliveries use the delivery code');
  setStatus_(o, { status: 'Serving', servedAt: now_() });
  audit_(user, 'Food served', '#' + o.id);
  if (String(o.customerId) !== '') {
    notifyCustomer_(o.customerId, 'Your food is here', 'Open the app and press Receive food.', o.id, 'order');
  }
  return true;
}

function receiveFood_(req) {
  var o = findCustomerOrder_(req);
  expect_(o, ['Serving'], 'Your waiter has not served this order yet');
  var code = String(o.serveCode || '');
  if (!code) {
    code = String(Math.floor(100000 + Math.random() * 900000));
    setStatus_(o, { serveCode: code });
  }
  return { code: code };
}

function completeServe_(req, user) {
  var o = getOrder_(req.id);
  expect_(o, ['Serving'], 'This order has not been served yet');
  if (user.role === 'waiter' && !isAssignee_(o, user)) throw new Error('FORBIDDEN');
  var code = String(req.code || '').replace(/[^0-9]/g, '');
  if (!code || code !== String(o.serveCode || '')) {
    throw new Error('Wrong code. Ask the customer to press Receive food in their app.');
  }
  setStatus_(o, { status: 'Completed', completedBy: user.name, completedAt: now_(), serveCode: '' });
  audit_(user, 'Order completed (served)', '#' + o.id);
  finishOrder_(o, user);
  return true;
}


// ================================================================== v4: shared helpers

function todayStr_() { return Utilities.formatDate(new Date(), TIMEZONE, 'yyyy-MM-dd'); }
function addDays_(ymdStr, n) {
  var p = String(ymdStr).split('-');
  var d = new Date(Date.UTC(Number(p[0]), Number(p[1]) - 1, Number(p[2]) + n));
  return d.getUTCFullYear() + '-' + pad2_(d.getUTCMonth() + 1) + '-' + pad2_(d.getUTCDate());
}
function parseObj_(json) {
  try {
    var o = JSON.parse(String(json || '{}'));
    return (o && typeof o === 'object' && !Array.isArray(o)) ? o : {};
  } catch (e) { return {}; }
}
function normCode_(c) { return String(c || '').trim().toUpperCase().replace(/[^A-Z0-9]/g, ''); }
function randomCode_(len) {
  var c = '';
  for (var i = 0; i < len; i++) c += CODE_ALPHABET.charAt(Math.floor(Math.random() * CODE_ALPHABET.length));
  return c;
}
function newUniqueCode_(sheetName, len) {
  var used = {};
  readTable_(sheetName).forEach(function (r) { if (r.code) used[String(r.code)] = true; });
  for (var i = 0; i < 50; i++) { var c = randomCode_(len); if (!used[c]) return c; }
  throw new Error('Could not make a code. Please try again.');
}
function deleteRowsWhere_(name, fn) {
  var s = sheet_(name), last = s.getLastRow();
  if (last < 2) return;
  var headers = SHEETS[name];
  var values = s.getRange(2, 1, last - 1, headers.length).getValues();
  for (var i = values.length - 1; i >= 0; i--) {
    var o = {};
    headers.forEach(function (h, j) { o[h] = values[i][j]; });
    if (fn(o)) s.deleteRow(i + 2);
  }
  dropCache_(name);
}

// ================================================================== restaurant info (admin editable)

function getInfo_() {
  var social = parseObj_(getSetting_('social', '{}'));
  return { location: String(getSetting_('location', 'Kagando, Uganda')),
           phones: parseItems_(getSetting_('servicePhones', '[]')).map(function (p) {
             return { label: String(p.label || ''), number: String(p.number || '') };
           }),
           social: { whatsapp: String(social.whatsapp || ''), instagram: String(social.instagram || ''),
                     email: String(social.email || ''), x: String(social.x || '') } };
}

function saveRestaurantInfo_(req, user) {
  var location = String(req.location || '').trim().slice(0, 200);
  var phones = (Array.isArray(req.phones) ? req.phones : []).slice(0, 8).map(function (p) {
    var number = String(p.number || '').trim();
    if (number && !/^[0-9+ ()-]{6,20}$/.test(number)) throw new Error('Check the phone number: ' + number);
    return { label: String(p.label || '').trim().slice(0, 30), number: number };
  }).filter(function (p) { return p.number; });
  var social = {};
  var inSocial = req.social || {};
  ['whatsapp', 'instagram', 'email', 'x'].forEach(function (k) {
    var v = String(inSocial[k] || '').trim().slice(0, 300);
    if (v && k === 'email' && !/^mailto:/i.test(v)) {
      if (!validEmail_(v)) throw new Error('Enter a valid email address');
      v = 'mailto:' + v;
    }
    if (v && k !== 'email' && !/^https:\/\//i.test(v)) throw new Error('The ' + k + ' link must start with https://');
    social[k] = v;
  });
  setSetting_('location', location);
  setSetting_('servicePhones', JSON.stringify(phones));
  setSetting_('social', JSON.stringify(social));
  audit_(user, 'Restaurant info updated', location);
  return getInfo_();
}

function getMomo_() {
  var m = parseObj_(getSetting_('momo', '{}'));
  function one(k, ussd) {
    var x = m[k] || {};
    return { ussd: String(x.ussd !== undefined ? x.ussd : ussd), merchant: String(x.merchant || ''),
             instructions: String(x.instructions || '') };
  }
  return { mtn: one('mtn', '*165#'), airtel: one('airtel', '*185#') };
}

function saveMomoSettings_(req, user) {
  var out = {};
  ['mtn', 'airtel'].forEach(function (k) {
    var x = (req.momo || {})[k] || {};
    out[k] = { ussd: String(x.ussd || '').trim().slice(0, 30), merchant: String(x.merchant || '').trim().slice(0, 30),
               instructions: String(x.instructions || '').trim().slice(0, 500) };
  });
  setSetting_('momo', JSON.stringify(out));
  audit_(user, 'Mobile money details updated', '');
  return getMomo_();
}

function saveCategoryImages_(req, user) {
  var cat = String(req.category || '').trim().slice(0, 40);
  if (!cat) throw new Error('Choose a category');
  var list = (Array.isArray(req.images) ? req.images : []).map(function (u) { return String(u || '').trim(); })
    .filter(function (u) { return /^https:\/\//.test(u) && u.length < 500; });
  if (list.length > 10) throw new Error('At most 10 pictures per category');
  var all = parseObj_(getSetting_('categoryImages', '{}'));
  if (list.length) all[cat] = list; else delete all[cat];
  setSetting_('categoryImages', JSON.stringify(all));
  audit_(user, 'Category pictures updated', cat + ': ' + list.length);
  return { categoryImages: all };
}

// ================================================================== table codes

function checkTableCode_(table, code) {
  if (!toBool_(getSetting_('tableCodesRequired', false))) return;
  var codes = parseObj_(getSetting_('tableCodes', '{}'));
  var want = codes[String(table)];
  if (!want) return;
  if (String(code || '').trim() !== String(want)) {
    throw new Error('Wrong table code. Please type the code that is on your table.');
  }
}

function verifyTableCode_(req) {
  var cache = CacheService.getScriptCache();
  var key = 'tfail_' + Math.floor(Number(req.table) || 0);
  var fails = Number(cache.get(key) || 0);
  if (fails >= 20) throw new Error('Too many wrong codes for this table. Ask the waiter to help.');
  try { checkTableCode_(Math.floor(Number(req.table)), req.code); }
  catch (e) { cache.put(key, String(fails + 1), LOCKOUT_SECONDS); throw e; }
  return true;
}

function listTableCodes_() {
  var codes = parseObj_(getSetting_('tableCodes', '{}'));
  var count = Number(getSetting_('tableCount', 10));
  var out = [];
  for (var n = 1; n <= count; n++) out.push({ table: n, code: String(codes[String(n)] || '') });
  return { required: toBool_(getSetting_('tableCodesRequired', false)), codes: out };
}

function generateTableCodes_(req, user) {
  var n = Math.floor(Number(req.count));
  if (!(n >= 1 && n <= 200)) throw new Error('Tables must be between 1 and 200');
  var codes = {}, used = {};
  for (var t = 1; t <= n; t++) {
    var c;
    do { c = String(Math.floor(100000 + Math.random() * 900000)); } while (used[c]);
    used[c] = true; codes[String(t)] = c;
  }
  setSetting_('tableCodes', JSON.stringify(codes));
  setSetting_('tableCount', n);
  setSetting_('tableCodesRequired', true);
  audit_(user, 'Table codes generated', String(n));
  return listTableCodes_();
}

function setTableCodesRequired_(req, user) {
  setSetting_('tableCodesRequired', !!req.required);
  audit_(user, 'Table codes ' + (req.required ? 'required' : 'switched off'), '');
  return listTableCodes_();
}

// ================================================================== customer accounts

function acctView_(a) {
  return { id: Number(a.id), name: String(a.name), phone: String(a.phone), photoUrl: String(a.photoUrl || ''),
           wallet: Number(a.wallet) || 0, tokens: Number(a.tokens) || 0 };
}

function acctByPhone_(phone) {
  var p = last9_(phone), found = null;
  if (p.length < 9) return null;
  readTable_('Accounts').forEach(function (a) { if (last9_(a.phone) === p) found = a; });
  return found;
}

function customerSession_(token) {
  var cache = CacheService.getScriptCache();
  var id = cache.get('c_' + token);
  if (!id) {
    var row = findRow_('CustomerSessions', 'token', token);
    if (!row) return null;
    if (String(row.createdAt).slice(0, 10) < daysAgoStr_(60)) {
      deleteRow_('CustomerSessions', 'token', token);
      return null;
    }
    id = String(row.customerId);
    cache.put('c_' + token, id, SESSION_SECONDS);
  }
  var a = findRow_('Accounts', 'id', id);
  if (!a || !toBool_(a.active)) return null;
  return { id: Number(a.id), name: String(a.name), phone: String(a.phone), role: 'customer',
           wallet: Number(a.wallet) || 0, tokens: Number(a.tokens) || 0, photoUrl: String(a.photoUrl || '') };
}

function newCustomerSession_(a) {
  var token = 'C' + Utilities.getUuid() + Utilities.getUuid();
  appendRow_('CustomerSessions', { token: token, customerId: Number(a.id), createdAt: now_() });
  CacheService.getScriptCache().put('c_' + token, String(a.id), SESSION_SECONDS);
  return token;
}

function meRegister_(req) {
  var name = String(req.name || '').trim().slice(0, 60);
  var phone = cleanPhone_(req.phone);
  var password = String(req.password || '').trim();
  if (name.length < 2) throw new Error('Enter your name');
  if (phone.length < 9) throw new Error('Enter a valid phone number');
  if (password.length < 6) throw new Error('Choose a password of at least 6 characters');
  if (acctByPhone_(phone)) throw new Error('This phone number already has a profile. Please sign in.');
  var photo = req.photoData ? storeImage_(req.photoData, req.photoMime, 500, 'profile') : '';
  var salt = Utilities.getUuid();
  var a = { id: nextId_('Accounts', 'id', 1), name: name, phone: phone, salt: salt,
            passHash: hashPassword_(salt, password), photoUrl: photo, wallet: 0, tokens: 0,
            active: true, createdAt: now_() };
  appendRow_('Accounts', a);
  audit_({ name: name, role: 'customer' }, 'Customer profile created', phone);
  return { token: newCustomerSession_(a), profile: acctView_(a) };
}

// A password the manager reset is stored as "T:<last valid day>:<hash>" so the customer must choose a new one.
// (older resets stored "T:<hash>" and are still understood)
function isTempPass_(a) { return String(a.passHash).indexOf('T:') === 0; }
function tempParts_(a) {
  var p = String(a.passHash).split(':');
  return p.length >= 3 ? { expiry: p[1], hash: p[2] } : { expiry: '', hash: p[1] };
}
function tempExpired_(a) { var t = tempParts_(a); return !!t.expiry && t.expiry < todayStr_(); }

// Forgiving on purpose: phone keyboards add spaces and change letter case.
function passMatches_(a, password) {
  var pw = String(password || '');
  if (isTempPass_(a)) {
    if (tempExpired_(a)) return false;
    var clean = pw.replace(/\s+/g, ''), h = tempParts_(a).hash;
    return hashPassword_(a.salt, clean) === h || hashPassword_(a.salt, clean.toUpperCase()) === h;
  }
  if (hashPassword_(a.salt, pw) === String(a.passHash)) return true;
  var t = pw.trim();
  return t !== pw && hashPassword_(a.salt, t) === String(a.passHash);
}

function meLogin_(req) {
  var phone = cleanPhone_(req.phone);
  var password = String(req.password || '');
  if (phone.length < 9 || !password) throw new Error('Enter your phone number and password');
  var cache = CacheService.getScriptCache();
  var key = 'cfails_' + last9_(phone);
  var fails = Number(cache.get(key) || 0);
  if (fails >= MAX_LOGIN_FAILS) throw new Error('Too many wrong attempts. Try again in 10 minutes.');
  var a = acctByPhone_(phone);
  if (a && toBool_(a.active) && isTempPass_(a) && tempExpired_(a)) {
    throw new Error('Your temporary password has expired. Please ask the restaurant to reset it again.');
  }
  if (!a || !toBool_(a.active) || !passMatches_(a, password)) {
    cache.put(key, String(fails + 1), LOCKOUT_SECONDS);
    throw new Error('Wrong phone number or password');
  }
  cache.remove(key);
  return { token: newCustomerSession_(a), profile: acctView_(a), mustChange: isTempPass_(a) };
}

// ---- manager / admin: find a customer and reset a forgotten password
function listCustomers_(req) {
  var q = String(req.q || '').trim().toLowerCase();
  var digits = q.replace(/[^0-9]/g, '');
  var rows = readTable_('Accounts').filter(function (a) {
    if (!q) return true;
    return String(a.name).toLowerCase().indexOf(q) >= 0 || (digits.length >= 3 && String(a.phone).replace(/[^0-9]/g, '').indexOf(digits) >= 0);
  });
  rows.sort(function (a, b) { return Number(b.id) - Number(a.id); });
  return rows.slice(0, 50).map(function (a) {
    return { id: Number(a.id), name: String(a.name), phone: String(a.phone), wallet: Number(a.wallet) || 0,
             tokens: Number(a.tokens) || 0, createdAt: String(a.createdAt), tempPassword: isTempPass_(a) };
  });
}

function resetCustomerPassword_(req, user) {
  var a = findRow_('Accounts', 'id', req.id);
  if (!a) throw new Error('Customer not found');
  var temp = String(Math.floor(100000 + Math.random() * 900000));   // 6 digits: easy to type on any keyboard
  var salt = Utilities.getUuid();
  var expires = addDays_(todayStr_(), 2);
  updateRow_('Accounts', 'id', a.id, { salt: salt, passHash: 'T:' + expires + ':' + hashPassword_(salt, temp) });
  // sign the customer out everywhere and clear any lock-out
  var cache = CacheService.getScriptCache();
  readTable_('CustomerSessions').forEach(function (r) {
    if (String(r.customerId) === String(a.id)) cache.remove('c_' + String(r.token));
  });
  deleteRowsWhere_('CustomerSessions', function (r) { return String(r.customerId) === String(a.id); });
  cache.remove('cfails_' + last9_(a.phone));
  audit_(user, 'Customer password reset', String(a.name) + ' ' + String(a.phone));
  return { name: String(a.name), phone: String(a.phone), tempPassword: temp, expires: expires };
}

function meLogout_(req) {
  CacheService.getScriptCache().remove('c_' + req.token);
  try { deleteRow_('CustomerSessions', 'token', String(req.token)); } catch (e) {}
  return true;
}

function meChangePassword_(req, acct) {
  var a = findRow_('Accounts', 'id', acct.id);
  if (!passMatches_(a, req.oldPassword)) throw new Error('Your current password is wrong');
  var np = String(req.newPassword || '').trim();
  if (np.length < 6) throw new Error('Choose a password of at least 6 characters');
  var salt = Utilities.getUuid();
  updateRow_('Accounts', 'id', acct.id, { salt: salt, passHash: hashPassword_(salt, np) });
  return true;
}

function meUpdate_(req, acct) {
  var upd = {};
  var name = String(req.name || '').trim().slice(0, 60);
  if (name) { if (name.length < 2) throw new Error('Enter your name'); upd.name = name; }
  if (req.photoData) upd.photoUrl = storeImage_(req.photoData, req.photoMime, 500, 'profile');
  if (Object.keys(upd).length) updateRow_('Accounts', 'id', acct.id, upd);
  return acctView_(findRow_('Accounts', 'id', acct.id));
}

function meProfile_(req, acct) {
  var a = findRow_('Accounts', 'id', acct.id);
  var tx = readTable_('WalletTx').filter(function (t) { return String(t.customerId) === String(acct.id); })
    .reverse().slice(0, 20).map(function (t) {
      return { timestamp: String(t.timestamp), change: Number(t.change), reason: String(t.reason), balance: Number(t.balance) };
    });
  var pending = readTable_('PaymentRequests').filter(function (r) {
    return String(r.customerId) === String(acct.id) && r.status === 'Pending';
  }).map(function (r) { return { id: Number(r.id), kind: String(r.kind), amount: Number(r.amount), method: String(r.method), note: String(r.note || '') }; });
  return { profile: acctView_(a), transactions: tx, pendingPayments: pending, tokenRules: getTokenRules_() };
}

function meOrders_(req, acct) {
  var items = itemsByOrder_();
  var rows = readTable_('Orders').filter(function (o) {
    return String(o.customerId) === String(acct.id) || (String(o.customerId) === '' && last9_(o.phone) === last9_(acct.phone));
  }).map(function (o) {
    var v = orderView_(o, items, true);
    v.serveCode = o.status === 'Serving' ? String(o.serveCode || '') : '';
    return v;
  });
  rows.sort(function (a, b) { return b.id - a.id; });
  return rows.slice(0, 40);
}

// ------------------------------------------------------------------ wallet & tokens

function creditWallet_(custId, amount, reason, refId) {
  var a = findRow_('Accounts', 'id', custId);
  if (!a) throw new Error('Profile not found');
  var bal = Math.round((Number(a.wallet) || 0) + Number(amount));
  updateRow_('Accounts', 'id', custId, { wallet: bal });
  appendRow_('WalletTx', { id: nextId_('WalletTx', 'id', 1), timestamp: now_(), customerId: Number(custId),
                           change: Number(amount), reason: reason, refId: refId === undefined ? '' : refId, balance: bal });
  return bal;
}

function debitWallet_(custId, amount, reason, refId) {
  var a = findRow_('Accounts', 'id', custId);
  if (!a || (Number(a.wallet) || 0) < Number(amount)) throw new Error('Not enough money in your wallet. Top up first.');
  return creditWallet_(custId, -Number(amount), reason, refId);
}

function addTokens_(custId, n) {
  var a = findRow_('Accounts', 'id', custId);
  if (!a) return;
  updateRow_('Accounts', 'id', custId, { tokens: Math.max(0, (Number(a.tokens) || 0) + Number(n)) });
}

var DEFAULT_TOKEN_RULES = [{ min: 5000, max: 9999, tokens: 5 }, { min: 10000, max: 19999, tokens: 10 },
                           { min: 20000, max: 1000000000, tokens: 25 }];

function getTokenRules_() {
  var r = parseItems_(getSetting_('tokenRules', ''));
  if (!r.length) r = DEFAULT_TOKEN_RULES;
  return r.map(function (x) { return { min: Number(x.min), max: Number(x.max), tokens: Number(x.tokens) }; });
}

function saveTokenRules_(req, user) {
  var list = Array.isArray(req.rules) ? req.rules : [];
  if (list.length > 20) throw new Error('At most 20 rules');
  var clean = list.map(function (x) {
    var min = Number(x.min), max = Number(x.max), tokens = Math.floor(Number(x.tokens));
    if (!(min >= 0) || !(max >= min) || !(tokens >= 0)) throw new Error('Check the token ranges');
    return { min: min, max: max, tokens: tokens };
  });
  setSetting_('tokenRules', JSON.stringify(clean));
  audit_(user, 'Token rules updated', String(clean.length));
  return getTokenRules_();
}

function tokensFor_(amount) {
  var n = 0;
  getTokenRules_().forEach(function (r) { if (amount >= r.min && amount <= r.max) n = r.tokens; });
  return n;
}

function awardTokens_(o) {
  if (Number(o.tokensUsed) > 0 || Number(o.tokensEarned) > 0 || o.paymentStatus === 'Refunded') return;
  var acct = String(o.customerId) !== '' ? findRow_('Accounts', 'id', o.customerId) : acctByPhone_(o.phone);
  if (!acct) return;
  var n = tokensFor_(Number(o.total));
  if (n <= 0) return;
  addTokens_(acct.id, n);
  updateRow_('Orders', 'id', o.id, { tokensEarned: n });
  notifyCustomer_(acct.id, 'You earned ' + n + ' tokens', 'Thank you for order #' + o.id + '. Use your tokens for free meals.', o.id, 'tokens');
}

// ================================================================== payments

function readPayInput_(req, acct, amount, allowWallet) {
  var method = String(req.method || '');
  var ok = allowWallet ? ['Wallet', 'Cash', 'MTN', 'Airtel'] : ['Cash', 'MTN', 'Airtel'];
  if (ok.indexOf(method) < 0) throw new Error('Choose how you will pay');
  var pay = { method: method, provider: '', phone: '', txnId: '', proofUrl: '' };
  if (method === 'Wallet' && (Number(acct.wallet) || 0) < amount) throw new Error('Not enough money in your wallet. Top up first.');
  if (method === 'MTN' || method === 'Airtel') {
    pay.provider = method;
    pay.phone = cleanPhone_(req.payPhone);
    pay.txnId = String(req.txnId || '').trim().slice(0, 40);
    if (pay.phone.length < 9) throw new Error('Enter the phone number you paid from');
    if (req.proofData) pay.proofUrl = storeImage_(req.proofData, req.proofMime, 1000, 'proof');
    if (pay.txnId.length < 6 && !pay.proofUrl) throw new Error('Enter the transaction ID or attach a screenshot');
  }
  return pay;
}

function settlePayment_(kind, refId, acct, amount, pay, label) {
  if (pay.method === 'Wallet') {
    debitWallet_(acct.id, amount, label, refId);
    fulfill_(kind, refId, amount, acct.id);
    return { paid: true };
  }
  var id = nextId_('PaymentRequests', 'id', 1);
  appendRow_('PaymentRequests', { id: id, createdAt: now_(), kind: kind, refId: refId, customerId: acct.id,
    customerName: acct.name, amount: amount, method: pay.method, provider: pay.provider, phone: pay.phone,
    txnId: pay.txnId, proofUrl: pay.proofUrl, status: 'Pending', handledBy: '', handledAt: '', note: label });
  notify_(['manager', 'admin'], '', 'Confirm payment: ' + label,
          acct.name + ' - UGX ' + amount + ' - ' + pay.method + (pay.method === 'Cash' ? ' (cash to the manager)' : ''), '', 'payment');
  return { paid: false, requestId: id };
}

function fulfill_(kind, refId, amount, customerId) {
  if (kind === 'wallet') creditWallet_(customerId, amount, 'Wallet top-up', '');
  else if (kind === 'event') issueTicket_(refId);
  else if (kind === 'subscription') activateSubscription_(refId);
}

function requestView_(r) {
  return { id: Number(r.id), createdAt: String(r.createdAt), kind: String(r.kind), customerName: String(r.customerName),
           amount: Number(r.amount), method: String(r.method), provider: String(r.provider || ''),
           phone: String(r.phone || ''), txnId: String(r.txnId || ''), proofUrl: String(r.proofUrl || ''),
           status: String(r.status), note: String(r.note || '') };
}

function meTopUp_(req, acct) {
  var amount = Math.floor(Number(req.amount));
  if (!(amount >= 1000 && amount <= 5000000)) throw new Error('Top-up must be between UGX 1,000 and UGX 5,000,000');
  var pay = readPayInput_(req, acct, amount, false);
  return settlePayment_('wallet', '', acct, amount, pay, 'Wallet top-up UGX ' + amount);
}

function confirmPaymentRequest_(req, user) {
  var r = findRow_('PaymentRequests', 'id', req.id);
  if (!r || r.status !== 'Pending') throw new Error('This request was already handled');
  fulfill_(String(r.kind), r.refId, Number(r.amount), r.customerId);
  updateRow_('PaymentRequests', 'id', r.id, { status: 'Confirmed', handledBy: user.name, handledAt: now_() });
  audit_(user, 'Payment confirmed', r.kind + ' #' + r.id + ' UGX ' + r.amount);
  notifyCustomer_(r.customerId, 'Payment confirmed', String(r.note || 'Your payment was received.'), '', 'payment');
  return true;
}

function rejectPaymentRequest_(req, user) {
  var r = findRow_('PaymentRequests', 'id', req.id);
  if (!r || r.status !== 'Pending') throw new Error('This request was already handled');
  var reason = String(req.reason || '').trim().slice(0, 150) || 'Payment could not be verified';
  if (r.kind === 'event') updateRow_('EventTickets', 'id', r.refId, { status: 'Rejected' });
  if (r.kind === 'subscription') updateRow_('Subscriptions', 'id', r.refId, { status: 'Rejected' });
  updateRow_('PaymentRequests', 'id', r.id, { status: 'Rejected', handledBy: user.name, handledAt: now_(), note: reason });
  audit_(user, 'Payment rejected', r.kind + ' #' + r.id + ': ' + reason);
  notifyCustomer_(r.customerId, 'Payment not confirmed', reason, '', 'alert');
  return true;
}

// ---- mobile money proof for an order (customer, or waiter / manager)
function applyProof_(o, req, who) {
  var provider = (o.paymentMethod === 'MTN' || o.paymentMethod === 'Airtel') ? String(o.paymentMethod) : '';
  if (!provider) throw new Error('This order is not paid by mobile money');
  if (o.paymentStatus === 'Paid') throw new Error('This order is already paid');
  if (['Rejected', 'Cancelled', 'Failed'].indexOf(o.status) >= 0) throw new Error('This order is closed');
  var txn = String(req.txnId || '').trim().slice(0, 40);
  var pay = cleanPhone_(req.payPhone);
  if (pay.length < 9) throw new Error('Enter the phone number the money was sent from');
  var proofUrl = req.proofData ? storeImage_(req.proofData, req.proofMime, 1000, 'proof') : '';
  if (txn.length < 6 && !proofUrl) throw new Error('Enter the transaction ID or attach a screenshot');
  setStatus_(o, { paymentStatus: 'Proof submitted', payProvider: provider, payPhone: pay, txnId: txn,
                  proofUrl: proofUrl, proofAt: now_() });
  notify_(['manager', 'admin'], '', 'Check ' + provider + ' payment - order #' + o.id,
          'UGX ' + o.total + ' from ' + pay + (txn ? ' - ID ' + txn : ''), o.id, 'payment');
  audit_(who, 'Payment proof sent', '#' + o.id + ' ' + provider);
}

function submitPaymentProof_(req) {
  applyProof_(findCustomerOrder_(req), req, { name: 'Customer', role: 'customer' });
  return true;
}

function staffPaymentProof_(req, user) {
  var o = getOrder_(req.id);
  if (user.role === 'waiter' && String(o.createdById) !== String(user.id) && String(o.assignedToId) !== String(user.id)) {
    throw new Error('This order is not yours.');
  }
  applyProof_(o, req, user);
  return true;
}

function confirmPayment_(req, user) {
  var o = getOrder_(req.id);
  if (o.paymentStatus !== 'Proof submitted') throw new Error('There is no payment proof to approve');
  setStatus_(o, { paymentStatus: 'Paid' });
  audit_(user, 'Mobile money approved', '#' + o.id + ' UGX ' + o.total + ' ' + o.payProvider);
  if (String(o.createdById) !== '') {
    notify_([], o.createdById, 'Payment received - order #' + o.id,
            'The manager approved the mobile money payment. It is not counted in the cash you must hand in.', o.id, 'payment');
  }
  if (String(o.customerId) !== '') notifyCustomer_(o.customerId, 'Payment received', 'Order #' + o.id + ' is paid. Thank you!', o.id, 'payment');
  return true;
}

function rejectPayment_(req, user) {
  var o = getOrder_(req.id);
  if (o.paymentStatus !== 'Proof submitted') throw new Error('There is no payment proof to reject');
  var reason = String(req.reason || '').trim().slice(0, 150) || 'Details did not match';
  setStatus_(o, { paymentStatus: 'Unpaid', rejectReason: o.status === 'Rejected' ? o.rejectReason : '' });
  audit_(user, 'Mobile money rejected', '#' + o.id + ': ' + reason);
  if (String(o.createdById) !== '') notify_([], o.createdById, 'Payment not confirmed - order #' + o.id, reason, o.id, 'alert');
  if (String(o.customerId) !== '') notifyCustomer_(o.customerId, 'Payment not confirmed', reason, o.id, 'alert');
  return true;
}

// ---- cash: the waiter collects, then hands the money + order code to the manager
function orderForCode_(code) {
  code = normCode_(code);
  if (code.length < 4 || code.length > 10) throw new Error('Invalid code');
  var found = null;
  readTable_('Orders').forEach(function (r) { if (String(r.code) === code) found = r; });
  if (!found) throw new Error('Invalid code');
  return found;
}

function collectCash_(req, user) {
  var o;
  if (!req.code && req.id) {
    // a walk-in order the waiter took herself: no customer code exists
    o = getOrder_(req.id);
    if (o.source !== 'staff' || String(o.createdById) !== String(user.id)) throw new Error('Enter the customer\'s order code');
  } else {
    o = orderForCode_(req.code);
  }
  if (o.paymentMethod !== 'Cash') throw new Error('This order is not paid in cash');
  if (['Rejected', 'Cancelled', 'Failed'].indexOf(o.status) >= 0) throw new Error('This order is closed');
  if (o.paymentStatus === 'With waiter') throw new Error('Cash for this order was already collected');
  if (o.paymentStatus !== 'Unpaid') throw new Error('This order is already paid');
  if (String(o.assignedToId) !== String(user.id) && String(o.createdById) !== String(user.id)) {
    throw new Error('This order is not yours.');
  }
  setStatus_(o, { paymentStatus: 'With waiter', cashById: user.id, cashByName: user.name, cashAt: now_() });
  audit_(user, 'Cash collected', '#' + o.id + ' UGX ' + o.total);
  notify_(['manager', 'admin'], '', 'Cash with ' + user.name, 'Order #' + o.id + ' - UGX ' + o.total + '. Waiting for hand-in.', o.id, 'payment');
  return { id: Number(o.id), total: Number(o.total) };
}

function receiveCash_(req, user) {
  var o = orderForCode_(req.code);
  if (o.paymentStatus !== 'With waiter') throw new Error('No cash is waiting to be handed in for this order');
  setStatus_(o, { paymentStatus: 'Paid', cashHandedAt: now_(), cashReceivedBy: user.name });
  audit_(user, 'Cash received from waiter', '#' + o.id + ' UGX ' + o.total + ' from ' + o.cashByName);
  notify_([], o.cashById, 'Cash received - order #' + o.id, 'UGX ' + o.total + ' confirmed by ' + user.name + '.', o.id, 'payment');
  return { id: Number(o.id), total: Number(o.total), waiter: String(o.cashByName) };
}

function paymentsDesk_() {
  var items = itemsByOrder_();
  var orders = readTable_('Orders');
  var cash = orders.filter(function (o) { return o.paymentStatus === 'With waiter'; })
    .map(function (o) { return orderView_(o, items, false); });
  var proofs = orders.filter(function (o) { return o.paymentStatus === 'Proof submitted'; })
    .map(function (o) { return orderView_(o, items, false); });
  var requests = readTable_('PaymentRequests').filter(function (r) { return r.status === 'Pending'; }).map(requestView_);
  var byWaiter = {};
  cash.forEach(function (o) {
    var k = o.cashByName || '?';
    byWaiter[k] = byWaiter[k] || { waiter: k, total: 0, orders: 0 };
    byWaiter[k].total += o.total; byWaiter[k].orders++;
  });
  return { cash: cash, proofs: proofs, requests: requests,
           byWaiter: Object.keys(byWaiter).map(function (k) { return byWaiter[k]; }) };
}

// ---- waiter desk
function waiterDesk_(req, user) {
  var items = itemsByOrder_();
  var since = daysAgoStr_(1);
  var mine = readTable_('Orders').filter(function (o) {
    var isMine = String(o.assignedToId) === String(user.id) || String(o.createdById) === String(user.id) ||
                 String(o.cashById) === String(user.id);
    if (!isMine) return false;
    if (o.paymentStatus === 'With waiter' && String(o.cashById) === String(user.id)) return true;
    if (OPEN_STATUSES.indexOf(o.status) >= 0 && o.status !== 'Pending') return true;
    return o.status === 'Completed' && String(o.completedAt).slice(0, 10) >= since;
  });
  var outstanding = 0, count = 0;
  mine.forEach(function (o) {
    if (o.paymentStatus === 'With waiter' && String(o.cashById) === String(user.id)) { outstanding += Number(o.total); count++; }
  });
  var views = mine.map(function (o) { return orderView_(o, items, false); });
  views.sort(function (a, b) { return b.id - a.id; });
  return { orders: views.slice(0, 80), outstanding: outstanding, outstandingCount: count };
}

// ---- check any code (order / event ticket / subscription meal)
function ticketView_(t) {
  var ev = findRow_('Events', 'id', t.eventId);
  return { id: Number(t.id), eventId: Number(t.eventId), eventTitle: String(t.eventTitle), packageName: String(t.packageName),
           amount: Number(t.amount), status: String(t.status), method: String(t.method),
           code: t.status === 'Paid' ? String(t.code) : '', customerName: String(t.customerName),
           eventDate: ev ? String(ev.date) : '', eventTime: ev ? String(ev.time || '') : '',
           usedAt: String(t.usedAt || ''), usedBy: String(t.usedBy || '') };
}

function checkCode_(req) {
  var code = normCode_(req.code);
  if (code.length < 4 || code.length > 10) throw new Error('Invalid code');
  var o = null;
  readTable_('Orders').forEach(function (r) { if (String(r.code) === code) o = r; });
  if (o) {
    var v = orderView_(o, itemsByOrder_(), false);
    return { type: 'order', order: v, completed: o.status === 'Completed',
             pending: OPEN_STATUSES.indexOf(o.status) >= 0 };
  }
  var t = null;
  readTable_('EventTickets').forEach(function (r) { if (String(r.code) === code && r.status === 'Paid') t = r; });
  if (t) return { type: 'event', ticket: ticketView_(t) };
  var c = null;
  readTable_('SubClaims').forEach(function (r) { if (String(r.code) === code) c = r; });
  if (c) return { type: 'subscription', claim: claimView_(c) };
  throw new Error('Invalid code');
}

// ================================================================== attendance & auto-assign

function getAttendance_() {
  var today = todayStr_();
  var present = {};
  readTable_('Attendance').forEach(function (a) { if (String(a.date) === today) present[String(a.userId)] = true; });
  var staff = readTable_('Users').filter(function (u) {
    return toBool_(u.active) && ['kitchen', 'waiter', 'delivery'].indexOf(String(u.role)) >= 0;
  }).map(function (u) {
    return { id: Number(u.id), name: String(u.name), role: String(u.role), present: !!present[String(u.id)] };
  });
  return { date: today, isSet: String(getSetting_('attendanceDate', '')) === today,
           autoAssign: String(getSetting_('autoAssign', 'true')) !== 'false', staff: staff };
}

function setAttendance_(req, user) {
  var today = todayStr_();
  var ids = (Array.isArray(req.userIds) ? req.userIds : []).map(String);
  deleteRowsWhere_('Attendance', function (a) { return String(a.date) === today; });
  readTable_('Users').forEach(function (u) {
    if (toBool_(u.active) && ids.indexOf(String(u.id)) >= 0) {
      appendRow_('Attendance', { date: today, userId: Number(u.id), name: String(u.name), role: String(u.role) });
    }
  });
  setSetting_('attendanceDate', today);
  if (req.autoAssign !== undefined) setSetting_('autoAssign', req.autoAssign ? 'true' : 'false');
  audit_(user, 'Attendance set', today + ': ' + ids.length + ' workers');
  return { assigned: autoAssign_() };
}

function assignNow_() { return { assigned: autoAssign_() }; }

// Gives each waiting (Ready) order to the free worker with the fewest completed tasks today.
function autoAssign_() {
  try {
    if (String(getSetting_('autoAssign', 'true')) === 'false') return 0;
    var orders = readTable_('Orders');
    var waiting = orders.filter(function (o) { return o.status === 'Ready' && String(o.assignedToId) === ''; })
      .sort(function (a, b) { return Number(a.id) - Number(b.id); });
    if (!waiting.length) return 0;
    var today = todayStr_();
    var users = readTable_('Users').filter(function (u) { return toBool_(u.active); });
    var present = {};
    if (String(getSetting_('attendanceDate', '')) === today) {
      readTable_('Attendance').forEach(function (a) { if (String(a.date) === today) present[String(a.userId)] = true; });
    }
    var busy = {}, doneCount = {}, lastDone = {};
    orders.forEach(function (o) {
      var uid = String(o.assignedToId);
      if (!uid) return;
      if (o.status === 'Assigned' || o.status === 'Serving') busy[uid] = true;
      if (o.status === 'Completed' && String(o.completedAt).slice(0, 10) === today) {
        doneCount[uid] = (doneCount[uid] || 0) + 1;
        if (String(o.completedAt) > (lastDone[uid] || '')) lastDone[uid] = String(o.completedAt);
      }
    });
    var assigned = 0;
    waiting.forEach(function (o) {
      var role = o.mode === 'Delivery' ? 'delivery' : 'waiter';
      var pick = null;
      if (o.source === 'staff' && o.mode !== 'Delivery' && String(o.createdById) !== '') {
        // an order a waiter took stays with that waiter
        users.forEach(function (u) { if (String(u.id) === String(o.createdById) && u.role === 'waiter') pick = u; });
      }
      if (!pick) {
        var cands = users.filter(function (u) { return u.role === role && present[String(u.id)] && !busy[String(u.id)]; });
        cands.sort(function (a, b) {
          var ca = doneCount[String(a.id)] || 0, cb = doneCount[String(b.id)] || 0;
          if (ca !== cb) return ca - cb;
          var la = lastDone[String(a.id)] || '', lb = lastDone[String(b.id)] || '';
          if (la !== lb) return la < lb ? -1 : 1;
          return Number(a.id) - Number(b.id);
        });
        pick = cands[0] || null;
      }
      if (pick) {
        assignOrder_(o, pick, '', { name: 'Auto-assign', role: 'system' });
        busy[String(pick.id)] = true;
        assigned++;
      }
    });
    return assigned;
  } catch (e) { return 0; }
}

// ================================================================== staff activity

function workerStats_(req) {
  var days = Math.max(1, Math.min(90, Math.floor(Number(req.days || 7))));
  var from = daysAgoStr_(days - 1);
  var users = readTable_('Users').filter(function (u) {
    return toBool_(u.active) && ['kitchen', 'waiter', 'delivery'].indexOf(String(u.role)) >= 0;
  });
  var stat = {}, byName = {};
  users.forEach(function (u) {
    stat[String(u.id)] = { id: Number(u.id), name: String(u.name), role: String(u.role), completed: 0, cooked: 0,
                           recorded: 0, cashCollected: 0, cashOutstanding: 0, daysPresent: 0, lastActive: '', tasks: 0 };
    byName[String(u.name)] = String(u.id);
  });
  var daily = {};
  for (var i = days - 1; i >= 0; i--) { var k = daysAgoStr_(i); daily[k] = { date: k, waiter: 0, kitchen: 0, delivery: 0 }; }
  function bump(date, role) { if (daily[date]) daily[date][role]++; }
  readTable_('Orders').forEach(function (o) {
    var created = String(o.createdAt).slice(0, 10), done = String(o.completedAt).slice(0, 10);
    var ready = String(o.readyAt).slice(0, 10);
    if (o.status === 'Completed' && done >= from && String(o.assignedToId) !== '') {
      var s = stat[String(o.assignedToId)];
      if (s) { s.completed++; s.tasks++; bump(done, s.role); if (String(o.completedAt) > s.lastActive) s.lastActive = String(o.completedAt); }
    }
    if (ready >= from && o.cookedBy) {
      var cid = byName[String(o.cookedBy)], cs = cid ? stat[cid] : null;
      if (cs && cs.role === 'kitchen') { cs.cooked++; cs.tasks++; bump(ready, 'kitchen'); if (String(o.readyAt) > cs.lastActive) cs.lastActive = String(o.readyAt); }
    }
    if (o.source === 'staff' && String(o.createdById) !== '' && created >= from) {
      var rs = stat[String(o.createdById)];
      if (rs) { rs.recorded++; rs.tasks++; }
    }
    if (String(o.cashById) !== '') {
      var ws = stat[String(o.cashById)];
      if (ws) {
        if (String(o.cashAt).slice(0, 10) >= from) ws.cashCollected += Number(o.total);
        if (o.paymentStatus === 'With waiter') ws.cashOutstanding += Number(o.total);
      }
    }
  });
  readTable_('Attendance').forEach(function (a) {
    if (String(a.date) >= from && stat[String(a.userId)]) stat[String(a.userId)].daysPresent++;
  });
  return { days: days,
           workers: Object.keys(stat).map(function (k) { return stat[k]; }),
           daily: Object.keys(daily).sort().map(function (k) { return daily[k]; }) };
}

// ================================================================== kitchen requests & units

var DEFAULT_UNITS = ['number', 'kg', 'gram', 'litre', 'bottle', 'packet', 'bunch', 'piece', 'tin', 'crate', 'sack', 'carton', 'box', 'bundle', 'tray'];

function customUnits_() { return parseItems_(getSetting_('units', '[]')).map(String); }

function listUnits_() {
  var list = DEFAULT_UNITS.slice();
  customUnits_().forEach(function (u) { if (list.map(function (x) { return x.toLowerCase(); }).indexOf(u.toLowerCase()) < 0) list.push(u); });
  return list;
}

function rememberUnit_(unit) {
  unit = String(unit || '').trim().slice(0, 30);
  if (!unit) return;
  var known = listUnits_().map(function (x) { return x.toLowerCase(); });
  if (known.indexOf(unit.toLowerCase()) >= 0) return;
  var custom = customUnits_(); custom.push(unit);
  setSetting_('units', JSON.stringify(custom));
}

function addUnit_(req, user) {
  var u = String(req.name || '').trim().slice(0, 30);
  if (!u) throw new Error('Type the unit name');
  rememberUnit_(u);
  audit_(user, 'Unit added', u);
  return listUnits_();
}

function createStockRequest_(req, user) {
  var list = Array.isArray(req.items) ? req.items : [];
  if (!list.length) throw new Error('Add at least one item');
  if (list.length > 30) throw new Error('Too many items');
  var note = String(req.note || '').trim().slice(0, 150);
  var names = [];
  list.forEach(function (x) {
    var name = String(x.name || '').trim().slice(0, 60);
    var qty = Number(x.qty);
    if (x.itemId) { var it = findRow_('Inventory', 'id', x.itemId); if (it) name = String(it.name); }
    if (!name) throw new Error('Choose or type the item name');
    if (!(qty > 0)) throw new Error('Enter how many ' + name + ' you need');
    appendRow_('StockRequests', { id: nextId_('StockRequests', 'id', 1), createdAt: now_(), by: user.name, byId: user.id,
      itemId: x.itemId || '', itemName: name, qty: qty, unit: String(x.unit || '').trim().slice(0, 30),
      note: note, status: 'Open', handledBy: '', handledAt: '' });
    names.push(fmt_(qty) + ' ' + (String(x.unit || '').trim()) + ' ' + name);
  });
  notify_(['manager', 'admin'], '', 'Kitchen request from ' + user.name, names.slice(0, 4).join(', ') + (names.length > 4 ? '...' : ''), '', 'stock');
  audit_(user, 'Stock request', names.join(', '));
  return { count: list.length };
}

function reqView_(r) {
  return { id: Number(r.id), createdAt: String(r.createdAt), by: String(r.by), itemName: String(r.itemName),
           qty: Number(r.qty), unit: String(r.unit || ''), note: String(r.note || ''), status: String(r.status),
           handledBy: String(r.handledBy || '') };
}
function myStockRequests_(req, user) {
  return readTable_('StockRequests').filter(function (r) { return String(r.byId) === String(user.id); })
    .reverse().slice(0, 40).map(reqView_);
}
function listStockRequests_(req) {
  var rows = readTable_('StockRequests');
  if (req.status) rows = rows.filter(function (r) { return r.status === req.status; });
  return rows.reverse().slice(0, 100).map(reqView_);
}
function resolveStockRequest_(req, user) {
  var r = findRow_('StockRequests', 'id', req.id);
  if (!r) throw new Error('Request not found');
  var status = String(req.status || '');
  if (['Bought', 'Declined', 'Approved'].indexOf(status) < 0) throw new Error('Choose a result');
  updateRow_('StockRequests', 'id', r.id, { status: status, handledBy: user.name, handledAt: now_() });
  notify_([], r.byId, 'Request ' + status.toLowerCase(), fmt_(r.qty) + ' ' + r.unit + ' ' + r.itemName, '', 'stock');
  audit_(user, 'Stock request ' + status, r.itemName);
  return true;
}

// ================================================================== events

function eventView_(e, sold) {
  return { id: Number(e.id), title: String(e.title), date: String(e.date), time: String(e.time || ''),
           imageUrl: String(e.imageUrl || ''), details: String(e.details || ''),
           packages: parseItems_(e.packagesJson).map(function (p) {
             return { name: String(p.name), fee: Number(p.fee) || 0, details: String(p.details || '') };
           }), active: toBool_(e.active), sold: sold || 0 };
}

function listEvents_() {
  var today = todayStr_();
  return readTable_('Events').filter(function (e) { return toBool_(e.active) && String(e.date) >= today; })
    .sort(function (a, b) { return String(a.date + a.time) < String(b.date + b.time) ? -1 : 1; })
    .map(function (e) { return eventView_(e, 0); });
}

function listEventsAdmin_() {
  var sold = {};
  readTable_('EventTickets').forEach(function (t) { if (t.status === 'Paid') sold[String(t.eventId)] = (sold[String(t.eventId)] || 0) + 1; });
  return readTable_('Events').reverse().map(function (e) { return eventView_(e, sold[String(e.id)] || 0); });
}

function saveEvent_(req, user) {
  var it = req.item || {};
  var title = String(it.title || '').trim().slice(0, 80);
  var date = String(it.date || '').trim();
  if (!title) throw new Error('Give the event a title');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new Error('Enter the date as YYYY-MM-DD');
  var pkgs = (Array.isArray(it.packages) ? it.packages : []).slice(0, 6).map(function (p) {
    var fee = Number(p.fee);
    if (!String(p.name || '').trim()) throw new Error('Every package needs a name');
    if (!(fee >= 0)) throw new Error('Check the package fee');
    return { name: String(p.name).trim().slice(0, 40), fee: fee, details: String(p.details || '').trim().slice(0, 200) };
  });
  if (!pkgs.length) throw new Error('Add at least one package (for example Regular - fee)');
  var row = { title: title, date: date, time: String(it.time || '').trim().slice(0, 20),
              imageUrl: String(it.imageUrl || ''), details: String(it.details || '').trim().slice(0, 800),
              packagesJson: JSON.stringify(pkgs), active: it.active === false ? false : true };
  if (it.id) {
    if (!findRow_('Events', 'id', it.id)) throw new Error('Event not found');
    updateRow_('Events', 'id', it.id, row);
    audit_(user, 'Event edited', title);
    return { id: Number(it.id) };
  }
  row.id = nextId_('Events', 'id', 1); row.createdAt = now_();
  appendRow_('Events', row);
  audit_(user, 'Event added', title + ' ' + date);
  return { id: row.id };
}

function deleteEvent_(req, user) {
  var e = findRow_('Events', 'id', req.id);
  if (!e) throw new Error('Event not found');
  deleteRow_('Events', 'id', req.id);
  audit_(user, 'Event deleted', String(e.title));
  return true;
}

function issueTicket_(id) {
  var t = findRow_('EventTickets', 'id', id);
  if (!t || t.status === 'Paid') return;
  var code = newUniqueCode_('EventTickets', 8);
  updateRow_('EventTickets', 'id', id, { status: 'Paid', code: code, paidAt: now_() });
  notifyCustomer_(t.customerId, 'Ticket confirmed', String(t.eventTitle) + ' - your entry code is ' + code, '', 'event');
}

function meBuyTicket_(req, acct) {
  var ev = findRow_('Events', 'id', req.eventId);
  if (!ev || !toBool_(ev.active) || String(ev.date) < todayStr_()) throw new Error('This event is not available');
  var pkg = null;
  parseItems_(ev.packagesJson).forEach(function (p) { if (String(p.name) === String(req.packageName)) pkg = p; });
  if (!pkg) throw new Error('Choose a package');
  var fee = Number(pkg.fee) || 0;
  var pay = fee > 0 ? readPayInput_(req, acct, fee, true) : { method: 'Free' };
  var id = nextId_('EventTickets', 'id', 1);
  appendRow_('EventTickets', { id: id, eventId: Number(ev.id), eventTitle: String(ev.title), packageName: String(pkg.name),
    amount: fee, customerId: acct.id, customerName: acct.name, phone: acct.phone, method: pay.method,
    status: 'Pending', code: '', paidAt: '', usedAt: '', usedBy: '' });
  if (fee > 0) settlePayment_('event', id, acct, fee, pay, 'Ticket: ' + ev.title + ' (' + pkg.name + ')');
  else issueTicket_(id);
  return ticketView_(findRow_('EventTickets', 'id', id));
}

function meTickets_(req, acct) {
  return readTable_('EventTickets').filter(function (t) { return String(t.customerId) === String(acct.id); })
    .reverse().map(ticketView_);
}

function admitEventCode_(req, user) {
  var code = normCode_(req.code);
  var t = null;
  readTable_('EventTickets').forEach(function (r) { if (String(r.code) === code && code) t = r; });
  if (!t) throw new Error('Invalid code');
  if (t.status !== 'Paid') throw new Error('This ticket is not paid');
  if (String(t.usedAt || '') !== '') throw new Error('Already used at ' + t.usedAt + ' by ' + t.usedBy);
  updateRow_('EventTickets', 'id', t.id, { usedAt: now_(), usedBy: user.name });
  audit_(user, 'Event entry', t.eventTitle + ' - ' + t.customerName);
  return ticketView_(findRow_('EventTickets', 'id', t.id));
}

// ================================================================== subscriptions

function pkgView_(p) {
  var dishes = {};
  readTable_('Menu').forEach(function (d) { dishes[String(d.id)] = d; });
  return { id: Number(p.id), name: String(p.name), description: String(p.description || ''), days: Number(p.days),
           price: Number(p.price), imageUrl: String(p.imageUrl || ''), active: toBool_(p.active),
           items: parseItems_(p.itemsJson).map(function (x) {
             return { dishId: Number(x.dishId), name: dishes[String(x.dishId)] ? String(dishes[String(x.dishId)].name) : '(removed)', qty: Number(x.qty) };
           }) };
}

function listSubPackages_() {
  return readTable_('SubPackages').filter(function (p) { return toBool_(p.active); }).map(pkgView_);
}

function listSubscriptionsAdmin_() {
  var pk = readTable_('SubPackages').map(pkgView_);
  var subs = readTable_('Subscriptions').reverse().slice(0, 80).map(subView_);
  return { packages: pk, subscriptions: subs };
}

function saveSubPackage_(req, user) {
  var it = req.item || {};
  var name = String(it.name || '').trim().slice(0, 60);
  var days = Math.floor(Number(it.days)), price = Number(it.price);
  if (!name) throw new Error('Give the package a name');
  if (!(days >= 1 && days <= 365)) throw new Error('The period must be 1 to 365 days');
  if (!(price >= 0)) throw new Error('Enter the package price');
  var items = (Array.isArray(it.items) ? it.items : []).slice(0, 20).map(function (x) {
    var qty = Math.floor(Number(x.qty));
    if (!findRow_('Menu', 'id', x.dishId)) throw new Error('A dish in the package no longer exists');
    if (!(qty >= 1 && qty <= 500)) throw new Error('Check the number of meals');
    return { dishId: Number(x.dishId), qty: qty };
  });
  if (!items.length) throw new Error('Select the food items in this package');
  var row = { name: name, description: String(it.description || '').trim().slice(0, 300), days: days, price: price,
              itemsJson: JSON.stringify(items), active: it.active === false ? false : true, imageUrl: String(it.imageUrl || '') };
  if (it.id) {
    if (!findRow_('SubPackages', 'id', it.id)) throw new Error('Package not found');
    updateRow_('SubPackages', 'id', it.id, row);
    audit_(user, 'Package edited', name);
    return { id: Number(it.id) };
  }
  row.id = nextId_('SubPackages', 'id', 1);
  appendRow_('SubPackages', row);
  audit_(user, 'Package added', name);
  return { id: row.id };
}

function deleteSubPackage_(req, user) {
  var p = findRow_('SubPackages', 'id', req.id);
  if (!p) throw new Error('Package not found');
  updateRow_('SubPackages', 'id', req.id, { active: false });
  audit_(user, 'Package switched off', String(p.name));
  return true;
}

function subView_(s) {
  var dishes = {};
  readTable_('Menu').forEach(function (d) { dishes[String(d.id)] = String(d.name); });
  var bal = parseObj_(s.balancesJson);
  var end = String(s.endDate || ''), today = todayStr_();
  var left = 0;
  if (end) { left = Math.round((Date.parse(end) - Date.parse(today)) / 86400000); if (left < 0) left = 0; }
  return { id: Number(s.id), packageName: String(s.packageName), customerName: String(s.customerName || ''),
           startDate: String(s.startDate || ''), endDate: end,
           status: (s.status === 'Active' && end && end < today) ? 'Expired' : String(s.status),
           pausedDays: Number(s.pausedDays) || 0, daysLeft: left,
           balances: Object.keys(bal).map(function (k) {
             return { dishId: Number(k), name: dishes[k] || '(removed)', qty: Number(bal[k]) };
           }) };
}

function activateSubscription_(id) {
  var s = findRow_('Subscriptions', 'id', id);
  if (!s || s.status === 'Active') return;
  var pkg = findRow_('SubPackages', 'id', s.packageId);
  var days = pkg ? Number(pkg.days) : 30;
  var today = todayStr_();
  updateRow_('Subscriptions', 'id', id, { status: 'Active', startDate: today, endDate: addDays_(today, days - 1), paidAt: now_() });
  notifyCustomer_(s.customerId, 'Subscription active', String(s.packageName) + ' is ready. Choose your meals in the app.', '', 'subscription');
}

function meBuyPackage_(req, acct) {
  var pkg = findRow_('SubPackages', 'id', req.packageId);
  if (!pkg || !toBool_(pkg.active)) throw new Error('This package is not available');
  var price = Number(pkg.price);
  var pay = price > 0 ? readPayInput_(req, acct, price, true) : { method: 'Free' };
  var bal = {};
  parseItems_(pkg.itemsJson).forEach(function (x) { bal[String(x.dishId)] = Number(x.qty); });
  var id = nextId_('Subscriptions', 'id', 1);
  appendRow_('Subscriptions', { id: id, customerId: acct.id, customerName: acct.name, packageId: Number(pkg.id),
    packageName: String(pkg.name), startDate: '', endDate: '', balancesJson: JSON.stringify(bal),
    status: 'Pending', paidAt: '', pausedDays: 0 });
  if (price > 0) settlePayment_('subscription', id, acct, price, pay, 'Subscription: ' + pkg.name);
  else activateSubscription_(id);
  return subView_(findRow_('Subscriptions', 'id', id));
}

function claimView_(c) {
  return { id: Number(c.id), subId: Number(c.subId), dishId: Number(c.dishId), dishName: String(c.dishName),
           code: String(c.code), date: String(c.date), status: String(c.status),
           customerName: (function () { var a = findRow_('Accounts', 'id', c.customerId); return a ? String(a.name) : ''; })() };
}

function refundStaleClaims_(custId) {
  var today = todayStr_();
  readTable_('SubClaims').forEach(function (c) {
    if (String(c.customerId) !== String(custId) || c.status !== 'Open' || String(c.date) >= today) return;
    var s = findRow_('Subscriptions', 'id', c.subId);
    if (s) {
      var bal = parseObj_(s.balancesJson);
      bal[String(c.dishId)] = (Number(bal[String(c.dishId)]) || 0) + 1;
      updateRow_('Subscriptions', 'id', s.id, { balancesJson: JSON.stringify(bal) });
    }
    updateRow_('SubClaims', 'id', c.id, { status: 'Expired' });
  });
}

function meSubscriptions_(req, acct) {
  refundStaleClaims_(acct.id);
  var today = todayStr_();
  var subs = readTable_('Subscriptions').filter(function (s) { return String(s.customerId) === String(acct.id); });
  subs.forEach(function (s) {
    if (s.status === 'Active' && String(s.endDate) < today) updateRow_('Subscriptions', 'id', s.id, { status: 'Expired' });
  });
  var claims = readTable_('SubClaims').filter(function (c) {
    return String(c.customerId) === String(acct.id) && c.status === 'Open';
  }).map(claimView_);
  return { subscriptions: readTable_('Subscriptions').filter(function (s) { return String(s.customerId) === String(acct.id); })
                            .reverse().map(subView_), openClaims: claims };
}

function ownSub_(id, acct) {
  var s = findRow_('Subscriptions', 'id', id);
  if (!s || String(s.customerId) !== String(acct.id)) throw new Error('Subscription not found');
  return s;
}

// Omitted days: tell us you will skip some days and the end date moves forward.
function meSkipDays_(req, acct) {
  var s = ownSub_(req.subId, acct);
  if (s.status !== 'Active') throw new Error('Only an active subscription can be paused');
  var n = Math.floor(Number(req.days));
  if (!(n >= 1 && n <= 7)) throw new Error('Skip between 1 and 7 days at a time');
  var total = (Number(s.pausedDays) || 0) + n;
  if (total > 14) throw new Error('You can pause at most 14 days in one subscription');
  updateRow_('Subscriptions', 'id', s.id, { endDate: addDays_(String(s.endDate), n), pausedDays: total });
  audit_({ name: acct.name, role: 'customer' }, 'Subscription paused', '#' + s.id + ' +' + n + ' days');
  return subView_(findRow_('Subscriptions', 'id', s.id));
}

function meClaimMeal_(req, acct) {
  refundStaleClaims_(acct.id);
  var s = ownSub_(req.subId, acct);
  var today = todayStr_();
  if (s.status !== 'Active' || String(s.endDate) < today || String(s.startDate) > today) throw new Error('This subscription is not active today');
  var dish = findRow_('Menu', 'id', req.dishId);
  if (!dish) throw new Error('Dish not found');
  var bal = parseObj_(s.balancesJson);
  if (!(Number(bal[String(dish.id)]) > 0)) throw new Error('No ' + dish.name + ' left in this package');
  var dup = readTable_('SubClaims').filter(function (c) {
    return String(c.subId) === String(s.id) && String(c.dishId) === String(dish.id) && String(c.date) === today &&
           (c.status === 'Open' || c.status === 'Redeemed');
  }).length;
  if (dup) throw new Error('You already chose ' + dish.name + ' today');
  bal[String(dish.id)] = Number(bal[String(dish.id)]) - 1;
  updateRow_('Subscriptions', 'id', s.id, { balancesJson: JSON.stringify(bal) });
  var c = { id: nextId_('SubClaims', 'id', 1), subId: Number(s.id), customerId: acct.id, dishId: Number(dish.id),
            dishName: String(dish.name), code: newUniqueCode_('SubClaims', 6), date: today, status: 'Open',
            redeemedBy: '', redeemedAt: '' };
  appendRow_('SubClaims', c);
  return claimView_(c);
}

// A waiter enters the customer's meal code: the meal is marked as a paid subscription meal and sent to the kitchen.
function redeemSubscriptionCode_(req, user) {
  var code = normCode_(req.code), c = null;
  readTable_('SubClaims').forEach(function (r) { if (String(r.code) === code && code) c = r; });
  if (!c) throw new Error('Invalid code');
  if (c.status === 'Redeemed') throw new Error('This meal was already served');
  if (c.status !== 'Open') throw new Error('This code has expired');
  if (String(c.date) !== todayStr_()) throw new Error('This code was for ' + c.date);
  var mode = String(req.mode || 'Takeaway');
  if (mode !== 'Indoor' && mode !== 'Takeaway') throw new Error('Choose indoor or takeaway');
  var acct = findRow_('Accounts', 'id', c.customerId);
  var r = buildOrder_({ mode: mode, table: req.table, items: [{ kind: 'dish', id: c.dishId, qty: 1 }],
                        customer: acct ? acct.name : '', phone: acct ? acct.phone : '', note: 'Subscription meal',
                        payment: 'Subscription' },
                      { staff: true, user: user, customer: null, subscription: true, linkCustomerId: c.customerId });
  updateRow_('SubClaims', 'id', c.id, { status: 'Redeemed', redeemedBy: user.name, redeemedAt: now_() });
  audit_(user, 'Subscription meal redeemed', c.dishName + ' - order #' + r.orderId);
  return { orderId: r.orderId, dishName: String(c.dishName) };
}

// ================================================================== customer notifications & push

function notifyCustomer_(customerId, title, body, orderId, kind) {
  notify_([], 'c' + customerId, title, body, orderId, kind);
}

function meNotifications_(req, acct) {
  return readTable_('Notifications').filter(function (n) { return String(n.userId) === 'c' + acct.id; })
    .slice(-30).reverse().map(function (n) {
      return { id: Number(n.id), timestamp: String(n.timestamp), title: String(n.title), body: String(n.body), kind: String(n.kind) };
    });
}

function registerDevice_(req, user) {
  var tok = String(req.deviceToken || '').trim();
  if (tok.length < 20 || tok.length > 400) throw new Error('Invalid device');
  var uid = user.role === 'customer' ? 'c' + user.id : user.id;
  var row = findRow_('Devices', 'token', tok);
  if (row) updateRow_('Devices', 'token', tok, { userId: uid, role: user.role, updatedAt: now_() });
  else appendRow_('Devices', { token: tok, userId: uid, role: user.role, updatedAt: now_() });
  return true;
}

function unregisterDevice_(req) {
  var tok = String(req.deviceToken || '').trim();
  try { deleteRow_('Devices', 'token', tok); } catch (e) {}
  return true;
}

function b64url_(bytesOrStr) { return Utilities.base64EncodeWebSafe(bytesOrStr).replace(/=+$/, ''); }

function fcmAccessToken_(sa) {
  var cache = CacheService.getScriptCache();
  var cached = cache.get('fcm_token');
  if (cached) return cached;
  var header = b64url_(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  var iat = Math.floor(new Date().getTime() / 1000);
  var claim = b64url_(JSON.stringify({ iss: sa.client_email, scope: 'https://www.googleapis.com/auth/firebase.messaging',
                                       aud: 'https://oauth2.googleapis.com/token', iat: iat, exp: iat + 3600 }));
  var sig = b64url_(Utilities.computeRsaSha256Signature(header + '.' + claim, sa.private_key));
  var res = UrlFetchApp.fetch('https://oauth2.googleapis.com/token', {
    method: 'post', muteHttpExceptions: true,
    payload: { grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: header + '.' + claim + '.' + sig } });
  var data = JSON.parse(res.getContentText());
  if (!data.access_token) throw new Error('Push sign-in failed');
  cache.put('fcm_token', data.access_token, 3000);
  return data.access_token;
}

// Sends a real phone push (works when the app is closed). Needs the Firebase service account
// saved in Script properties as FCM_SERVICE_ACCOUNT. Without it, nothing is sent and nothing breaks.
function pushTo_(roles, userId, title, body, orderId, kind) {
  var raw = PropertiesService.getScriptProperties().getProperty('FCM_SERVICE_ACCOUNT');
  if (!raw) return 0;
  var sa = JSON.parse(raw);
  var devices = readTable_('Devices').filter(function (d) {
    return userId !== '' ? String(d.userId) === String(userId) : (roles || []).indexOf(String(d.role)) >= 0;
  }).slice(0, 60);
  if (!devices.length) return 0;
  var token = fcmAccessToken_(sa);
  var url = 'https://fcm.googleapis.com/v1/projects/' + sa.project_id + '/messages:send';
  var reqs = devices.map(function (d) {
    return { url: url, method: 'post', contentType: 'application/json', muteHttpExceptions: true,
             headers: { Authorization: 'Bearer ' + token },
             payload: JSON.stringify({ message: { token: String(d.token),
               notification: { title: String(title), body: String(body || '') },
               android: { priority: 'HIGH', notification: { channel_id: 'kanyatsi_updates', icon: 'ic_stat' } },
               data: { orderId: String(orderId || ''), kind: String(kind || '') } } }) };
  });
  var res = UrlFetchApp.fetchAll(reqs);
  res.forEach(function (r, i) {
    if (r.getResponseCode() === 404 || /UNREGISTERED/.test(r.getContentText())) {
      try { deleteRow_('Devices', 'token', String(devices[i].token)); } catch (e) {}
    }
  });
  return devices.length;
}


// ------------------------------------------------------------------ inventory & stock
// Stock is always stored in the item's BASE unit (bottle, kg, number...).
// An item may also have a PACK (crate, sack, carton...) holding packSize base units.

var DEFAULT_LOW_PCT = 25;

function num_(v) { var n = Number(v); return isFinite(n) ? n : 0; }
function fmt_(n) { return String(Math.round(num_(n) * 100) / 100); }

function stockText_(stock, unit, packName, packSize) {
  stock = num_(stock);
  if (packName && packSize > 0 && stock >= packSize) {
    var packs = Math.floor(stock / packSize + 1e-9);
    var rem = Math.round((stock - packs * packSize) * 100) / 100;
    return fmt_(packs) + ' ' + packName + (rem > 0 ? ' + ' + fmt_(rem) + ' ' + unit : '') +
           ' (' + fmt_(stock) + ' ' + unit + ')';
  }
  return fmt_(stock) + ' ' + unit;
}

function invView_(x, includePrices) {
  var stock = num_(x.stock), minimum = num_(x.minimum);
  var packSize = num_(x.packSize), full = num_(x.fullLevel);
  var lowPct = num_(x.lowPct) > 0 ? num_(x.lowPct) : DEFAULT_LOW_PCT;
  if (!(full > 0)) full = stock;
  var pct = full > 0 ? Math.min(100, stock / full * 100) : (stock > 0 ? 100 : 0);
  var out = stock <= 0;
  var low = out || pct <= lowPct || (minimum > 0 && stock <= minimum);
  var v = {
    id: Number(x.id), name: String(x.name), unit: String(x.unit), stock: stock, minimum: minimum,
    packName: String(x.packName || ''), packSize: packSize, fullLevel: full, lowPct: lowPct,
    percent: Math.round(pct * 10) / 10, low: low, out: out,
    stockText: stockText_(stock, String(x.unit), String(x.packName || ''), packSize)
  };
  if (includePrices) {
    v.packPrice = num_(x.packPrice); v.unitPrice = num_(x.unitPrice);
    v.value = Math.round(stock * num_(x.unitPrice));
  }
  return v;
}

function listInventory_(req, user) {
  var prices = user && (user.role === 'admin' || user.role === 'manager');
  return readTable_('Inventory').map(function (x) { return invView_(x, prices); });
}

function cleanItemFields_(req, existing) {
  var f = {};
  var name = String(req.name !== undefined ? req.name : (existing ? existing.name : '')).trim();
  var unit = String(req.unit !== undefined ? req.unit : (existing ? existing.unit : '')).trim();
  if (!name || !unit) throw new Error('Item name and unit are required');
  if (name.length > 60 || unit.length > 30) throw new Error('Name or unit is too long');
  f.name = name; f.unit = unit;
  function pick(key, label) {
    if (req[key] === undefined) return existing ? existing[key] : '';
    var raw = String(req[key]).trim();
    if (raw === '') return '';
    var n = Number(raw);
    if (!(n >= 0)) throw new Error(label + ' must be a number');
    return n;
  }
  f.packName = String(req.packName !== undefined ? req.packName : (existing ? existing.packName : '')).trim().slice(0, 30);
  f.packSize = pick('packSize', 'Items per pack');
  f.packPrice = pick('packPrice', 'Pack price');
  f.unitPrice = pick('unitPrice', 'Single item price');
  f.lowPct = pick('lowPct', 'Low-stock warning level');
  f.minimum = pick('minimum', 'Minimum');
  if (f.packSize !== '' && f.packSize !== 0 && !(f.packSize > 0)) throw new Error('Items per pack must be more than zero');
  if (f.lowPct !== '' && f.lowPct > 100) throw new Error('Warning level is a percentage up to 100');
  rememberUnit_(f.unit); rememberUnit_(f.packName);
  if (f.unitPrice === '' && f.packPrice !== '' && f.packSize !== '' && f.packSize > 0) {
    f.unitPrice = Math.round(f.packPrice / f.packSize * 100) / 100;
  }
  if (f.packPrice === '' && f.unitPrice !== '' && f.packSize !== '' && f.packSize > 0 && f.packName) {
    f.packPrice = Math.round(f.unitPrice * f.packSize * 100) / 100;
  }
  return f;
}

function logMovement_(item, change, reason, user, kind, cost, balance) {
  appendRow_('StockMovements', { timestamp: now_(), itemId: item.id, name: item.name, change: change,
                                 reason: reason, by: user.name, kind: kind, unit: item.unit,
                                 cost: cost === undefined ? '' : cost, balance: balance });
}

function saveInventoryItem_(req, user) {
  if (req.id) {
    var old = findRow_('Inventory', 'id', req.id);
    if (!old) throw new Error('Stock item not found');
    var f = cleanItemFields_(req, old);
    f.updatedAt = now_();
    updateRow_('Inventory', 'id', req.id, f);
    audit_(user, 'Inventory item edited', f.name);
    return { id: Number(req.id) };
  }
  var fields = cleanItemFields_(req, null);
  var dup = readTable_('Inventory').filter(function (x) {
    return String(x.name).toLowerCase() === fields.name.toLowerCase();
  });
  if (dup.length) throw new Error('"' + fields.name + '" already exists. Use Add stock on it instead.');
  var stock = req.stock === undefined || req.stock === '' ? 0 : Number(req.stock);
  if (!(stock >= 0)) throw new Error('Enter valid quantities');
  var id = nextId_('Inventory', 'id', 1);
  fields.id = id; fields.stock = stock; fields.fullLevel = stock; fields.updatedAt = now_();
  appendRow_('Inventory', fields);
  if (stock > 0) logMovement_({ id: id, name: fields.name, unit: fields.unit }, stock, 'Opening stock', user, 'IN', '', stock);
  audit_(user, 'Inventory item added', fields.name);
  return { id: id };
}

function deleteInventoryItem_(req, user) {
  var it = findRow_('Inventory', 'id', req.id);
  if (!it) throw new Error('Stock item not found');
  deleteRow_('Inventory', 'id', req.id);
  audit_(user, 'Inventory item deleted', String(it.name));
  return true;
}

// Add stock to an existing item (itemId) or create it on the spot (name + unit).
// qtyUnit: 'base' (single items) or 'pack' (crates, sacks...).
function addStock_(req, user) {
  var qty = Number(req.qty);
  if (!(qty > 0)) throw new Error('Enter how many were bought');
  var qtyUnit = String(req.qtyUnit || 'base') === 'pack' ? 'pack' : 'base';
  var item;
  if (req.itemId) {
    item = findRow_('Inventory', 'id', req.itemId);
    if (!item) throw new Error('Stock item not found');
    var hasChange = ['unit', 'packName', 'packSize', 'packPrice', 'unitPrice', 'lowPct'].some(function (k) {
      return req[k] !== undefined && String(req[k]).trim() !== '';
    });
    if (hasChange) {
      var merged = {};
      ['name', 'unit', 'packName', 'packSize', 'packPrice', 'unitPrice', 'lowPct', 'minimum'].forEach(function (k) {
        merged[k] = (req[k] !== undefined && String(req[k]).trim() !== '') ? req[k] : item[k];
      });
      var nf = cleanItemFields_(merged, item);
      updateRow_('Inventory', 'id', item.id, nf);
      item = findRow_('Inventory', 'id', item.id);
    }
  } else {
    var created = saveInventoryItem_({
      name: req.name, unit: req.unit, packName: req.packName, packSize: req.packSize,
      packPrice: req.packPrice, unitPrice: req.unitPrice, lowPct: req.lowPct, stock: 0
    }, user);
    item = findRow_('Inventory', 'id', created.id);
  }
  var packSize = num_(item.packSize);
  var base = qty;
  if (qtyUnit === 'pack') {
    if (!(packSize > 0)) throw new Error('Say how many ' + item.unit + ' are in one ' + (item.packName || 'pack') + ' first');
    base = qty * packSize;
  }
  var cost = '';
  if (qtyUnit === 'pack' && item.packPrice !== '' && num_(item.packPrice) > 0) cost = Math.round(qty * num_(item.packPrice));
  else if (item.unitPrice !== '' && num_(item.unitPrice) > 0) cost = Math.round(base * num_(item.unitPrice));
  var newStock = Math.round((num_(item.stock) + base) * 1000) / 1000;
  // A restock sets the new "full" level, which the low-stock percentage is measured against.
  updateRow_('Inventory', 'id', item.id, { stock: newStock, fullLevel: newStock, updatedAt: now_() });
  var reason = String(req.note || '').trim().slice(0, 100) || 'Purchase';
  logMovement_(item, base, reason + (qtyUnit === 'pack' ? ' (' + fmt_(qty) + ' ' + (item.packName || 'pack') + ')' : ''),
               user, 'IN', cost, newStock);
  audit_(user, 'Stock added', item.name + ' +' + fmt_(base) + ' ' + item.unit);
  return invView_(findRow_('Inventory', 'id', item.id), true);
}

// Items used (by the kitchen, or recorded by the manager). Subtracts from stock.
function useStock_(req, user) {
  var list = Array.isArray(req.items) ? req.items : [];
  if (!list.length) throw new Error('Choose at least one item');
  if (list.length > 40) throw new Error('Too many items at once');
  var wanted = {};
  list.forEach(function (x) {
    var item = findRow_('Inventory', 'id', x.id);
    if (!item) throw new Error('A stock item no longer exists');
    var qty = Number(x.qty);
    if (!(qty > 0)) throw new Error('Enter a quantity for ' + item.name);
    var unit = String(x.qtyUnit || 'base') === 'pack' ? 'pack' : 'base';
    var base = qty;
    if (unit === 'pack') {
      if (!(num_(item.packSize) > 0)) throw new Error(item.name + ' has no pack size set');
      base = qty * num_(item.packSize);
    }
    wanted[String(item.id)] = (wanted[String(item.id)] || 0) + base;
  });
  Object.keys(wanted).forEach(function (id) {
    var item = findRow_('Inventory', 'id', id);
    if (wanted[id] > num_(item.stock) + 1e-9) {
      throw new Error('Not enough ' + item.name + ' in stock. Available: ' +
        stockText_(item.stock, item.unit, item.packName, num_(item.packSize)));
    }
  });
  var note = String(req.note || '').trim().slice(0, 80);
  var reason = (user.role === 'kitchen' ? 'Used in kitchen' : 'Used (recorded by ' + user.role + ')') + (note ? ': ' + note : '');
  var done = [];
  Object.keys(wanted).forEach(function (id) {
    var item = findRow_('Inventory', 'id', id);
    var before = invView_(item, false);
    var newStock = Math.round((num_(item.stock) - wanted[id]) * 1000) / 1000;
    updateRow_('Inventory', 'id', id, { stock: newStock, updatedAt: now_() });
    logMovement_(item, -wanted[id], reason, user, 'OUT', '', newStock);
    var after = invView_(findRow_('Inventory', 'id', id), false);
    if (after.out && !before.out) {
      notify_(['manager', 'admin'], '', 'Out of stock: ' + item.name, 'There is none left. Please buy more.', '', 'stock');
    } else if (after.low && !before.low) {
      notify_(['manager', 'admin'], '', 'Low stock: ' + item.name,
              'Only ' + after.stockText + ' left (' + Math.round(after.percent) + '%).', '', 'stock');
    }
    done.push(after);
  });
  audit_(user, 'Stock used', Object.keys(wanted).map(function (id) {
    var it = findRow_('Inventory', 'id', id); return it.name + ' -' + fmt_(wanted[id]);
  }).join(', '));
  return { updated: done };
}

function adjustStock_(req, user) {
  var item = findRow_('Inventory', 'id', req.id);
  if (!item) throw new Error('Stock item not found');
  var change = Number(req.change);
  if (!isFinite(change) || change === 0) throw new Error('Enter a quantity to add or remove');
  var newStock = Number(item.stock) + change;
  if (newStock < 0) throw new Error('Stock cannot go below zero');
  var reason = String(req.reason || 'Adjustment').slice(0, 100);
  var upd = { stock: newStock, updatedAt: now_() };
  if (newStock > num_(item.fullLevel)) upd.fullLevel = newStock;
  updateRow_('Inventory', 'id', req.id, upd);
  logMovement_(item, change, reason, user, 'ADJ', '', newStock);
  audit_(user, 'Inventory adjustment', item.name + ' ' + (change > 0 ? '+' : '') + change + ' (' + reason + ')');
  return { stock: newStock };
}

function listStockMovements_(req) {
  var rows = readTable_('StockMovements');
  if (req.itemId) rows = rows.filter(function (m) { return String(m.itemId) === String(req.itemId); });
  return rows.reverse().slice(0, 200).map(function (m) {
    return { timestamp: String(m.timestamp), name: String(m.name), change: num_(m.change),
             unit: String(m.unit || ''), reason: String(m.reason), by: String(m.by),
             kind: String(m.kind || ''), cost: m.cost === '' ? 0 : num_(m.cost), balance: m.balance === '' ? 0 : num_(m.balance) };
  });
}

// Data for the stock graphs: levels now + usage per day for the last N days.
function stockReport_(req) {
  var days = Math.max(3, Math.min(60, Math.floor(Number(req.days || 14))));
  var items = readTable_('Inventory');
  var views = items.map(function (x) { return invView_(x, true); });
  var labels = [], keys = [];
  for (var i = days - 1; i >= 0; i--) {
    var k = daysAgoStr_(i);
    keys.push(k); labels.push(k.slice(5));
  }
  var index = {};
  keys.forEach(function (k, i) { index[k] = i; });
  var byItem = {}, perDayValue = keys.map(function () { return 0; });
  var priceOf = {};
  items.forEach(function (x) { priceOf[String(x.id)] = num_(x.unitPrice); });
  readTable_('StockMovements').forEach(function (m) {
    if (String(m.kind) !== 'OUT') return;
    var d = String(m.timestamp).slice(0, 10);
    if (index[d] === undefined) return;
    var key = String(m.itemId);
    var e = byItem[key] = byItem[key] || { id: Number(m.itemId), name: String(m.name), unit: String(m.unit || ''),
                                            series: keys.map(function () { return 0; }), total: 0 };
    var used = Math.abs(num_(m.change));
    e.series[index[d]] += used; e.total += used;
    perDayValue[index[d]] += used * (priceOf[key] || 0);
  });
  var value = 0, low = 0, out = 0;
  views.forEach(function (v) { value += v.value || 0; if (v.low) low++; if (v.out) out++; });
  return {
    days: labels, items: views,
    usage: Object.keys(byItem).map(function (k) {
      var e = byItem[k];
      e.series = e.series.map(function (n) { return Math.round(n * 100) / 100; });
      e.total = Math.round(e.total * 100) / 100;
      return e;
    }),
    usageValue: perDayValue.map(function (n) { return Math.round(n); }),
    summary: { items: views.length, low: low, out: out, stockValue: Math.round(value) }
  };
}

// ------------------------------------------------------------------ notifications
// Messages are stored per role (or per person). The app asks for new ones every few
// seconds and shows them as phone notifications.

function notify_(roles, userId, title, body, orderId, kind) {
  try {
    appendRow_('Notifications', {
      id: nextId_('Notifications', 'id', 1), timestamp: now_(),
      roles: (roles || []).join(','), userId: userId === undefined ? '' : userId,
      title: String(title).slice(0, 80), body: String(body || '').slice(0, 200),
      orderId: orderId === undefined ? '' : orderId, kind: kind || 'info'
    });
    var s = sheet_('Notifications');
    if (s.getLastRow() > 700) { s.deleteRows(2, 300); dropCache_('Notifications'); }   // keep the sheet small
  } catch (e) { /* a failed notification must never break the real action */ }
  try { pushTo_(roles, userId === undefined ? '' : userId, title, body, orderId, kind); } catch (e2) { /* push is optional */ }
}

function listNotifications_(req, user) {
  var rows = readTable_('Notifications').filter(function (n) {
    if (String(n.userId) !== '') return String(n.userId) === String(user.id);
    return String(n.roles).split(',').indexOf(user.role) >= 0;
  });
  return rows.slice(-40).reverse().map(function (n) {
    return { id: Number(n.id), timestamp: String(n.timestamp), title: String(n.title),
             body: String(n.body), orderId: n.orderId === '' ? 0 : Number(n.orderId), kind: String(n.kind) };
  });
}

function sendNotification_(req, user) {
  var roles = (Array.isArray(req.roles) ? req.roles : []).filter(function (r) { return ROLES.indexOf(r) >= 0; });
  var title = String(req.title || '').trim();
  if (!roles.length) throw new Error('Choose who should receive it');
  if (!title) throw new Error('Write a title');
  notify_(roles, '', title, String(req.body || ''), '', 'broadcast');
  audit_(user, 'Notification sent', title + ' -> ' + roles.join(','));
  return true;
}

function saveHeroImages_(req, user) {
  var list = Array.isArray(req.images) ? req.images : [];
  var clean = [];
  list.forEach(function (u) {
    u = String(u || '').trim();
    if (/^https:\/\//.test(u) && u.length < 500) clean.push(u);
  });
  if (clean.length > 12) throw new Error('At most 12 background pictures');
  setSetting_('heroImages', JSON.stringify(clean));
  audit_(user, 'Background pictures updated', String(clean.length));
  return { images: clean };
}

// ------------------------------------------------------------------ delivery codes
// Every delivery order gets a short random code (8 characters). The customer shows it
// to the delivery man, who enters it on his phone. It works ONCE.

var CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';   // no 0/O/1/I/L

function newDeliveryCode_() {
  var used = {};
  readTable_('Orders').forEach(function (o) { if (o.code) used[String(o.code)] = true; });
  for (var tries = 0; tries < 50; tries++) {
    var c = '';
    for (var i = 0; i < 8; i++) c += CODE_ALPHABET.charAt(Math.floor(Math.random() * CODE_ALPHABET.length));
    if (!used[c]) return c;
  }
  throw new Error('Could not make a code. Please try again.');
}

function amountDue_(o) {
  var due = o.paymentStatus !== 'Paid' && (o.paymentMethod === 'Pay on Delivery' || o.paymentMethod === 'Cash');
  return due ? Number(o.total) : 0;
}

function deliveryForCode_(req, user) {
  var code = String(req.code || '').trim().toUpperCase().replace(/[^A-Z0-9]/g, '');
  if (code.length < 4 || code.length > 10) throw new Error('Enter the code the customer shows you');
  var cache = CacheService.getScriptCache();
  var key = 'codefail_' + user.id;
  var fails = Number(cache.get(key) || 0);
  if (fails >= 8) throw new Error('Too many wrong codes. Wait 10 minutes and try again.');
  var o = null;
  readTable_('Orders').forEach(function (r) { if (String(r.code) === code) o = r; });
  var problem = '';
  if (!o) problem = 'That code is not valid.';
  else if (toBool_(o.codeUsed)) problem = 'This code was already used. The order is closed.';
  else if (o.status !== 'Assigned') problem = 'Order #' + o.id + ' is ' + o.status + ' and cannot be handed over now.';
  else if (String(o.assignedToId) !== String(user.id)) problem = 'This order was given to another delivery man.';
  if (problem) {
    cache.put(key, String(fails + 1), LOCKOUT_SECONDS);
    throw new Error(problem);
  }
  return o;
}

function deliveryDetails_(o) {
  var lines = itemsByOrder_()[String(o.id)] || [];
  return {
    id: Number(o.id), customer: String(o.customer), phone: String(o.phone),
    stationName: String(o.stationName || ''), mode: String(o.mode), lines: lines,
    payment: String(o.paymentMethod), paymentStatus: String(o.paymentStatus),
    subtotal: Number(o.subtotal), deliveryFee: Number(o.deliveryFee), total: Number(o.total),
    amountDue: amountDue_(o), deliveryNote: String(o.deliveryNote || ''), note: String(o.note || '')
  };
}

function lookupDeliveryCode_(req, user) {
  var o = deliveryForCode_(req, user);
  return deliveryDetails_(o);
}

function confirmDelivery_(req, user) {
  var o = deliveryForCode_(req, user);
  var due = amountDue_(o);
  if (due > 0 && req.collected !== true) {
    throw new Error('Collect UGX ' + due + ' from the customer first, then confirm.');
  }
  var changes = { status: 'Completed', completedBy: user.name, completedAt: now_(),
                  codeUsed: true, codeUsedAt: now_(), amountCollected: due > 0 ? due : 0 };
  if (due > 0) changes.paymentStatus = 'Paid';
  setStatus_(o, changes);
  CacheService.getScriptCache().remove('codefail_' + user.id);
  audit_(user, 'Delivery confirmed by code', '#' + o.id + (due > 0 ? ' collected UGX ' + due : ''));
  finishOrder_(o, user, 'Handed over by ' + user.name + (due > 0 ? ' - collected UGX ' + due : ''));
  return { id: Number(o.id), collected: due };
}

function listMyDone_(req, user) {
  return viewOrders_(function (o) {
    return o.status === 'Completed' && String(o.assignedToId) === String(user.id);
  }, 50, true, false);
}

function listSubscribers_() {
  return readTable_('Customers').filter(function (c) { return toBool_(c.whatsappOptIn); })
      .map(function (c) { return { phone: String(c.phone), name: String(c.name) }; });
}

function saveCustomer_(phone, name, optIn) {
  var existing = findRow_('Customers', 'phone', phone);
  if (existing) {
    var upd = {};
    if (name) upd.name = name;
    if (optIn && !toBool_(existing.whatsappOptIn)) { upd.whatsappOptIn = true; upd.optInDate = now_(); }
    if (Object.keys(upd).length) updateRow_('Customers', 'phone', phone, upd);
  } else {
    appendRow_('Customers', { phone: phone, name: name, whatsappOptIn: optIn, optInDate: optIn ? now_() : '' });
  }
}

// ----------------------------------------------------------------- statistics

function pad2_(n) { return (n < 10 ? '0' : '') + n; }
function ymd_(d) { return d.getFullYear() + '-' + pad2_(d.getMonth() + 1) + '-' + pad2_(d.getDate()); }
function parseYmd_(s) {
  var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(s || ''));
  if (!m) throw new Error('Invalid date');
  return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), 12, 0, 0);
}
function parseStamp_(s) {
  var m = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$/.exec(String(s || ''));
  return m ? new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6])) : null;
}
function daysAgoStr_(n) {
  var d = new Date();
  d.setDate(d.getDate() - n);
  return Utilities.formatDate(d, TIMEZONE, 'yyyy-MM-dd');
}

var MONTH_NAMES = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/**
 * Statistics are built from COMPLETED orders (approved, cooked and handed over).
 * mode 'day'   : from, to (yyyy-MM-dd, max 92 days)
 * mode 'month' : year
 * mode 'year'  : all years that have orders
 */
function stats_(req, user) {
  var mode = String(req.mode || 'day');
  var done = readTable_('Orders').filter(function (o) { return o.status === 'Completed'; });
  var servingsByOrder = {};
  var itemRows = readTable_('OrderItems');
  itemRows.forEach(function (x) {
    servingsByOrder[String(x.orderId)] = (servingsByOrder[String(x.orderId)] || 0) + Number(x.servings);
  });
  function dateOf(o) { return String(o.completedAt || o.createdAt); }

  var buckets = [], keyOf, from = '', to = '';
  if (mode === 'month') {
    var year = Math.floor(Number(req.year)) || new Date().getFullYear();
    for (var m = 0; m < 12; m++) buckets.push({ key: year + '-' + pad2_(m + 1), label: MONTH_NAMES[m] });
    keyOf = function (o) { return dateOf(o).slice(0, 7); };
    from = year + '-01-01'; to = year + '-12-31';
  } else if (mode === 'year') {
    var years = {};
    done.forEach(function (o) { years[dateOf(o).slice(0, 4)] = true; });
    var thisYear = String(new Date().getFullYear());
    years[thisYear] = true;
    Object.keys(years).sort().forEach(function (y) { buckets.push({ key: y, label: y }); });
    keyOf = function (o) { return dateOf(o).slice(0, 4); };
    from = buckets[0].key + '-01-01'; to = buckets[buckets.length - 1].key + '-12-31';
  } else {
    var end = req.to ? parseYmd_(req.to) : new Date();
    end.setHours(12, 0, 0, 0);
    var start = req.from ? parseYmd_(req.from) : new Date(end.getTime() - 13 * 86400000);
    start.setHours(12, 0, 0, 0);
    if (start > end) throw new Error('The start date must be before the end date');
    var span = Math.round((end - start) / 86400000) + 1;
    if (span > 92) throw new Error('Choose at most 92 days at a time');
    for (var i = 0; i < span; i++) {
      var d = new Date(start.getTime() + i * 86400000);
      d.setHours(12, 0, 0, 0);
      buckets.push({ key: ymd_(d), label: pad2_(d.getMonth() + 1) + '-' + pad2_(d.getDate()) });
    }
    keyOf = function (o) { return dateOf(o).slice(0, 10); };
    from = buckets[0].key; to = buckets[buckets.length - 1].key;
  }

  var series = buckets.map(function (b) { return { key: b.key, label: b.label, sales: 0, orders: 0, servings: 0 }; });
  var index = {};
  series.forEach(function (s, i) { index[s.key] = i; });

  var inPeriod = [], ids = {};
  var totals = { sales: 0, orders: 0, servings: 0 };
  var byPayment = {}, byMode = {};
  done.forEach(function (o) {
    var k = keyOf(o);
    if (index[k] === undefined) return;
    var s = series[index[k]];
    var total = Number(o.total);
    var sv = servingsByOrder[String(o.id)] || 0;
    s.sales += total; s.orders += 1; s.servings += sv;
    totals.sales += total; totals.orders += 1; totals.servings += sv;
    byPayment[o.paymentMethod] = (byPayment[o.paymentMethod] || 0) + total;
    byMode[o.mode] = (byMode[o.mode] || 0) + total;
    inPeriod.push(o); ids[String(o.id)] = true;
  });

  var sold = {};
  itemRows.forEach(function (x) {
    if (!ids[String(x.orderId)]) return;
    var key = x.kind + ':' + x.name;
    var e = sold[key] = sold[key] || { name: String(x.name), kind: String(x.kind), qty: 0, servings: 0, total: 0 };
    e.qty += Number(x.qty); e.servings += Number(x.servings); e.total += Number(x.lineTotal);
  });
  var best = Object.keys(sold).map(function (k) { return sold[k]; })
      .sort(function (a, b) { return b.qty - a.qty; }).slice(0, 8);

  // Order outcomes for orders placed in the same period.
  var outcomes = { placed: 0, rejected: 0, cancelled: 0, failed: 0 };
  readTable_('Orders').forEach(function (o) {
    var k = String(o.createdAt).slice(0, mode === 'month' ? 7 : mode === 'year' ? 4 : 10);
    if (index[k] === undefined) return;
    outcomes.placed++;
    if (o.status === 'Rejected') outcomes.rejected++;
    if (o.status === 'Cancelled') outcomes.cancelled++;
    if (o.status === 'Failed') outcomes.failed++;
  });

  var minutes = 0, timed = 0;
  inPeriod.forEach(function (o) {
    var a = parseStamp_(o.createdAt), b = parseStamp_(o.completedAt);
    if (a && b && b >= a) { minutes += (b - a) / 60000; timed++; }
  });

  var result = {
    mode: mode, from: from, to: to, series: series, totals: totals,
    averageOrder: totals.orders ? Math.round(totals.sales / totals.orders) : 0,
    averageMinutes: timed ? Math.round(minutes / timed) : 0,
    byPayment: byPayment, byMode: byMode, bestSellers: best, outcomes: outcomes,
    lowStockCount: readTable_('Inventory').filter(function (x) { return invView_(x, false).low; }).length
  };

  if (user && user.role === 'admin') {
    var staff = {};
    var who = function (name, role) {
      if (!name) return null;
      var k = name + '|' + role;
      return staff[k] = staff[k] || { name: String(name), role: role, approved: 0, cooked: 0, handedOver: 0, sales: 0 };
    };
    inPeriod.forEach(function (o) {
      var a = who(o.approvedBy, 'manager'); if (a) a.approved++;
      var c = who(o.cookedBy, 'kitchen'); if (c) c.cooked++;
      var h = who(o.completedBy, o.mode === 'Delivery' ? 'delivery' : 'waiter');
      if (h) { h.handedOver++; h.sales += Number(o.total); }
    });
    result.staff = Object.keys(staff).map(function (k) { return staff[k]; });
  }
  return result;
}

// ------------------------------------------------------------- sheet helpers

// Speed: remember sheets and table reads for the duration of ONE request.
var TCACHE_ = {};
var SHEETOBJ_ = {};
var MENU_SHEETS_ = { Menu: 1, Combos: 1, Stations: 1, Settings: 1 };

function dropCache_(name) {
  delete TCACHE_[name];
  if (MENU_SHEETS_[name]) {
    try { CacheService.getScriptCache().remove('menu_json'); } catch (e) {}
  }
}

function sheet_(name) {
  if (SHEETOBJ_[name]) return SHEETOBJ_[name];
  var s = SpreadsheetApp.getActive().getSheetByName(name);
  if (!s) throw new Error('Sheet "' + name + '" is missing. Run setupSheets once.');
  SHEETOBJ_[name] = s;
  return s;
}

function readTable_(name) {
  var c = TCACHE_[name];
  if (!c) { c = readTableRaw_(name); TCACHE_[name] = c; }
  return c.slice();
}

function readTableRaw_(name) {
  var s = sheet_(name);
  var last = s.getLastRow();
  if (last < 2) return [];
  var headers = SHEETS[name];
  var values = s.getRange(2, 1, last - 1, headers.length).getValues();
  return values.filter(function (r) { return r.join('') !== ''; }).map(function (r) {
    var o = {};
    headers.forEach(function (h, i) { o[h] = r[i]; });
    return o;
  });
}

function appendRow_(name, obj) {
  var headers = SHEETS[name];
  sheet_(name).appendRow(headers.map(function (h) { return obj[h] === undefined ? '' : obj[h]; }));
  dropCache_(name);
}

function findRow_(name, key, value) {
  var rows = readTable_(name);
  for (var i = 0; i < rows.length; i++) {
    if (String(rows[i][key]) === String(value)) return rows[i];
  }
  return null;
}

function rowIndex_(name, key, value) {
  var s = sheet_(name);
  var last = s.getLastRow();
  if (last < 2) return -1;
  var col = SHEETS[name].indexOf(key);
  var keys = s.getRange(2, col + 1, last - 1, 1).getValues();
  for (var i = 0; i < keys.length; i++) {
    if (String(keys[i][0]) === String(value)) return i + 2;
  }
  return -1;
}

function updateRow_(name, key, value, changes) {
  var row = rowIndex_(name, key, value);
  if (row < 0) throw new Error('Row not found');
  var s = sheet_(name), headers = SHEETS[name];
  var range = s.getRange(row, 1, 1, headers.length);
  var vals = range.getValues()[0];
  Object.keys(changes).forEach(function (field) {
    var col = headers.indexOf(field);
    if (col >= 0) vals[col] = changes[field];
  });
  range.setValues([vals]);
  dropCache_(name);
}

function deleteRow_(name, key, value) {
  var row = rowIndex_(name, key, value);
  if (row < 0) throw new Error('Row not found');
  sheet_(name).deleteRow(row);
  dropCache_(name);
}

function nextId_(name, key, start) {
  var max = start - 1;
  readTable_(name).forEach(function (r) { var n = Number(r[key]); if (n > max) max = n; });
  return max + 1;
}

function getSetting_(key, fallback) {
  var r = findRow_('Settings', 'key', key);
  return r ? r.value : fallback;
}

function setSetting_(key, value) {
  if (findRow_('Settings', 'key', key)) updateRow_('Settings', 'key', key, { value: value });
  else appendRow_('Settings', { key: key, value: value });
}

function audit_(user, action, details) {
  appendRow_('Audit', { timestamp: now_(), user: user ? user.name : '', role: user ? user.role : '',
                        action: action, details: details });
}

function now_() { return Utilities.formatDate(new Date(), TIMEZONE, 'yyyy-MM-dd HH:mm:ss'); }

function toBool_(v) { return v === true || String(v).toLowerCase() === 'true'; }

// ---------------------------------------------------------------- first setup

function setupSheets() {
  TCACHE_ = {}; SHEETOBJ_ = {};
  var ss = SpreadsheetApp.getActive();
  Object.keys(SHEETS).forEach(function (name) {
    var s = ss.getSheetByName(name) || ss.insertSheet(name);
    var headers = SHEETS[name];
    s.getRange(1, 1, 1, headers.length).setValues([headers]).setFontWeight('bold');
    s.setFrozenRows(1);
    (TEXT_COLUMNS[name] || []).forEach(function (h) {
      s.getRange(2, headers.indexOf(h) + 1, s.getMaxRows() - 1, 1).setNumberFormat('@');
    });
  });
  var blank = ss.getSheetByName('Sheet1');
  if (blank && ss.getSheets().length > 1 && blank.getLastRow() === 0) ss.deleteSheet(blank);

  // Touch Drive and Mail once so Google asks for those permissions now.
  var folders = DriveApp.getFoldersByName(IMAGE_FOLDER);
  if (!folders.hasNext()) DriveApp.createFolder(IMAGE_FOLDER);
  MailApp.getRemainingDailyQuota();

  if (readTable_('Menu').length === 0) {
    [
      ['Chicken Pilawo', 'Local Food', 15000, 'Spiced rice with chicken and vegetables.'],
      ['Beef Pilawo', 'Local Food', 14000, 'Pilawo rice served with tender beef.'],
      ['Katogo', 'Breakfast', 10000, 'Traditional breakfast with fresh ingredients.'],
      ['Chapati', 'Snacks', 3000, 'Freshly prepared chapati.'],
      ['Pizza', 'Pizza', 22000, 'Restaurant house pizza.'],
      ['Coffee', 'Coffee', 5000, 'Hot freshly prepared coffee.'],
      ['Soda', 'Beverages', 3000, 'Chilled soft drink.'],
      ['Fresh Juice', 'Beverages', 6000, 'Fresh seasonal fruit juice.']
    ].forEach(function (m, i) {
      appendRow_('Menu', { id: i + 1, name: m[0], category: m[1], price: m[2],
                           description: m[3], available: true, imageUrl: '' });
    });
  }
  if (readTable_('Combos').length === 0) {
    appendRow_('Combos', { id: 1, name: 'Pilawo & Soda', description: 'Chicken Pilawo with a chilled soda.',
                           price: 17000, available: true, imageUrl: '',
                           itemsJson: JSON.stringify([{ id: 1, qty: 1 }, { id: 7, qty: 1 }]) });
  }
  if (readTable_('Stations').length === 0) {
    appendRow_('Stations', { id: 1, name: 'Kagando Trading Centre', fee: 2000 });
    appendRow_('Stations', { id: 2, name: 'Health Centre Junction', fee: 3000 });
  }
  if (!findRow_('Settings', 'key', 'tableCount')) setSetting_('tableCount', 10);
  if (readTable_('Inventory').length === 0) {
    [['Rice', 'kg', 18, 10], ['Chicken', 'kg', 7, 8], ['Beef', 'kg', 12, 5],
     ['Cooking Oil', 'litres', 4, 5], ['Soda', 'crates', 9, 3]
    ].forEach(function (x, i) {
      appendRow_('Inventory', { id: i + 1, name: x[0], unit: x[1], stock: x[2], minimum: x[3] });
    });
  }
  if (readTable_('Users').length === 0) {
    var salt = Utilities.getUuid();
    appendRow_('Users', { id: 1, name: 'Administrator', username: 'admin', email: '', role: 'admin',
                          salt: salt, passHash: hashPassword_(salt, 'Admin@1234'),
                          active: true, mustChange: true });
  }
  Logger.log('Setup complete. First login: admin / Admin@1234 (you must change it).');
}
