import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'push.dart';

part 'brand.dart';
part 'stock.dart';
part 'delivery.dart';
part 'customer.dart';
part 'staff2.dart';

// ---------------------------------------------------------------------------
// SETUP: paste your Google Apps Script "Web app" URL between the quotes
// (it ends in /exec). See README.md. While it is empty the app runs in DEMO
// mode (customers can browse; nothing is saved and staff cannot sign in).
// ---------------------------------------------------------------------------
const String kApiUrl = 'https://script.google.com/macros/s/AKfycbwA38fpQQAExaL9V25r3RmISuSrEfvY9GBKSjFU54LUMHWwug__hPcLxUwuvpBcZqEs/exec';

const String kSessionExpired = 'SESSION_EXPIRED';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Notify.init();
  CustomerStore.instance.restore();
  runApp(const AkanyatsiApp());
}

class AkanyatsiApp extends StatelessWidget {
  const AkanyatsiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kanyatsi Restaurant',
      debugShowCheckedModeBanner: false,
      theme: buildKanyatsiTheme(),
      builder: (context, child) => BrandBackdrop(child: child ?? const SizedBox.shrink()),
      home: const HomeScreen(),
    );
  }
}

// ============================================================ API (Google Sheets)

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

typedef Rows = List<Map<String, dynamic>>;

/// Talks to the Google Apps Script web app that reads/writes the Google Sheet.
class Api {
  static String? token;
  static String? customerToken;
  static bool get configured => kApiUrl.trim().isNotEmpty;

  static Future<Rows> list(String action, [Map<String, dynamic>? data]) async {
    final r = await call(action, data);
    return (r as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  static Future<Map<String, dynamic>> map(String action,
      [Map<String, dynamic>? data, Duration? timeout]) async {
    final r = await call(action, data, timeout);
    return Map<String, dynamic>.from(r as Map);
  }

  static Future<MenuBundle> menu() async {
    if (!configured) return MenuBundle.demo();
    return MenuBundle.fromJson(await map('getMenu'));
  }

  static Future<dynamic> call(String action,
      [Map<String, dynamic>? data, Duration? timeout]) async {
    if (!configured) {
      throw ApiException('The app is not connected to Google Sheets yet.');
    }
    final limit = timeout ?? const Duration(seconds: 45);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final isCustomerAction = RegExp(r'^me[A-Z]').hasMatch(action);
      final sessionToken = isCustomerAction ? customerToken : token;
      final body = jsonEncode({
        'action': action,
        if (sessionToken != null) 'token': sessionToken,
        ...?data,
      });

      // Apps Script answers a POST with a redirect; follow it by hand with GET.
      final req = await client.postUrl(Uri.parse(kApiUrl.trim()));
      req.followRedirects = false;
      req.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
      req.add(utf8.encode(body));
      var res = await req.close().timeout(limit);

      var hops = 0;
      // Note: res.isRedirect is false for a 302 after a POST, so check the
      // status code ourselves.
      bool isRedirectCode(int c) =>
          c == 301 || c == 302 || c == 303 || c == 307 || c == 308;
      var current = Uri.parse(kApiUrl.trim());
      while (isRedirectCode(res.statusCode) && hops < 8) {
        final location = res.headers.value(HttpHeaders.locationHeader);
        await res.drain<void>();
        if (location == null) break;
        current = current.resolve(location);
        final next = await client.getUrl(current);
        next.followRedirects = false;
        res = await next.close().timeout(limit);
        hops++;
      }

      final text = await res.transform(utf8.decoder).join();
      dynamic decoded;
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        final snippet = text.replaceAll(RegExp(r'<[^>]*>|\s+'), ' ').trim();
        throw ApiException(
            'Unexpected reply from the server (HTTP ${res.statusCode}): '
            '${snippet.length > 120 ? snippet.substring(0, 120) : snippet}');
      }
      if (decoded is! Map) {
        throw ApiException('Unexpected reply from the server.');
      }
      if (decoded['ok'] != true) {
        final err = '${decoded['error'] ?? 'Request failed'}';
        if (err == kSessionExpired) {
          if (isCustomerAction) {
            CustomerStore.instance.clearLocal();
            throw ApiException('Please sign in to your profile again.');
          }
          token = null;
          throw ApiException(kSessionExpired);
        }
        if (err == 'FORBIDDEN') {
          throw ApiException('You are not allowed to do that.');
        }
        if (err == 'Unknown action') {
          throw ApiException('The restaurant backend is out of date. In Google Apps Script paste the latest '
              'Code.gs and use Deploy > Manage deployments > New version.');
        }
        throw ApiException(err);
      }
      return decoded['data'];
    } on ApiException {
      rethrow;
    } on SocketException {
      throw ApiException('No internet connection. Please try again.');
    } on TimeoutException {
      throw ApiException('The server took too long to answer. Please try again.');
    } on HandshakeException {
      throw ApiException('Secure connection failed. Please try again.');
    } on HttpException {
      throw ApiException('Network error. Please try again.');
    } finally {
      client.close(force: true);
    }
  }
}

// ================================================================== MODELS

enum UserRole { customer, admin, manager, kitchen, waiter, delivery }

extension RoleLabel on UserRole {
  String get label => switch (this) {
        UserRole.customer => 'Customer',
        UserRole.admin => 'Administrator',
        UserRole.manager => 'Manager',
        UserRole.kitchen => 'Kitchen (Chef)',
        UserRole.waiter => 'Waiter',
        UserRole.delivery => 'Delivery Man',
      };
}

String roleLabel(String role) {
  for (final r in UserRole.values) {
    if (r.name == role) return r.label;
  }
  return role;
}

const kStaffRoles = ['admin', 'manager', 'kitchen', 'waiter', 'delivery'];

class Dish {
  final int id;
  final String name, category, description, imageUrl;
  final double price;
  final bool available;
  final int tokenPrice;
  Dish(this.id, this.name, this.category, this.price, this.description,
      {this.available = true, this.imageUrl = '', this.tokenPrice = 0});

  factory Dish.fromJson(Map<String, dynamic> j) => Dish(
        (j['id'] as num).toInt(),
        '${j['name']}',
        '${j['category']}',
        (j['price'] as num).toDouble(),
        '${j['description'] ?? ''}',
        available: j['available'] == true,
        imageUrl: '${j['imageUrl'] ?? ''}',
        tokenPrice: ((j['tokenPrice'] as num?) ?? 0).toInt(),
      );
}

class ComboItem {
  final int id, qty;
  final String name;
  ComboItem(this.id, this.name, this.qty);
}

class Combo {
  final int id;
  final String name, description, imageUrl;
  final double price, itemsTotal;
  final bool available; // can be ordered right now
  final bool enabled; // switch set by the manager
  final List<ComboItem> items;
  Combo(this.id, this.name, this.description, this.price, this.itemsTotal,
      this.available, this.enabled, this.imageUrl, this.items);

  factory Combo.fromJson(Map<String, dynamic> j) => Combo(
        (j['id'] as num).toInt(),
        '${j['name']}',
        '${j['description'] ?? ''}',
        (j['price'] as num).toDouble(),
        (j['itemsTotal'] as num).toDouble(),
        j['available'] == true,
        j['enabled'] == true,
        '${j['imageUrl'] ?? ''}',
        [
          for (final i in (j['items'] as List))
            ComboItem((i['id'] as num).toInt(), '${i['name']}',
                (i['qty'] as num).toInt())
        ],
      );

  String get includes => items.map((i) => '${i.qty} x ${i.name}').join(', ');
}

class Station {
  final int id;
  final String name;
  final double fee;
  Station(this.id, this.name, this.fee);
}

class MenuBundle {
  final List<Dish> dishes;
  final List<Combo> combos;
  final List<Station> stations;
  final int tableCount;
  final List<String> heroImages;
  final Map<String, dynamic> info;
  final Map<String, dynamic> momo;
  final List<Map<String, dynamic>> tokenRules;
  final Map<String, List<String>> categoryImages;
  final bool tableCodesRequired;
  MenuBundle(this.dishes, this.combos, this.stations, this.tableCount,
      {this.heroImages = const [],
      this.info = const {},
      this.momo = const {},
      this.tokenRules = const [],
      this.categoryImages = const {},
      this.tableCodesRequired = false});

  factory MenuBundle.fromJson(Map<String, dynamic> j) => MenuBundle(
        [for (final d in (j['dishes'] as List)) Dish.fromJson(Map<String, dynamic>.from(d as Map))],
        [for (final c in (j['combos'] as List)) Combo.fromJson(Map<String, dynamic>.from(c as Map))],
        [
          for (final s in (j['stations'] as List))
            Station((s['id'] as num).toInt(), '${s['name']}', (s['fee'] as num).toDouble())
        ],
        (j['tableCount'] as num).toInt(),
        heroImages: [for (final u in ((j['heroImages'] as List?) ?? const [])) '$u'],
        info: Map<String, dynamic>.from((j['info'] as Map?) ?? const {}),
        momo: Map<String, dynamic>.from((j['momo'] as Map?) ?? const {}),
        tokenRules: [
          for (final r in ((j['tokenRules'] as List?) ?? const [])) Map<String, dynamic>.from(r as Map)
        ],
        categoryImages: {
          for (final e in ((j['categoryImages'] as Map?) ?? const {}).entries)
            '${e.key}': [for (final u in (e.value as List)) '$u']
        },
        tableCodesRequired: j['tableCodesRequired'] == true,
      );

  factory MenuBundle.demo() => MenuBundle(
        [
          Dish(1, 'Chicken Pilawo', 'Local Food', 15000, 'Spiced rice with chicken and vegetables.'),
          Dish(2, 'Beef Pilawo', 'Local Food', 14000, 'Pilawo rice served with tender beef.'),
          Dish(3, 'Katogo', 'Breakfast', 10000, 'Traditional breakfast with fresh ingredients.'),
          Dish(4, 'Chapati', 'Snacks', 3000, 'Freshly prepared chapati.'),
          Dish(5, 'Pizza', 'Pizza', 22000, 'Restaurant house pizza.'),
          Dish(6, 'Coffee', 'Coffee', 5000, 'Hot freshly prepared coffee.'),
          Dish(7, 'Soda', 'Beverages', 3000, 'Chilled soft drink.'),
          Dish(8, 'Fresh Juice', 'Beverages', 6000, 'Fresh seasonal fruit juice.'),
        ],
        [
          Combo(1, 'Pilawo & Soda', 'Chicken Pilawo with a chilled soda.', 17000,
              18000, true, true, '', [ComboItem(1, 'Chicken Pilawo', 1), ComboItem(7, 'Soda', 1)]),
        ],
        [Station(1, 'Kagando Trading Centre', 2000), Station(2, 'Health Centre Junction', 3000)],
        10,
      );
}

class CartLine {
  final String kind; // 'dish' or 'combo'
  final int id;
  final String name, imageUrl;
  final double price;
  int qty;
  final int tokenPrice;
  CartLine(this.kind, this.id, this.name, this.price, this.imageUrl, this.qty,
      {this.tokenPrice = 0});
  double get total => price * qty;
}

String ugx(num v) {
  final s = v.round().abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return 'UGX ${v < 0 ? '-' : ''}$b';
}

String compact(num v) {
  String trim(double x) {
    final s = x.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  if (v >= 1000000) return '${trim(v / 1000000)}M';
  if (v >= 1000) return '${trim(v / 1000)}k';
  return v.round().toString();
}

String ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// ================================================================== STORE

const kPaymentsByMode = {
  'Indoor': ['Cash', 'MTN', 'Airtel', 'Wallet', 'Tokens'],
  'Takeaway': ['Cash', 'MTN', 'Airtel', 'Wallet', 'Tokens'],
  'Delivery': ['MTN', 'Airtel', 'Pay on Delivery', 'Wallet'],
};

class RestaurantStore extends ChangeNotifier {
  static final RestaurantStore instance = RestaurantStore._();
  RestaurantStore._();

  UserRole role = UserRole.customer;
  String staffName = '';

  // current customer order
  String orderMode = 'Indoor';
  int? tableNo;
  String tableCode = '';
  Station? station;
  String customerName = '';
  String phone = '';
  String note = '';
  String paymentMethod = '';
  bool whatsappOptIn = false;
  final cart = <CartLine>[];

  MenuBundle? menu;
  bool menuLoading = false;
  String? menuError;

  void update(VoidCallback change) {
    change();
    notifyListeners();
  }

  List<String> get paymentOptions {
    final all = kPaymentsByMode[orderMode] ?? const ['Cash'];
    final signedIn = CustomerStore.instance.signedIn;
    return [
      for (final p in all)
        if ((p != 'Wallet' && p != 'Tokens') || signedIn)
          if (p != 'Tokens' || canPayTokens) p
    ];
  }

  bool get canPayTokens => cart.isNotEmpty && cart.every((x) => x.kind == 'dish' && x.tokenPrice > 0);
  int get tokensNeeded => cart.fold<int>(0, (t, x) => t + x.tokenPrice * x.qty);

  void beginOrder(String mode) {
    orderMode = mode;
    tableCode = '';
    tableNo = null;
    station = null;
    paymentMethod = '';
    notifyListeners();
  }

  Future<void> loadMenu() async {
    // Show the menu saved on this phone straight away, then refresh it in the background.
    if (menu == null && Api.configured) {
      try {
        final p = await SharedPreferences.getInstance();
        final c = p.getString('menu_cache');
        if (c != null) {
          menu = MenuBundle.fromJson(Map<String, dynamic>.from(jsonDecode(c) as Map));
          kHeroImages.value = menu!.heroImages;
          notifyListeners();
        }
      } catch (_) {}
    }
    menuLoading = menu == null;
    menuError = null;
    notifyListeners();
    try {
      if (Api.configured) {
        final raw = await Api.map('getMenu');
        menu = MenuBundle.fromJson(raw);
        try {
          final p = await SharedPreferences.getInstance();
          await p.setString('menu_cache', jsonEncode(raw));
        } catch (_) {}
      } else {
        menu = await Api.menu();
      }
      kHeroImages.value = menu!.heroImages;
    } on ApiException catch (e) {
      if (menu == null) menuError = e.message;
    } catch (_) {
      if (menu == null) menuError = 'Could not load the menu.';
    }
    menuLoading = false;
    notifyListeners();
  }

  int qtyOf(String kind, int id) {
    for (final l in cart) {
      if (l.kind == kind && l.id == id) return l.qty;
    }
    return 0;
  }

  void addLine(String kind, int id, String name, double price, String imageUrl,
      {int tokenPrice = 0}) {
    for (final l in cart) {
      if (l.kind == kind && l.id == id) {
        if (l.qty < 50) l.qty++;
        notifyListeners();
        return;
      }
    }
    cart.add(CartLine(kind, id, name, price, imageUrl, 1, tokenPrice: tokenPrice));
    notifyListeners();
  }

  void removeLine(String kind, int id) {
    for (final l in cart) {
      if (l.kind == kind && l.id == id) {
        if (l.qty > 1) {
          l.qty--;
        } else {
          cart.remove(l);
        }
        notifyListeners();
        return;
      }
    }
  }

  double get subtotal => cart.fold(0, (s, e) => s + e.total);
  double get deliveryFee => orderMode == 'Delivery' ? (station?.fee ?? 0) : 0;
  double get total => subtotal + deliveryFee;
  int get itemCount => cart.fold(0, (s, e) => s + e.qty);

  String get whereLabel => switch (orderMode) {
        'Indoor' => tableNo == null ? 'Indoor' : 'Table $tableNo',
        'Delivery' => station == null ? 'Delivery' : 'Pick-up: ${station!.name}',
        _ => 'Takeaway',
      };

  /// Sends the order to the sheet. Returns the order number
  /// (0 in demo mode, where nothing is saved).
  Future<int> submitOrder() async {
    if (cart.isEmpty) throw ApiException('Nothing selected yet.');
    if (!Api.configured) {
      cart.clear();
      notifyListeners();
      return 0;
    }
    final result = await Api.map(CustomerStore.instance.signedIn ? 'meCreateOrder' : 'createOrder', {
      'mode': orderMode,
      'table': tableNo,
      'tableCode': tableCode,
      'stationId': station?.id,
      'items': [
        for (final x in cart) {'kind': x.kind, 'id': x.id, 'qty': x.qty}
      ],
      'customer': customerName,
      'phone': phone,
      'note': note,
      'payment': paymentMethod,
      'whatsappOptIn': whatsappOptIn,
    });
    cart.clear();
    paymentMethod = '';
    notifyListeners();
    return (result['orderId'] as num).toInt();
  }

  /// Returns true when the user must choose a new password now.
  Future<bool> signIn(String username, String password) async {
    final r = await Api.map('login', {'username': username, 'password': password});
    Api.token = '${r['token']}';
    staffName = '${r['name']}';
    registerPush();
    role = UserRole.values.firstWhere((x) => x.name == r['role'],
        orElse: () => UserRole.customer);
    notifyListeners();
    return r['mustChange'] == true;
  }

  Future<void> signOut() async {
    try {
      await Api.call('logout');
    } catch (_) {}
    signOutLocal();
  }

  void signOutLocal() {
    Api.token = null;
    role = UserRole.customer;
    staffName = '';
    notifyListeners();
  }
}

// ================================================================== HELPERS

void handleSessionExpired(BuildContext context) {
  final messenger = ScaffoldMessenger.of(context);
  RestaurantStore.instance.signOutLocal();
  Navigator.of(context).popUntil((r) => r.isFirst);
  messenger.showSnackBar(const SnackBar(
      content: Text('Session expired. Please sign in again.')));
}

/// Runs [task], shows errors as a snack bar and returns true on success.
Future<bool> guarded(BuildContext context, Future<void> Function() task,
    {String? success}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await task();
    if (success != null) {
      messenger.showSnackBar(SnackBar(content: Text(success)));
    }
    return true;
  } on ApiException catch (e) {
    if (e.message == kSessionExpired) {
      if (context.mounted) handleSessionExpired(context);
    } else {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
    return false;
  } catch (_) {
    messenger.showSnackBar(const SnackBar(
        content: Text('Something went wrong. Please try again.')));
    return false;
  }
}

/// Shows a spinner over the screen while [task] runs.
Future<T> withProgress<T>(BuildContext context, Future<T> Function() task) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: Center(child: CircularProgressIndicator()),
    ),
  );
  try {
    return await task();
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

Future<bool> confirmDialog(BuildContext context, String title, String message,
    {String action = 'Yes'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
      ],
    ),
  );
  return r ?? false;
}

void alertStaff() {
  SystemSound.play(SystemSoundType.alert);
  HapticFeedback.heavyImpact();
}

class FieldSpec {
  final String key, label, initial;
  final TextInputType keyboard;
  final bool obscure;
  final List<String>? options;
  const FieldSpec(this.key, this.label,
      {this.initial = '',
      this.keyboard = TextInputType.text,
      this.obscure = false,
      this.options});
}

Future<Map<String, String>?> formDialog(
    BuildContext context, String title, List<FieldSpec> fields,
    {String action = 'Save'}) {
  final ctrls = {
    for (final f in fields) f.key: TextEditingController(text: f.initial)
  };
  return showDialog<Map<String, String>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final f in fields)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: f.options != null
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(f.label),
                            Wrap(
                              spacing: 8,
                              children: [
                                for (final o in f.options!)
                                  ChoiceChip(
                                    label: Text(o),
                                    selected: ctrls[f.key]!.text == o,
                                    onSelected: (_) =>
                                        setS(() => ctrls[f.key]!.text = o),
                                  ),
                              ],
                            ),
                          ],
                        )
                      : TextField(
                          controller: ctrls[f.key],
                          keyboardType: f.keyboard,
                          obscureText: f.obscure,
                          decoration: InputDecoration(labelText: f.label),
                        ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, {
              for (final e in ctrls.entries) e.key: e.value.text.trim()
            }),
            child: Text(action),
          ),
        ],
      ),
    ),
  );
}

/// A screen that loads its data from the sheet, with refresh, retry,
/// optional automatic refresh and a hook for "new data arrived" alerts.
class RemoteView<T> extends StatefulWidget {
  final String title;
  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data, Future<void> Function() reload) builder;
  final Widget? Function(BuildContext context, Future<void> Function() reload)? fab;
  final Duration? autoRefresh;
  final void Function(T? previous, T current)? onLoaded;
  final List<Widget> actions;
  final bool bare;
  const RemoteView({
    required this.title,
    required this.load,
    required this.builder,
    this.fab,
    this.autoRefresh,
    this.onLoaded,
    this.actions = const [],
    this.bare = false,
    super.key,
  });
  @override
  State<RemoteView<T>> createState() => _RemoteViewState<T>();
}

class _RemoteViewState<T> extends State<RemoteView<T>> {
  T? _data;
  bool _hasData = false;
  String? _error;
  bool _loading = true;
  bool _inFlight = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    final every = widget.autoRefresh;
    if (every != null) {
      _timer = Timer.periodic(every, (_) {
        if (mounted && !_inFlight) _load(silent: true);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> reload() => _load();

  Future<void> _load({bool silent = false}) async {
    if (_inFlight) return;
    _inFlight = true;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final d = await widget.load();
      if (!mounted) return;
      final previous = _hasData ? _data : null;
      setState(() {
        _data = d;
        _hasData = true;
        _loading = false;
        _error = null;
      });
      widget.onLoaded?.call(previous, d);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.message == kSessionExpired) {
        _timer?.cancel();
        handleSessionExpired(context);
        return;
      }
      if (!silent) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      if (!silent) {
        setState(() {
          _error = 'Something went wrong. Please try again.';
          _loading = false;
        });
      }
    } finally {
      _inFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (!_hasData && _loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (!_hasData && _error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: reload, child: const Text('Try again')),
            ],
          ),
        ),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: reload,
        child: widget.builder(context, _data as T, reload),
      );
    }
    if (widget.bare) return body;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          ...widget.actions,
          IconButton(
              tooltip: 'Refresh',
              onPressed: _loading ? null : reload,
              icon: const Icon(Icons.refresh)),
        ],
      ),
      body: body,
      floatingActionButton: widget.fab?.call(context, reload),
    );
  }
}

/// Keeps content a comfortable width on tablets.
class Narrow extends StatelessWidget {
  final Widget child;
  final double width;
  const Narrow({required this.child, this.width = 720, super.key});
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width), child: child),
      );
}

class SectionTitle extends StatelessWidget {
  final String text;
  const SectionTitle(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleLarge),
      );
}

class StatCard extends StatelessWidget {
  final String label, value;
  final IconData icon;
  const StatCard(this.label, this.value, this.icon, {super.key});
  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          leading: CircleAvatar(child: Icon(icon)),
          title: Text(label),
          subtitle: Text(value, style: Theme.of(context).textTheme.titleLarge),
        ),
      );
}

class FoodImage extends StatelessWidget {
  final String url;
  final double size;
  const FoodImage(this.url, {this.size = 72, super.key});

  // Small pictures load much faster on slow data: ask Google Drive for the size we need.
  String get _src {
    if (url.contains('drive.google.com/thumbnail')) {
      final w = (size * 2.5).round().clamp(240, 800);
      return url.replaceFirst(RegExp(r'sz=w\d+'), 'sz=w$w');
    }
    return url;
  }

  Widget _placeholder() => Container(
        width: size,
        height: size,
        color: kSurface2,
        child: Icon(Icons.restaurant,
            color: kGold.withValues(alpha: 0.55), size: size * 0.5),
      );

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: url.isEmpty
            ? _placeholder()
            : Image.network(
                _src,
                width: size,
                height: size,
                cacheWidth: (size * 2).round(),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _placeholder(),
                loadingBuilder: (_, child, progress) => progress == null
                    ? child
                    : SizedBox(
                        width: size,
                        height: size,
                        child: const Center(
                            child: CircularProgressIndicator(strokeWidth: 2))),
              ),
      );
}

Future<Uint8List?> pickPhoto() async {
  try {
    final x = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 900,
        maxHeight: 900,
        imageQuality: 80);
    if (x == null) return null;
    return await x.readAsBytes();
  } catch (_) {
    return null;
  }
}

Widget photoPreview(Uint8List? bytes, String url, double size) => bytes != null
    ? ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(bytes, width: size, height: size, fit: BoxFit.cover))
    : FoodImage(url, size: size);

Future<String> uploadPhotoIfNeeded(Uint8List? bytes, String currentUrl) async {
  if (bytes == null) return currentUrl;
  final r = await Api.map('uploadImage',
      {'data': base64Encode(bytes), 'mime': 'image/jpeg'},
      const Duration(seconds: 120));
  return '${r['url']}';
}

String payGroup(String p) => switch (p) {
      'Cash' => 'Cash',
      'MTN' => 'MTN',
      'Airtel' => 'Airtel',
      'Wallet' => 'Wallet',
      _ => 'Other',
    };

IconData payGroupIcon(String g) => switch (g) {
      'Cash' => Icons.payments_outlined,
      'MTN' || 'Airtel' => Icons.phone_android,
      'Wallet' => Icons.account_balance_wallet_outlined,
      'Other' => Icons.more_horiz,
      _ => Icons.list_alt,
    };

// ---- order display helpers shared by the staff screens

Color statusColor(String s) => switch (s) {
      'Pending' => Colors.orange,
      'Approved' => Colors.blue,
      'Cooking' => Colors.deepOrange,
      'Ready' => Colors.teal,
      'Assigned' || 'Serving' => Colors.indigo,
      'Completed' => Colors.green,
      _ => Colors.red,
    };

String orderWhere(Map<String, dynamic> o) => switch ('${o['mode']}') {
      'Indoor' => 'Indoor • Table ${o['table']}',
      'Delivery' => 'Delivery • ${o['stationName']}',
      _ => 'Takeaway',
    };

class OrderCard extends StatelessWidget {
  final Map<String, dynamic> o;
  final List<Widget> actions;
  final bool showMoney;
  const OrderCard(this.o, {this.actions = const [], this.showMoney = true, super.key});

  @override
  Widget build(BuildContext context) {
    final status = '${o['status']}';
    final color = statusColor(status);
    final reason = '${o['rejectReason']}';
    final note = '${o['note']}';
    final assigned = '${o['assignedToName']}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('#${o['id']}',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12)),
                  child: Text(status,
                      style: TextStyle(color: color, fontWeight: FontWeight.w600)),
                ),
                const Spacer(),
                if (showMoney)
                  Text(ugx(o['total'] as num),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 4),
            Text(orderWhere(o), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            for (final l in (o['lines'] as List)) Text('• $l'),
            if (note.isNotEmpty) Text('Note: $note'),
            const SizedBox(height: 6),
            Text('${o['customer']} • ${o['phone']}'),
            Text('${o['payment']} • ${o['paymentStatus']} • ${o['createdAt']}',
                style: const TextStyle(fontSize: 12, color: kMuted)),
            if (assigned.isNotEmpty) Text('Handled by: $assigned'),
            if ('${o['deliveryNote'] ?? ''}'.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: kWarnBg, borderRadius: BorderRadius.circular(12)),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.assignment_outlined, size: 18, color: kGold),
                    const SizedBox(width: 8),
                    Expanded(child: Text('Instructions: ${o['deliveryNote']}')),
                  ],
                ),
              ),
            if ('${o['code'] ?? ''}'.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                    'Delivery code: ${o['code']}${o['codeUsed'] == true ? ' (used)' : ''}',
                    style: const TextStyle(color: kGold, fontWeight: FontWeight.w600)),
              ),
            if (o['amountCollected'] is num && (o['amountCollected'] as num) > 0)
              Text('Collected on delivery: ${ugx(o['amountCollected'] as num)}',
                  style: const TextStyle(color: Color(0xFF4CC38A))),
            if ('${o['paymentStatus']}' == 'With waiter')
              Text('Cash with ${o['cashByName']} - not handed in yet',
                  style: const TextStyle(color: Color(0xFFFF9F43), fontWeight: FontWeight.w600)),
            if (isMomo('${o['payment']}') && '${o['txnId'] ?? ''}'.isNotEmpty)
              Text('${payLabel('${o['payment']}')} ID ${o['txnId']} from ${o['payPhone']}',
                  style: const TextStyle(color: kGold, fontSize: 12)),
            if ('${o['createdByName'] ?? ''}'.isNotEmpty)
              Text('Taken by ${o['createdByName']}', style: const TextStyle(color: kMuted, fontSize: 12)),
            if ((o['tokensUsed'] ?? 0) is num && (o['tokensUsed'] as num) > 0)
              Text('Paid with ${o['tokensUsed']} tokens', style: const TextStyle(color: kGold, fontSize: 12)),
            if (reason.isNotEmpty)
              Text('Reason: $reason', style: const TextStyle(color: Colors.red)),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}

// ================================================================== CUSTOMER

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final store = RestaurantStore.instance;

  @override
  void initState() {
    super.initState();
    store.loadMenu();
  }

  void _go(String mode) {
    store.beginOrder(mode);
    final Widget next = switch (mode) {
      'Indoor' => const TablePickerScreen(),
      'Delivery' => const StationPickerScreen(),
      _ => const MenuScreen(),
    };
    Navigator.push(context, MaterialPageRoute(builder: (_) => next));
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 700;
    return AnimatedBuilder(
      animation: Listenable.merge([store, CustomerStore.instance]),
      builder: (_, __) {
        final menu = store.menu;
        final picks = <Dish>[
          if (menu != null)
            ...menu.dishes.where((d) => d.imageUrl.isNotEmpty && d.available)
        ];
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            actions: [
              TextButton.icon(
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const LoginScreen())),
                icon: const Icon(Icons.badge_outlined),
                label: const Text('Staff'),
              ),
            ],
          ),
          body: Narrow(
            width: 900,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
              children: [
                if (!Api.configured)
                  Card(
                    color: kWarnBg,
                    child: const ListTile(
                      leading: Icon(Icons.info_outline),
                      title: Text('Demo mode'),
                      subtitle: Text(
                          'Not connected to Google Sheets yet. Orders are not saved.'),
                    ),
                  ),
                const SizedBox(height: 4),
                const BrandHeader(),
                const SizedBox(height: 26),
                Text('How would you like to order?',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 14),
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: wide ? 4 : 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.05,
                  children: [
                    OptionCard(Icons.restaurant, 'Indoor', 'Eat at the restaurant',
                        () => _go('Indoor')),
                    OptionCard(Icons.takeout_dining, 'Takeaway', 'Collect your food',
                        () => _go('Takeaway')),
                    OptionCard(Icons.delivery_dining, 'Delivery',
                        'To a pick-up station', () => _go('Delivery')),
                    OptionCard(
                        Icons.receipt_long,
                        'Follow-up',
                        'Check your order',
                        () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const OrderTrackingScreen()))),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  alignment: WrapAlignment.center,
                  children: [
                    ActionChip(
                      avatar: const Icon(Icons.event, size: 18, color: kGold),
                      label: const Text('Events'),
                      onPressed: () => Navigator.push(
                          context, MaterialPageRoute(builder: (_) => const EventsScreen())),
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.card_membership, size: 18, color: kGold),
                      label: const Text('Subscriptions'),
                      onPressed: () => Navigator.push(
                          context, MaterialPageRoute(builder: (_) => const SubscriptionsScreen())),
                    ),
                    ActionChip(
                      avatar: Icon(CustomerStore.instance.signedIn ? Icons.account_circle : Icons.login,
                          size: 18, color: kGold),
                      label: Text(CustomerStore.instance.signedIn
                          ? (CustomerStore.instance.name.isEmpty ? 'My profile' : CustomerStore.instance.name)
                          : 'Sign in / Profile'),
                      onPressed: () async {
                        if (await requireCustomer(context) && context.mounted) {
                          Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const CustomerProfileScreen()));
                        }
                      },
                    ),
                  ],
                ),
                if (picks.isNotEmpty) ...[
                  const SizedBox(height: 26),
                  Text("Chef's picks", style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 214,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final d in picks.take(10))
                          Container(
                            width: 150,
                            margin: const EdgeInsets.only(right: 12),
                            decoration: BoxDecoration(
                              color: kSurface.withValues(alpha: 0.85),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: kGold.withValues(alpha: 0.25)),
                            ),
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                FoodImage(d.imageUrl, size: 134),
                                const SizedBox(height: 6),
                                Text(d.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w600)),
                                Text(ugx(d.price),
                                    style: const TextStyle(color: kGold, fontSize: 12)),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                ContactSection(menu?.info ?? const <String, dynamic>{}),
              ],
            ),
          ),
        );
      },
    );
  }
}

class OptionCard extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  const OptionCard(this.icon, this.title, this.subtitle, this.onTap, {super.key});
  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  kSurface.withValues(alpha: 0.88),
                  kPanelHi.withValues(alpha: 0.88),
                ],
              ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: kGold.withValues(alpha: 0.30)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: kAccent.withValues(alpha: 0.20),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, size: 30, color: kGold),
                  ),
                  const SizedBox(height: 10),
                  Text(title,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  Text(subtitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12, color: kMuted)),
                ],
              ),
            ),
          ),
        ),
      );
}

/// Shared loading / error states for the screens that need the menu data.
Widget menuStateBody(RestaurantStore store, Widget Function(MenuBundle m) ready) {
  final m = store.menu;
  if (m == null && store.menuLoading) {
    return const Center(child: CircularProgressIndicator());
  }
  if (m == null) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            Text(store.menuError ?? 'Could not load the menu.',
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: store.loadMenu, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
  return ready(m);
}

class TablePickerScreen extends StatelessWidget {
  const TablePickerScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final store = RestaurantStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (_, __) => Scaffold(
        appBar: AppBar(title: const Text('Indoor')),
        body: menuStateBody(
          store,
          (m) => Narrow(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Which table are you at?',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (var n = 1; n <= m.tableCount; n++)
                      SizedBox(
                        width: 64,
                        height: 64,
                        child: FilledButton.tonal(
                          style: FilledButton.styleFrom(padding: EdgeInsets.zero),
                          onPressed: () async {
                            var code = '';
                            if (m.tableCodesRequired) {
                              final c = await codeDialog(context, 'Table $n',
                                  message: 'Type the code that is written on your table.',
                                  digits: true,
                                  action: 'Confirm table');
                              if (c == null || c.isEmpty || !context.mounted) return;
                              final ok = await guarded(
                                  context, () => Api.call('verifyTableCode', {'table': n, 'code': c}));
                              if (!ok || !context.mounted) return;
                              code = c;
                            }
                            store.update(() {
                              store.tableNo = n;
                              store.tableCode = code;
                            });
                            Navigator.push(context,
                                MaterialPageRoute(builder: (_) => const MenuScreen()));
                          },
                          child: Text('$n',
                              style: const TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.bold)),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class StationPickerScreen extends StatelessWidget {
  const StationPickerScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final store = RestaurantStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (_, __) => Scaffold(
        appBar: AppBar(title: const Text('Delivery')),
        body: menuStateBody(
          store,
          (m) => Narrow(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Choose your pick-up station',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                const Text('Each station has its own delivery fee, added to your bill.'),
                const SizedBox(height: 8),
                if (m.stations.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No pick-up stations are available right now. Please call the restaurant.'),
                  ),
                for (final s in m.stations)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.location_on),
                      title: Text(s.name),
                      subtitle: Text('Delivery fee ${ugx(s.fee)}'),
                      trailing: const Icon(Icons.arrow_forward),
                      onTap: () {
                        store.update(() => store.station = s);
                        Navigator.push(context,
                            MaterialPageRoute(builder: (_) => const MenuScreen()));
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ItemTile extends StatelessWidget {
  final String imageUrl, name, description, extra;
  final double price;
  final bool available;
  final int qty;
  final VoidCallback onAdd, onRemove;
  const ItemTile({
    required this.imageUrl,
    required this.name,
    required this.description,
    required this.extra,
    required this.price,
    required this.available,
    required this.qty,
    required this.onAdd,
    required this.onRemove,
    super.key,
  });

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              FoodImage(imageUrl, size: 76),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                    if (description.isNotEmpty)
                      Text(description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: kMuted)),
                    if (extra.isNotEmpty)
                      Text(extra,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 4),
                    Text(available ? ugx(price) : '${ugx(price)} • Sold out',
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: available ? kGold : Colors.grey)),
                  ],
                ),
              ),
              if (available)
                qty == 0
                    ? IconButton.filledTonal(
                        onPressed: onAdd, icon: const Icon(Icons.add))
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                              onPressed: onRemove,
                              icon: const Icon(Icons.remove_circle_outline)),
                          Text('$qty',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 16)),
                          IconButton(
                              onPressed: onAdd,
                              icon: const Icon(Icons.add_circle_outline)),
                        ],
                      ),
            ],
          ),
        ),
      );
}

class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key});
  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  String category = 'All';

  @override
  Widget build(BuildContext context) {
    final store = RestaurantStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (_, __) => MenuBackdropFrame(
        store: store,
        category: category,
        child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text('Menu • ${store.whereLabel}')),
        body: menuStateBody(store, (m) {
          final cats = [
            'All',
            if (m.combos.isNotEmpty) 'Combos',
            ...{...m.dishes.map((d) => d.category)},
          ];
          if (!cats.contains(category)) category = 'All';
          final showCombos = category == 'All' || category == 'Combos';
          final dishes = category == 'Combos'
              ? <Dish>[]
              : category == 'All'
                  ? m.dishes
                  : m.dishes.where((d) => d.category == category).toList();
          return Narrow(
            child: Column(
              children: [
                SizedBox(
                  height: 56,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(8),
                    children: [
                      for (final c in cats)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(c),
                            selected: category == c,
                            onSelected: (_) => setState(() => category = c),
                          ),
                        )
                    ],
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: store.loadMenu,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
                      children: [
                        if (showCombos)
                          for (final c in m.combos)
                            ItemTile(
                              imageUrl: c.imageUrl,
                              name: '${c.name} (combo)',
                              description: c.description,
                              extra: 'Includes: ${c.includes}',
                              price: c.price,
                              available: c.available,
                              qty: store.qtyOf('combo', c.id),
                              onAdd: () => store.addLine('combo', c.id, c.name, c.price, c.imageUrl),
                              onRemove: () => store.removeLine('combo', c.id),
                            ),
                        for (final d in dishes)
                          ItemTile(
                            imageUrl: d.imageUrl,
                            name: d.name,
                            description: d.description,
                            extra: d.tokenPrice > 0 ? 'Or pay ${d.tokenPrice} tokens' : '',
                            price: d.price,
                            available: d.available,
                            qty: store.qtyOf('dish', d.id),
                            onAdd: () => store.addLine('dish', d.id, d.name, d.price, d.imageUrl,
                                tokenPrice: d.tokenPrice),
                            onRemove: () => store.removeLine('dish', d.id),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
        bottomNavigationBar: store.cart.isEmpty
            ? null
            : Material(
                elevation: 8,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Your bill • ${store.itemCount} item(s)',
                                  style: const TextStyle(fontSize: 12)),
                              Text(ugx(store.total),
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(fontWeight: FontWeight.bold)),
                              if (store.deliveryFee > 0)
                                Text('includes ${ugx(store.deliveryFee)} delivery',
                                    style: const TextStyle(fontSize: 11)),
                            ],
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const CheckoutScreen())),
                          icon: const Icon(Icons.shopping_bag),
                          label: const Text('Order'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
      ),
    );
  }
}

class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});
  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  final store = RestaurantStore.instance;
  late final TextEditingController _name =
      TextEditingController(
          text: store.customerName.isNotEmpty ? store.customerName : CustomerStore.instance.name);
  late final TextEditingController _phone =
      TextEditingController(
          text: store.phone.isNotEmpty ? store.phone : CustomerStore.instance.phone);
  late final TextEditingController _note = TextEditingController(text: store.note);
  bool _busy = false;

  void _say(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _submit() async {
    final digits = _phone.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (store.orderMode != 'Indoor' && _name.text.trim().isEmpty) {
      _say('Please enter your name.');
      return;
    }
    if (digits.length < 9) {
      _say('Enter your phone number. The manager will call you to confirm.');
      return;
    }
    if (store.paymentMethod.isEmpty) {
      _say('Choose how you will pay.');
      return;
    }
    store.customerName = _name.text.trim();
    store.phone = _phone.text.trim();
    store.note = _note.text.trim();

    setState(() => _busy = true);
    int? id;
    final ok = await guarded(context, () async {
      id = await store.submitOrder();
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok && id != null) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => OrderTrackingScreen(
              orderId: id, phone: store.phone, justPlaced: true),
        ),
        (r) => r.isFirst,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (_, __) => Scaffold(
        appBar: AppBar(title: const Text('Your Order')),
        body: store.cart.isEmpty
            ? const Center(child: Text('Nothing selected yet.'))
            : Narrow(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Card(
                      color: kPanelHi,
                      child: ListTile(
                        leading: Icon(store.orderMode == 'Indoor'
                            ? Icons.restaurant
                            : store.orderMode == 'Delivery'
                                ? Icons.delivery_dining
                                : Icons.takeout_dining),
                        title: Text(store.whereLabel),
                        subtitle: Text(store.orderMode),
                      ),
                    ),
                    for (final x in store.cart)
                      Card(
                        child: ListTile(
                          leading: FoodImage(x.imageUrl, size: 48),
                          title: Text(x.name),
                          subtitle: Text('${ugx(x.price)} × ${x.qty} = ${ugx(x.total)}'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                  onPressed: () => store.removeLine(x.kind, x.id),
                                  icon: const Icon(Icons.remove_circle_outline)),
                              IconButton(
                                  onPressed: () => store.addLine(
                                      x.kind, x.id, x.name, x.price, x.imageUrl,
                                      tokenPrice: x.tokenPrice),
                                  icon: const Icon(Icons.add_circle_outline)),
                            ],
                          ),
                        ),
                      ),
                    const Divider(),
                    Text('Food: ${ugx(store.subtotal)}'),
                    if (store.orderMode == 'Delivery')
                      Text('Delivery (${store.station?.name ?? ''}): ${ugx(store.deliveryFee)}'),
                    Text('Total bill: ${ugx(store.total)}',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                          labelText: store.orderMode == 'Indoor'
                              ? 'Your name (optional)'
                              : 'Your name',
                          prefixIcon: const Icon(Icons.person)),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                          labelText: 'Phone number',
                          helperText: 'The manager will call you to confirm your order',
                          prefixIcon: Icon(Icons.phone)),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _note,
                      decoration: const InputDecoration(
                          labelText: 'Note (optional)',
                          prefixIcon: Icon(Icons.edit_note)),
                    ),
                    const SizedBox(height: 14),
                    const Text('How will you pay?',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final p in store.paymentOptions)
                          ChoiceChip(
                            label: Text(payLabel(p)),
                            selected: store.paymentMethod == p,
                            onSelected: (_) =>
                                store.update(() => store.paymentMethod = p),
                          ),
                      ],
                    ),
                    if (store.paymentMethod == 'Wallet')
                      Text('Wallet balance: ${ugx(CustomerStore.instance.wallet)}',
                          style: TextStyle(
                              color: CustomerStore.instance.wallet >= store.total
                                  ? kGold
                                  : const Color(0xFFFF6B5E))),
                    if (store.paymentMethod == 'Tokens')
                      Text('This order costs ${store.tokensNeeded} tokens. You have ${CustomerStore.instance.tokens}.',
                          style: const TextStyle(color: kGold)),
                    if (isMomo(store.paymentMethod))
                      const Text(
                          'After you place the order you will see the number to pay and where to send your transaction ID.',
                          style: TextStyle(color: kMuted, fontSize: 12)),
                    if (!CustomerStore.instance.signedIn)
                      TextButton.icon(
                        onPressed: () async {
                          if (await requireCustomer(context) && mounted) setState(() {});
                        },
                        icon: const Icon(Icons.account_circle_outlined),
                        label: const Text('Sign in to use your wallet or tokens'),
                      ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: store.whatsappOptIn,
                      onChanged: (v) =>
                          store.update(() => store.whatsappOptIn = v ?? false),
                      title: const Text(
                          'Send me offers and promotions on WhatsApp (optional)'),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Place order'),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
      ),
    );
  }
}

class OrderTrackingScreen extends StatefulWidget {
  final int? orderId;
  final String? phone;
  final bool justPlaced;
  const OrderTrackingScreen(
      {this.orderId, this.phone, this.justPlaced = false, super.key});
  @override
  State<OrderTrackingScreen> createState() => _OrderTrackingScreenState();
}

class _OrderTrackingScreenState extends State<OrderTrackingScreen> {
  late final TextEditingController _id = TextEditingController(
      text: (widget.orderId ?? 0) > 0 ? '${widget.orderId}' : '');
  late final TextEditingController _phone =
      TextEditingController(text: widget.phone ?? '');
  Map<String, dynamic>? _result;
  String? _error;
  bool _loading = false;
  Timer? _timer;

  static const _progress = {
    'Pending': 0.1,
    'Approved': 0.3,
    'Cooking': 0.5,
    'Ready': 0.7,
    'Assigned': 0.85,
    'Serving': 0.93,
    'Completed': 1.0,
  };

  @override
  void initState() {
    super.initState();
    Notify.askPermission();
    if ((widget.orderId ?? 0) > 0 && (widget.phone ?? '').isNotEmpty) {
      _check();
    }
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_result != null && mounted && !_loading) _check(silent: true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check({bool silent = false}) async {
    final id = int.tryParse(_id.text.trim());
    if (id == null) {
      setState(() => _error = 'Enter your order number.');
      return;
    }
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final r = await Api.map(
          'trackOrder', {'orderId': id, 'phone': _phone.text.trim()});
      if (!mounted) return;
      final before = _result == null ? null : '${_result!['status']}';
      if (before != null && before != '${r['status']}') {
        Notify.show(900000 + id, 'Order #$id - ${r['status']}', _statusText(r));
      }
      setState(() {
        _result = r;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || silent) return;
      setState(() {
        _result = null;
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _cancel() async {
    final yes = await confirmDialog(
        context, 'Cancel order?', 'Do you want to cancel this order?',
        action: 'Cancel order');
    if (!yes || !mounted) return;
    final ok = await guarded(
        context,
        () => Api.call('cancelMyOrder',
            {'orderId': int.tryParse(_id.text.trim()), 'phone': _phone.text.trim()}),
        success: 'Order cancelled');
    if (ok) await _check();
  }

  String _statusText(Map<String, dynamic> r) {
    switch ('${r['status']}') {
      case 'Pending':
        return 'Waiting for the manager to call you and confirm';
      case 'Approved':
        return 'Confirmed - sent to the kitchen';
      case 'Cooking':
        return 'Your food is being cooked';
      case 'Ready':
        return 'Your food is ready';
      case 'Assigned':
        final who = '${r['assignedToName']}';
        return switch ('${r['mode']}') {
          'Delivery' => 'On its way with $who',
          'Indoor' => '$who is bringing it to your table',
          _ => '$who will hand it to you',
        };
      case 'Serving':
        return 'Your food has been served. Press Receive food below.';
      case 'Completed':
        return switch ('${r['mode']}') {
          'Delivery' => 'Delivered. Enjoy your meal!',
          'Indoor' => 'Served. Enjoy your meal!',
          _ => 'Collected. Enjoy your meal!',
        };
      case 'Rejected':
        return 'Sorry, we could not accept this order';
      case 'Cancelled':
        return 'This order was cancelled';
      case 'Failed':
        return 'The delivery could not be completed. Please call us.';
      default:
        return '${r['status']}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final demoOrder = widget.justPlaced && widget.orderId == 0;
    final r = _result;
    final status = r == null ? '' : '${r['status']}';
    final bad = ['Rejected', 'Cancelled', 'Failed'].contains(status);
    return Scaffold(
      appBar: AppBar(title: const Text('Follow-up')),
      body: Narrow(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (demoOrder)
              Card(
                color: kWarnBg,
                child: const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('Demo order'),
                  subtitle: Text(
                      'The app is not connected to Google Sheets, so this order was not saved.'),
                ),
              ),
            if (widget.justPlaced && !demoOrder)
              Card(
                color: kOkBg,
                child: ListTile(
                  leading: const Icon(Icons.check_circle, color: Colors.green),
                  title: Text('Order #${widget.orderId} received'),
                  subtitle: Text(
                      'The manager will call ${widget.phone ?? 'you'} to confirm. Keep your order number.'),
                ),
              ),
            if (!demoOrder) ...[
              TextField(
                controller: _id,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Order number'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                    labelText: 'Phone number used for the order'),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _loading ? null : _check,
                icon: _loading
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.search),
                label: const Text('Check status'),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (r != null)
              Card(
                margin: const EdgeInsets.only(top: 16),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Order #${r['id']}',
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 4),
                      Text(status,
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: statusColor(status))),
                      const SizedBox(height: 4),
                      Text(_statusText(r)),
                      if (bad && '${r['rejectReason']}'.isNotEmpty)
                        Text('Reason: ${r['rejectReason']}',
                            style: const TextStyle(color: Colors.red)),
                      const SizedBox(height: 10),
                      if (!bad && _progress.containsKey(status))
                        LinearProgressIndicator(value: _progress[status]),
                      const SizedBox(height: 10),
                      Text(orderWhere({
                        'mode': r['mode'],
                        'table': r['table'],
                        'stationName': r['stationName']
                      })),
                      Text('Bill: ${ugx(r['total'] as num)}'),
                      Text('${payLabel('${r['paymentMethod']}')} • ${r['paymentStatus']}'),
                      TrackingExtras(r: r, phone: _phone.text.trim(), onChanged: _check),
                      Text('Last update: ${r['updatedAt']}',
                          style: const TextStyle(fontSize: 12, color: kMuted)),
                      if (status == 'Pending')
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: OutlinedButton(
                              onPressed: _cancel,
                              child: const Text('Cancel this order')),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ================================================================== STAFF ACCESS

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  bool _hide = true;

  /// Asks the user to pick their own password. Returns false if they gave up.
  Future<bool> _forceNewPassword(String oldPassword) async {
    while (mounted) {
      final v = await formDialog(
        context,
        'Choose your own password',
        const [
          FieldSpec('a', 'New password (6 or more characters)', obscure: true),
          FieldSpec('b', 'Repeat new password', obscure: true),
        ],
      );
      if (v == null || !mounted) return false;
      if (v['a'] != v['b']) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('The passwords do not match.')));
        continue;
      }
      final ok = await guarded(
          context,
          () => Api.call('changePassword',
              {'oldPassword': oldPassword, 'newPassword': v['a']}),
          success: 'Password changed');
      if (ok) return true;
    }
    return false;
  }

  Future<void> _login() async {
    final store = RestaurantStore.instance;
    final password = _pass.text;
    setState(() => _busy = true);
    var mustChange = false;
    final ok = await guarded(context, () async {
      mustChange = await store.signIn(_user.text, password);
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) return;
    if (mustChange) {
      final changed = await _forceNewPassword(password);
      if (!changed) {
        await store.signOut();
        return;
      }
    }
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => StaffDashboard(role: store.role)),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Staff Login')),
        body: Narrow(
          width: 480,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!Api.configured)
                Card(
                  color: kWarnBg,
                  child: const ListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text('Not connected'),
                    subtitle: Text(
                        'Staff login needs the Google Sheets connection (see README).'),
                  ),
                ),
              const BrandHeader(compact: true),
              const SizedBox(height: 18),
              const Text(
                  'Administrator, manager, kitchen, waiter and delivery staff sign in here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kMuted)),
              const SizedBox(height: 16),
              TextField(
                controller: _user,
                autocorrect: false,
                decoration: const InputDecoration(
                    labelText: 'Username', prefixIcon: Icon(Icons.person)),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pass,
                obscureText: _hide,
                onSubmitted: (_) => _busy ? null : _login(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(
                    icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _hide = !_hide),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _login,
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Sign in'),
              ),
              TextButton(
                onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => ForgotPasswordScreen(username: _user.text.trim()))),
                child: const Text('Forgot password?'),
              ),
            ],
          ),
        ),
      );
}

class ForgotPasswordScreen extends StatefulWidget {
  final String username;
  const ForgotPasswordScreen({this.username = '', super.key});
  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  late final TextEditingController _user =
      TextEditingController(text: widget.username);
  final _code = TextEditingController();
  final _new = TextEditingController();
  bool _sent = false;
  bool _busy = false;
  String _message = '';

  Future<void> _request() async {
    setState(() => _busy = true);
    String msg = '';
    final ok = await guarded(context, () async {
      final r = await Api.map('requestReset', {'username': _user.text.trim()});
      msg = '${r['message']}';
    });
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _sent = true;
        _message = msg;
      }
    });
  }

  Future<void> _reset() async {
    setState(() => _busy = true);
    final ok = await guarded(
        context,
        () => Api.call('resetPassword', {
              'username': _user.text.trim(),
              'code': _code.text.trim(),
              'newPassword': _new.text,
            }),
        success: 'Password changed. You can sign in now.');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Forgot password')),
        body: Narrow(
          width: 480,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                  'Enter your username. If an email address is saved for you, we send a 6-digit code to it. '
                  'If you have no email saved, ask the administrator to reset your password.'),
              const SizedBox(height: 12),
              TextField(
                controller: _user,
                enabled: !_sent,
                autocorrect: false,
                decoration: const InputDecoration(
                    labelText: 'Username', prefixIcon: Icon(Icons.person)),
              ),
              const SizedBox(height: 12),
              if (!_sent)
                FilledButton(
                    onPressed: _busy ? null : _request,
                    child: const Text('Send code')),
              if (_sent) ...[
                Card(
                    color: kOkBg,
                    child: Padding(
                        padding: const EdgeInsets.all(12), child: Text(_message))),
                const SizedBox(height: 12),
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: '6-digit code', prefixIcon: Icon(Icons.pin)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _new,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'New password (6 or more characters)',
                      prefixIcon: Icon(Icons.lock)),
                ),
                const SizedBox(height: 12),
                FilledButton(
                    onPressed: _busy ? null : _reset,
                    child: const Text('Set new password')),
              ],
            ],
          ),
        ),
      );
}

class StaffDashboard extends StatelessWidget {
  final UserRole role;
  const StaffDashboard({required this.role, super.key});

  List<DashboardTile> get tiles {
    switch (role) {
      case UserRole.admin:
      case UserRole.manager:
        final admin = role == UserRole.admin;
        return [
          DashboardTile('Orders', Icons.receipt_long, const ManagerOrdersScreen()),
          DashboardTile('Payments', Icons.account_balance_wallet_outlined, const PaymentsDeskScreen()),
          DashboardTile("Today's Team", Icons.groups_2_outlined, const AttendanceScreen()),
          DashboardTile('Staff Activity', Icons.insights, const WorkerStatsScreen()),
          DashboardTile('Record Order', Icons.edit_note, const RecordOrderScreen()),
          DashboardTile('Check a Code', Icons.fact_check_outlined, const CheckCodeScreen()),
          DashboardTile('Menu & Combos', Icons.restaurant_menu, const MenuAdminScreen()),
          DashboardTile('Menu Backgrounds', Icons.slideshow, const CategoryPicturesScreen()),
          DashboardTile('Stations & Tables', Icons.location_on, const StationsScreen()),
          DashboardTile('Table Codes', Icons.pin_outlined, const TableCodesScreen()),
          DashboardTile('Completed Orders', Icons.task_alt, const CompletedOrdersScreen()),
          DashboardTile('Statistics', Icons.bar_chart, const StatsScreen()),
          DashboardTile('Inventory & Stock', Icons.inventory_2, const StockScreen()),
          DashboardTile('Items Used', Icons.outbox, const UseStockScreen()),
          DashboardTile('Kitchen Requests', Icons.shopping_basket_outlined, const StockRequestsScreen()),
          DashboardTile('Events', Icons.event, const EventsAdminScreen()),
          DashboardTile('Subscriptions', Icons.card_membership, const PackagesAdminScreen()),
          DashboardTile('Customers', Icons.people_alt_outlined, const CustomersScreen()),
          DashboardTile('Background Pictures', Icons.photo_library, const BackgroundsScreen()),
          if (admin) ...[
            DashboardTile('Restaurant Settings', Icons.tune, const ContactSettingsScreen()),
            DashboardTile('Users', Icons.manage_accounts, const UserManagementScreen()),
            DashboardTile('Promotions List', Icons.campaign, const NotificationsScreen()),
            DashboardTile('Audit Trail', Icons.security, const AuditScreen()),
            DashboardTile('Settings', Icons.settings, const SettingsScreen()),
          ],
        ];
      case UserRole.kitchen:
        return [
          DashboardTile('Kitchen', Icons.soup_kitchen, const KitchenScreen()),
          DashboardTile('Items Used', Icons.outbox, const UseStockScreen()),
          DashboardTile('Request Items', Icons.add_shopping_cart, const KitchenRequestScreen()),
        ];
      case UserRole.waiter:
        return [
          DashboardTile('My Orders', Icons.room_service, const WaiterDeskScreen()),
          DashboardTile('Take an Order', Icons.edit_note, const RecordOrderScreen()),
          DashboardTile('Check a Code', Icons.fact_check_outlined, const CheckCodeScreen()),
        ];
      case UserRole.delivery:
        return [DashboardTile('My Deliveries', Icons.delivery_dining, const DeliveryJobsScreen())];
      case UserRole.customer:
        return [];
    }
  }

  Future<void> _changePassword(BuildContext context) async {
    final v = await formDialog(
      context,
      'Change password',
      const [
        FieldSpec('old', 'Current password', obscure: true),
        FieldSpec('a', 'New password (6 or more characters)', obscure: true),
        FieldSpec('b', 'Repeat new password', obscure: true),
      ],
      action: 'Change',
    );
    if (v == null || !context.mounted) return;
    if (v['a'] != v['b']) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('The passwords do not match.')));
      return;
    }
    await guarded(
        context,
        () => Api.call('changePassword',
            {'oldPassword': v['old'], 'newPassword': v['a']}),
        success: 'Password changed');
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = (width ~/ 170).clamp(2, 4);
    final store = RestaurantStore.instance;
    return NotificationWatcher(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('KANYATSI'),
          actions: [
            const NotificationBell(),
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'pw') {
                  await _changePassword(context);
                } else {
                  await RestaurantStore.instance.signOut();
                  kUnread.value = 0;
                  if (context.mounted) {
                    Navigator.of(context).popUntil((r) => r.isFirst);
                  }
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'pw', child: Text('Change password')),
                PopupMenuItem(value: 'out', child: Text('Sign out')),
              ],
            ),
          ],
        ),
        body: Narrow(
          width: 900,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
            children: [
              GlassCard(
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                          color: kAccent, borderRadius: BorderRadius.circular(16)),
                      child: Image.asset('assets/logo.png'),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Welcome, ${store.staffName}',
                              style: Theme.of(context).textTheme.titleMedium),
                          Text(role.label,
                              style: const TextStyle(color: kGold, fontSize: 13)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: columns,
                childAspectRatio: 1.08,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                children: [
                  for (final t in tiles)
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(22),
                        onTap: () => Navigator.push(
                            context, MaterialPageRoute(builder: (_) => t.screen)),
                        child: Ink(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                kSurface.withValues(alpha: 0.90),
                                kPanelHi.withValues(alpha: 0.90),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(color: kGold.withValues(alpha: 0.28)),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: kAccent.withValues(alpha: 0.20),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(t.icon, size: 28, color: kGold),
                                ),
                                const SizedBox(height: 10),
                                Text(t.title,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DashboardTile {
  final String title;
  final IconData icon;
  final Widget screen;
  DashboardTile(this.title, this.icon, this.screen);
}

// ================================================================== ORDER HANDLING

Future<Rows> loadAllOrders() => Api.list('listOrders');

int countStatus(Rows rows, List<String> statuses) =>
    rows.where((o) => statuses.contains(o['status'])).length;

/// Asks for a reason, then runs [action] (rejectOrder, cancelOrder, failOrder...).
Future<void> reasonAction(BuildContext context, String title, String action,
    int id, Future<void> Function() reload,
    {String success = 'Done'}) async {
  final v = await formDialog(
      context, title, const [FieldSpec('reason', 'Reason')],
      action: 'Confirm');
  if (v == null || !context.mounted) return;
  final ok = await guarded(context,
      () => Api.call(action, {'id': id, 'reason': v['reason']}),
      success: success);
  if (ok) await reload();
}

Future<void> simpleOrderAction(BuildContext context, String action, int id,
    Future<void> Function() reload,
    {String? success}) async {
  final ok = await guarded(context, () => Api.call(action, {'id': id}),
      success: success);
  if (ok) await reload();
}

Future<void> allocateDialog(BuildContext context, Map<String, dynamic> o,
    Future<void> Function() reload) async {
  final needed = o['mode'] == 'Delivery' ? 'delivery' : 'waiter';
  Rows staff = [];
  final ok = await guarded(context, () async {
    final all = await Api.list('listStaff');
    staff = all.where((u) => u['role'] == needed).toList();
  });
  if (!ok || !context.mounted) return;
  if (staff.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'There is no active ${needed == 'delivery' ? 'delivery man' : 'waiter'}. Ask the administrator to add one.')));
    return;
  }
  final chosen = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(needed == 'delivery'
          ? 'Send order #${o['id']} with:'
          : 'Who takes order #${o['id']} (${orderWhere(o)})?'),
      children: [
        for (final u in staff)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, u),
            child: Text('${u['name']}', style: const TextStyle(fontSize: 16)),
          ),
      ],
    ),
  );
  if (chosen == null || !context.mounted) return;
  var note = '';
  if (o['mode'] == 'Delivery') {
    final owes = o['paymentStatus'] != 'Paid' &&
        (o['payment'] == 'Pay on Delivery' || o['payment'] == 'Cash');
    final v = await formDialog(
      context,
      'Instructions for ${chosen['name']}',
      [
        FieldSpec('note', 'What must the delivery man do? (optional)',
            initial: owes ? 'Collect ${ugx(o['total'] as num)} from the customer.' : ''),
      ],
      action: 'Send',
    );
    if (v == null || !context.mounted) return;
    note = v['note'] ?? '';
  }
  final done = await guarded(
      context,
      () => Api.call('allocateOrder', {
            'id': (o['id'] as num).toInt(),
            'staffId': chosen['id'],
            'note': note,
          }),
      success: 'Given to ${chosen['name']}');
  if (done) await reload();
}

class ManagerOrdersScreen extends StatefulWidget {
  const ManagerOrdersScreen({super.key});
  @override
  State<ManagerOrdersScreen> createState() => _ManagerOrdersScreenState();
}

class _ManagerOrdersScreenState extends State<ManagerOrdersScreen> {
  String filter = 'Pending';
  String payFilter = 'All';

  static const filters = {
    'Pending': ['Pending'],
    'In kitchen': ['Approved', 'Cooking'],
    'Ready': ['Ready'],
    'Serving': ['Assigned', 'Serving'],
    'Closed': ['Completed', 'Rejected', 'Cancelled', 'Failed'],
  };

  List<Widget> _actions(BuildContext context, Map<String, dynamic> o,
      Future<void> Function() reload) {
    final id = (o['id'] as num).toInt();
    final status = '${o['status']}';
    final open = ['Pending', 'Approved', 'Cooking', 'Ready', 'Assigned', 'Serving'].contains(status);
    final closedBad = ['Rejected', 'Cancelled', 'Failed'].contains(status);
    return [
      if (status == 'Pending') ...[
        FilledButton(
            onPressed: () => simpleOrderAction(context, 'approveOrder', id, reload,
                success: 'Approved - sent to the kitchen'),
            child: const Text('Approve')),
        OutlinedButton(
            onPressed: () => reasonAction(context, 'Reject order #$id', 'rejectOrder', id, reload,
                success: 'Order rejected'),
            child: const Text('Reject')),
      ],
      if (status == 'Ready')
        FilledButton(
            onPressed: () => allocateDialog(context, o, reload),
            child: const Text('Give to staff')),
      if (status == 'Assigned' || status == 'Serving') ...[
        FilledButton(
            onPressed: () => simpleOrderAction(context, 'completeOrder', id, reload,
                success: 'Order completed'),
            child: const Text('Mark completed')),
        if (status == 'Assigned')
          OutlinedButton(
              onPressed: () => allocateDialog(context, o, reload),
              child: const Text('Change staff')),
      ],
      if (!closedBad && ['With waiter', 'Proof submitted'].contains('${o['paymentStatus']}'))
        FilledButton.tonal(
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const PaymentsDeskScreen())).then((_) => reload()),
            child: Text('${o['paymentStatus']}' == 'With waiter' ? 'Cash hand-in' : 'Check payment')),
      if (!closedBad && !['Paid', 'With waiter', 'Proof submitted', 'Refunded'].contains('${o['paymentStatus']}'))
        OutlinedButton(
            onPressed: () => simpleOrderAction(context, 'markPaid', id, reload,
                success: 'Payment recorded'),
            child: const Text('Mark paid')),
      if (open && status != 'Pending')
        TextButton(
            onPressed: () => reasonAction(context, 'Cancel order #$id', 'cancelOrder', id, reload,
                success: 'Order cancelled'),
            child: const Text('Cancel', style: TextStyle(color: Colors.red))),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return RemoteView<Rows>(
      title: 'Orders',
      actions: [
        IconButton(
          tooltip: 'Payments',
          icon: const Icon(Icons.account_balance_wallet_outlined),
          onPressed: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const PaymentsDeskScreen())),
        ),
      ],
      load: loadAllOrders,
      autoRefresh: const Duration(seconds: 15),
      onLoaded: (prev, cur) {
        if (prev == null) return;
        if (countStatus(cur, ['Pending']) > countStatus(prev, ['Pending']) ||
            countStatus(cur, ['Ready']) > countStatus(prev, ['Ready'])) {
          alertStaff();
        }
      },
      builder: (context, orders, reload) {
        bool inGroup(Map<String, dynamic> o, String g) => g == 'All' || payGroup('${o['payment']}') == g;
        final shown = orders
            .where((o) => filters[filter]!.contains(o['status']) && inGroup(o, payFilter))
            .toList();
        return Narrow(
          width: 900,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final e in filters.entries)
                    ChoiceChip(
                      label: Text('${e.key} (${countStatus(orders, e.value)})'),
                      selected: filter == e.key,
                      onSelected: (_) => setState(() => filter = e.key),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  for (final g in const ['All', 'Cash', 'MTN', 'Airtel', 'Wallet', 'Other'])
                    FilterChip(
                      avatar: Icon(payGroupIcon(g), size: 16),
                      label: Text(
                          '$g (${orders.where((o) => filters[filter]!.contains(o['status']) && inGroup(o, g)).length})'),
                      selected: payFilter == g,
                      onSelected: (_) => setState(() => payFilter = g),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (filter == 'Pending' && shown.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                      'Call each customer on the number shown, then approve or reject.',
                      style: TextStyle(color: kMuted)),
                ),
              if (shown.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(24), child: Text('No orders here.')),
              for (final o in shown) OrderCard(o, actions: _actions(context, o, reload)),
            ],
          ),
        );
      },
    );
  }
}

class KitchenScreen extends StatelessWidget {
  const KitchenScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return RemoteView<Rows>(
      title: 'Kitchen',
      actions: [
        IconButton(
          tooltip: 'Request items',
          icon: const Icon(Icons.add_shopping_cart),
          onPressed: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const KitchenRequestScreen())),
        ),
        IconButton(
          tooltip: 'Items used',
          icon: const Icon(Icons.outbox),
          onPressed: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const UseStockScreen())),
        ),
      ],
      load: () => Api.list('listKitchen'),
      autoRefresh: const Duration(seconds: 15),
      onLoaded: (prev, cur) {
        if (prev == null) return;
        if (countStatus(cur, ['Approved']) > countStatus(prev, ['Approved'])) {
          alertStaff();
        }
      },
      builder: (context, orders, reload) => Narrow(
        width: 900,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (orders.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No orders waiting. New approved orders appear here by themselves.')),
            for (final o in orders)
              OrderCard(
                o,
                showMoney: false,
                actions: [
                  if (o['status'] == 'Approved')
                    FilledButton.icon(
                        onPressed: () => simpleOrderAction(
                            context, 'startCooking', (o['id'] as num).toInt(), reload),
                        icon: const Icon(Icons.local_fire_department),
                        label: const Text('Start cooking')),
                  if (o['status'] == 'Cooking')
                    FilledButton.icon(
                        onPressed: () => simpleOrderAction(
                            context, 'markReady', (o['id'] as num).toInt(), reload,
                            success: 'Marked ready - the manager is notified'),
                        icon: const Icon(Icons.check_circle),
                        label: const Text('Food is ready')),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class MyAssignmentsScreen extends StatelessWidget {
  const MyAssignmentsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final isDelivery = RestaurantStore.instance.role == UserRole.delivery;
    return RemoteView<Rows>(
      title: isDelivery ? 'My Deliveries' : 'My Orders',
      load: () => Api.list('listMine'),
      autoRefresh: const Duration(seconds: 15),
      onLoaded: (prev, cur) {
        if (prev != null && cur.length > prev.length) alertStaff();
      },
      builder: (context, orders, reload) => Narrow(
        width: 900,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (orders.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Nothing assigned to you right now.')),
            for (final o in orders)
              OrderCard(
                o,
                actions: [
                  FilledButton(
                    onPressed: () => simpleOrderAction(
                        context, 'completeOrder', (o['id'] as num).toInt(), reload,
                        success: 'Done'),
                    child: Text(switch ('${o['mode']}') {
                      'Delivery' => 'Mark delivered',
                      'Indoor' => 'Mark served',
                      _ => 'Mark collected',
                    }),
                  ),
                  if (o['mode'] == 'Delivery')
                    OutlinedButton(
                        onPressed: () => reasonAction(
                            context,
                            'Delivery failed',
                            'failOrder',
                            (o['id'] as num).toInt(),
                            reload,
                            success: 'Reported to the manager'),
                        child: const Text('Could not deliver')),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class CompletedOrdersScreen extends StatefulWidget {
  const CompletedOrdersScreen({super.key});
  @override
  State<CompletedOrdersScreen> createState() => _CompletedOrdersScreenState();
}

class _CompletedOrdersScreenState extends State<CompletedOrdersScreen> {
  int days = 1;

  @override
  Widget build(BuildContext context) {
    return RemoteView<Rows>(
      key: ValueKey(days),
      title: 'Completed Orders',
      load: () => Api.list('listCompleted', {'days': days}),
      builder: (context, orders, reload) {
        final total = orders.fold<double>(0, (s, o) => s + (o['total'] as num));
        return Narrow(
          width: 900,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final e in {'Today': 1, 'Last 7 days': 7, 'Last 30 days': 30, 'All': 0}.entries)
                    ChoiceChip(
                      label: Text(e.key),
                      selected: days == e.value,
                      onSelected: (_) => setState(() => days = e.value),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              StatCard('${orders.length} completed order(s)', ugx(total), Icons.task_alt),
              if (orders.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(24), child: Text('No completed orders in this period.')),
              for (final o in orders) OrderCard(o),
            ],
          ),
        );
      },
    );
  }
}

// ================================================================== RECORD ORDER

class RecordOrderScreen extends StatefulWidget {
  const RecordOrderScreen({super.key});
  @override
  State<RecordOrderScreen> createState() => _RecordOrderScreenState();
}

class _RecordOrderScreenState extends State<RecordOrderScreen> {
  MenuBundle? _menu;
  String? _error;
  String mode = 'Indoor';
  int? table;
  int? stationId;
  String payment = 'Cash';
  bool paid = true;
  bool _busy = false;
  final _txn = TextEditingController();
  final _payPhone = TextEditingController();
  Uint8List? _shot;
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _note = TextEditingController();
  final Map<String, int> qty = {}; // 'dish:1' / 'combo:2' -> quantity

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final m = await Api.menu();
      if (!mounted) return;
      setState(() => _menu = m);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.message == kSessionExpired) {
        handleSessionExpired(context);
        return;
      }
      setState(() => _error = e.message);
    }
  }

  void _bump(String key, int by) => setState(() {
        final n = (qty[key] ?? 0) + by;
        if (n <= 0) {
          qty.remove(key);
        } else if (n <= 50) {
          qty[key] = n;
        }
      });

  double get _total {
    final m = _menu;
    if (m == null) return 0;
    var t = 0.0;
    for (final d in m.dishes) {
      t += d.price * (qty['dish:${d.id}'] ?? 0);
    }
    for (final c in m.combos) {
      t += c.price * (qty['combo:${c.id}'] ?? 0);
    }
    if (mode == 'Delivery') {
      for (final s in m.stations) {
        if (s.id == stationId) t += s.fee;
      }
    }
    return t;
  }

  bool get _isWaiter => RestaurantStore.instance.role == UserRole.waiter;

  List<String> get _payments {
    if (_isWaiter) return ['Cash', 'MTN', 'Airtel'];
    return mode == 'Delivery' ? ['Cash', 'MTN', 'Airtel', 'Pay on Delivery'] : ['Cash', 'MTN', 'Airtel'];
  }

  Future<void> _record() async {
    if (qty.isEmpty) {
      _say('Select at least one item.');
      return;
    }
    if (mode == 'Indoor' && table == null) {
      _say('Choose the table.');
      return;
    }
    if (mode == 'Delivery' && stationId == null) {
      _say('Choose the pick-up station.');
      return;
    }
    if (_isWaiter && isMomo(payment) &&
        (_payPhone.text.trim().length < 9 || (_txn.text.trim().length < 6 && _shot == null))) {
      _say('Enter the customer phone number and the transaction ID (or a screenshot).');
      return;
    }
    setState(() => _busy = true);
    var orderId = 0;
    final ok = await guarded(context, () async {
      final r = await Api.map('recordOrder', {
        'mode': mode,
        'table': table,
        'stationId': stationId,
        'items': [
          for (final e in qty.entries)
            {
              'kind': e.key.split(':')[0],
              'id': int.parse(e.key.split(':')[1]),
              'qty': e.value
            }
        ],
        'customer': _name.text.trim(),
        'phone': _phone.text.trim(),
        'note': _note.text.trim(),
        'payment': payment,
        'paid': (_isWaiter && isMomo(payment)) ? false : paid,
        if (_isWaiter && isMomo(payment)) ...{
          'txnId': _txn.text.trim(),
          'payPhone': _payPhone.text.trim(),
          'proofData': _shot == null ? '' : base64Encode(_shot!),
          'proofMime': 'image/jpeg',
        },
      });
      orderId = (r['orderId'] as num).toInt();
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      _say('Order #$orderId recorded and sent to the kitchen.');
      setState(() {
        qty.clear();
        _name.clear();
        _phone.clear();
        _note.clear();
        _txn.clear();
        _payPhone.clear();
        _shot = null;
        table = null;
      });
    }
  }

  void _say(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final m = _menu;
    return Scaffold(
      appBar: AppBar(title: const Text('Record Order')),
      body: m == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_error!),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _load, child: const Text('Try again')),
                    ]),
            )
          : Narrow(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text(
                      'For customers who come to the restaurant and do not use the app. The order goes straight to the kitchen.'),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final x in _isWaiter ? ['Indoor', 'Takeaway'] : ['Indoor', 'Takeaway', 'Delivery'])
                        ChoiceChip(
                          label: Text(x),
                          selected: mode == x,
                          onSelected: (_) => setState(() {
                            mode = x;
                            if (!_payments.contains(payment)) payment = 'Cash';
                          }),
                        ),
                    ],
                  ),
                  if (mode == 'Indoor') ...[
                    const SizedBox(height: 10),
                    const Text('Table'),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (var n = 1; n <= m.tableCount; n++)
                          ChoiceChip(
                            label: Text('$n'),
                            selected: table == n,
                            onSelected: (_) => setState(() => table = n),
                          ),
                      ],
                    ),
                  ],
                  if (mode == 'Delivery') ...[
                    const SizedBox(height: 10),
                    const Text('Pick-up station'),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final s in m.stations)
                          ChoiceChip(
                            label: Text('${s.name} (+${ugx(s.fee)})'),
                            selected: stationId == s.id,
                            onSelected: (_) => setState(() => stationId = s.id),
                          ),
                      ],
                    ),
                  ],
                  const SectionTitle('Items'),
                  for (final c in m.combos)
                    ItemTile(
                      imageUrl: c.imageUrl,
                      name: '${c.name} (combo)',
                      description: c.description,
                      extra: 'Includes: ${c.includes}',
                      price: c.price,
                      available: c.available,
                      qty: qty['combo:${c.id}'] ?? 0,
                      onAdd: () => _bump('combo:${c.id}', 1),
                      onRemove: () => _bump('combo:${c.id}', -1),
                    ),
                  for (final d in m.dishes)
                    ItemTile(
                      imageUrl: d.imageUrl,
                      name: d.name,
                      description: d.description,
                      extra: '',
                      price: d.price,
                      available: d.available,
                      qty: qty['dish:${d.id}'] ?? 0,
                      onAdd: () => _bump('dish:${d.id}', 1),
                      onRemove: () => _bump('dish:${d.id}', -1),
                    ),
                  const SectionTitle('Customer'),
                  TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Name (optional)'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                        labelText: mode == 'Delivery'
                            ? 'Phone number'
                            : 'Phone number (optional)'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _note,
                    decoration: const InputDecoration(labelText: 'Note (optional)'),
                  ),
                  const SectionTitle('Payment'),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final p in _payments)
                        ChoiceChip(
                          label: Text(payLabel(p)),
                          selected: payment == p,
                          onSelected: (_) => setState(() => payment = p),
                        ),
                    ],
                  ),
                  if (!(_isWaiter && isMomo(payment)))
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: paid,
                      onChanged: (v) => setState(() => paid = v),
                      title: Text(_isWaiter ? 'I have collected the cash' : 'Customer has already paid'),
                    ),
                  if (_isWaiter && payment == 'Cash')
                    const Text(
                        'Cash you collect is recorded against your name. Hand it to the manager with the order code.',
                        style: TextStyle(color: kMuted, fontSize: 12)),
                  if (_isWaiter && isMomo(payment)) ...[
                    MomoInstructions(payment),
                    TextField(
                      controller: _payPhone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(labelText: 'Phone number the customer paid from'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _txn,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(labelText: 'Transaction ID'),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        final b = await pickPhotoLarge();
                        if (b != null) setState(() => _shot = b);
                      },
                      icon: Icon(_shot == null ? Icons.add_photo_alternate_outlined : Icons.check_circle),
                      label: Text(_shot == null ? 'Or attach screenshot' : 'Screenshot attached'),
                    ),
                    const Text('The manager checks the payment and approves it. It is not counted as cash you hold.',
                        style: TextStyle(color: kMuted, fontSize: 12)),
                  ],
                  const SizedBox(height: 8),
                  Text('Total bill: ${ugx(_total)}',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _busy ? null : _record,
                    child: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Record order'),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }
}

// ================================================================== MENU & COMBOS

class DishDraft {
  final String name, category, price, description;
  final String imageUrl;
  final Uint8List? bytes;
  final String tokenPrice;
  DishDraft(this.name, this.category, this.price, this.description,
      this.imageUrl, this.bytes,
      {this.tokenPrice = ''});
}

Future<DishDraft?> dishDialog(
    BuildContext context, Dish? d, List<String> categories) {
  final name = TextEditingController(text: d?.name ?? '');
  final category = TextEditingController(text: d?.category ?? '');
  final price = TextEditingController(text: d == null ? '' : '${d.price.round()}');
  final desc = TextEditingController(text: d?.description ?? '');
  final tokenPrice = TextEditingController(
      text: (d == null || d.tokenPrice == 0) ? '' : '${d.tokenPrice}');
  Uint8List? bytes;
  final url = d?.imageUrl ?? '';
  return showDialog<DishDraft>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: Text(d == null ? 'New dish' : 'Edit dish'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: photoPreview(bytes, url, 110)),
              Center(
                child: TextButton.icon(
                  onPressed: () async {
                    final b = await pickPhoto();
                    if (b != null) setS(() => bytes = b);
                  },
                  icon: const Icon(Icons.photo_library),
                  label: Text(bytes == null && url.isEmpty ? 'Add picture' : 'Change picture'),
                ),
              ),
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Dish name')),
              const SizedBox(height: 10),
              TextField(controller: category, decoration: const InputDecoration(labelText: 'Category')),
              if (categories.isNotEmpty)
                Wrap(
                  spacing: 6,
                  children: [
                    for (final c in categories)
                      ActionChip(label: Text(c), onPressed: () => setS(() => category.text = c)),
                  ],
                ),
              const SizedBox(height: 10),
              TextField(
                  controller: price,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Price (UGX)')),
              const SizedBox(height: 10),
              TextField(
                  controller: tokenPrice,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Token price (optional)',
                      helperText: 'How many tokens buy this dish. Empty = cannot be bought with tokens')),
              const SizedBox(height: 10),
              TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(
                ctx,
                DishDraft(name.text.trim(), category.text.trim(), price.text.trim(),
                    desc.text.trim(), url, bytes,
                    tokenPrice: tokenPrice.text.trim())),
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

class ComboDraft {
  final String name, description, price, imageUrl;
  final Map<int, int> qty;
  final Uint8List? bytes;
  ComboDraft(this.name, this.description, this.price, this.imageUrl, this.qty, this.bytes);
}

Future<ComboDraft?> comboDialog(BuildContext context, Combo? c, List<Dish> dishes) {
  final name = TextEditingController(text: c?.name ?? '');
  final desc = TextEditingController(text: c?.description ?? '');
  final price = TextEditingController(text: c == null ? '' : '${c.price.round()}');
  final qty = <int, int>{
    if (c != null)
      for (final i in c.items) i.id: i.qty,
  };
  Uint8List? bytes;
  final url = c?.imageUrl ?? '';
  return showDialog<ComboDraft>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) {
        var itemsTotal = 0.0;
        for (final d in dishes) {
          itemsTotal += d.price * (qty[d.id] ?? 0);
        }
        return AlertDialog(
          title: Text(c == null ? 'New combo' : 'Edit combo'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(child: photoPreview(bytes, url, 110)),
                  Center(
                    child: TextButton.icon(
                      onPressed: () async {
                        final b = await pickPhoto();
                        if (b != null) setS(() => bytes = b);
                      },
                      icon: const Icon(Icons.photo_library),
                      label: Text(bytes == null && url.isEmpty ? 'Add picture' : 'Change picture'),
                    ),
                  ),
                  TextField(controller: name, decoration: const InputDecoration(labelText: 'Combo name')),
                  const SizedBox(height: 10),
                  TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description')),
                  const SizedBox(height: 12),
                  const Text('Foods in this combo', style: TextStyle(fontWeight: FontWeight.w600)),
                  for (final d in dishes)
                    Row(
                      children: [
                        Expanded(child: Text('${d.name} (${ugx(d.price)})')),
                        IconButton(
                          onPressed: (qty[d.id] ?? 0) > 0
                              ? () => setS(() {
                                    final n = (qty[d.id] ?? 0) - 1;
                                    if (n <= 0) {
                                      qty.remove(d.id);
                                    } else {
                                      qty[d.id] = n;
                                    }
                                  })
                              : null,
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        SizedBox(width: 22, child: Text('${qty[d.id] ?? 0}', textAlign: TextAlign.center)),
                        IconButton(
                          onPressed: () => setS(() => qty[d.id] = (qty[d.id] ?? 0) + 1),
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                      ],
                    ),
                  const SizedBox(height: 8),
                  Text('Bought separately: ${ugx(itemsTotal)}'),
                  const SizedBox(height: 6),
                  TextField(
                      controller: price,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'Combo price (one bill, UGX)',
                        suffixIcon: TextButton(
                          onPressed: () => setS(() => price.text = '${itemsTotal.round()}'),
                          child: const Text('Use total'),
                        ),
                      )),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(
                  ctx,
                  ComboDraft(name.text.trim(), desc.text.trim(), price.text.trim(), url,
                      Map<int, int>.from(qty), bytes)),
              child: const Text('Save'),
            ),
          ],
        );
      },
    ),
  );
}

class MenuAdminScreen extends StatefulWidget {
  const MenuAdminScreen({super.key});
  @override
  State<MenuAdminScreen> createState() => _MenuAdminScreenState();
}

class _MenuAdminScreenState extends State<MenuAdminScreen> {
  MenuBundle? _menu;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final m = await Api.menu();
      if (!mounted) return;
      setState(() {
        _menu = m;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.message == kSessionExpired) {
        handleSessionExpired(context);
        return;
      }
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _afterChange() async {
    await _load();
    RestaurantStore.instance.loadMenu();
  }

  Future<void> _editDish([Dish? d]) async {
    final m = _menu;
    if (m == null) return;
    final cats = {...m.dishes.map((x) => x.category)}.toList();
    final draft = await dishDialog(context, d, cats);
    if (draft == null || !mounted) return;
    final ok = await guarded(
        context,
        () => withProgress(context, () async {
              final url = await uploadPhotoIfNeeded(draft.bytes, draft.imageUrl);
              await Api.call('saveDish', {
                'item': {
                  if (d != null) 'id': d.id,
                  'name': draft.name,
                  'category': draft.category,
                  'tokenPrice': int.tryParse(draft.tokenPrice) ?? 0,
                  'price': double.tryParse(draft.price) ?? -1,
                  'description': draft.description,
                  'available': d?.available ?? true,
                  'imageUrl': url,
                }
              });
            }),
        success: 'Dish saved');
    if (ok) await _afterChange();
  }

  Future<void> _editCombo([Combo? c]) async {
    final m = _menu;
    if (m == null) return;
    final draft = await comboDialog(context, c, m.dishes);
    if (draft == null || !mounted) return;
    final ok = await guarded(
        context,
        () => withProgress(context, () async {
              final url = await uploadPhotoIfNeeded(draft.bytes, draft.imageUrl);
              await Api.call('saveCombo', {
                'item': {
                  if (c != null) 'id': c.id,
                  'name': draft.name,
                  'description': draft.description,
                  'price': double.tryParse(draft.price) ?? -1,
                  'available': c?.enabled ?? true,
                  'imageUrl': url,
                  'items': [
                    for (final e in draft.qty.entries)
                      if (e.value > 0) {'id': e.key, 'qty': e.value}
                  ],
                }
              });
            }),
        success: 'Combo saved');
    if (ok) await _afterChange();
  }

  Future<void> _delete(String what, String action, int id, String name) async {
    final yes = await confirmDialog(context, 'Delete $what?',
        'Remove "$name" from the menu? Old orders keep their records.',
        action: 'Delete');
    if (!yes || !mounted) return;
    final ok = await guarded(context, () => Api.call(action, {'id': id}),
        success: '$what deleted');
    if (ok) await _afterChange();
  }

  @override
  Widget build(BuildContext context) {
    final m = _menu;
    Widget dishesTab = const SizedBox();
    Widget combosTab = const SizedBox();
    if (m != null) {
      dishesTab = ListView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 90),
        children: [
          for (final d in m.dishes)
            Card(
              child: ListTile(
                leading: FoodImage(d.imageUrl, size: 52),
                title: Text(d.name),
                subtitle: Text('${d.category} • ${ugx(d.price)}'),
                onTap: () => _editDish(d),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: d.available,
                      onChanged: (v) async {
                        final ok = await guarded(context,
                            () => Api.call('setAvailability', {'id': d.id, 'available': v}));
                        if (ok) await _afterChange();
                      },
                    ),
                    IconButton(
                        tooltip: 'Delete',
                        onPressed: () => _delete('dish', 'deleteDish', d.id, d.name),
                        icon: const Icon(Icons.delete_outline)),
                  ],
                ),
              ),
            ),
        ],
      );
      combosTab = ListView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 90),
        children: [
          if (m.combos.isEmpty)
            const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No combos yet. Tap + to bundle several foods under one price.')),
          for (final c in m.combos)
            Card(
              child: ListTile(
                isThreeLine: true,
                leading: FoodImage(c.imageUrl, size: 52),
                title: Text(c.name),
                subtitle: Text('${c.includes}\n${ugx(c.price)}'
                    '${c.itemsTotal > c.price ? ' (saves ${ugx(c.itemsTotal - c.price)})' : ''}'
                    '${c.enabled && !c.available ? ' • a dish is sold out' : ''}'),
                onTap: () => _editCombo(c),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: c.enabled,
                      onChanged: (v) async {
                        final ok = await guarded(context,
                            () => Api.call('setComboAvailability', {'id': c.id, 'available': v}));
                        if (ok) await _afterChange();
                      },
                    ),
                    IconButton(
                        tooltip: 'Delete',
                        onPressed: () => _delete('combo', 'deleteCombo', c.id, c.name),
                        icon: const Icon(Icons.delete_outline)),
                  ],
                ),
              ),
            ),
        ],
      );
    }
    return DefaultTabController(
      length: 2,
      child: Builder(
        builder: (ctx) {
          final tabs = DefaultTabController.of(ctx);
          return Scaffold(
            appBar: AppBar(
              title: const Text('Menu & Combos'),
              bottom: const TabBar(tabs: [Tab(text: 'Dishes'), Tab(text: 'Combos')]),
              actions: [
                IconButton(
                    tooltip: 'Refresh',
                    onPressed: _loading ? null : _load,
                    icon: const Icon(Icons.refresh)),
              ],
            ),
            body: m == null
                ? Center(
                    child: _loading
                        ? const CircularProgressIndicator()
                        : Column(mainAxisSize: MainAxisSize.min, children: [
                            Text(_error ?? 'Could not load the menu.'),
                            const SizedBox(height: 12),
                            FilledButton(onPressed: _load, child: const Text('Try again')),
                          ]),
                  )
                : TabBarView(children: [dishesTab, combosTab]),
            floatingActionButton: m == null
                ? null
                : AnimatedBuilder(
                    animation: tabs,
                    builder: (_, __) => FloatingActionButton.extended(
                      onPressed: () => tabs.index == 0 ? _editDish() : _editCombo(),
                      icon: const Icon(Icons.add),
                      label: Text(tabs.index == 0 ? 'New dish' : 'New combo'),
                    ),
                  ),
          );
        },
      ),
    );
  }
}

// ================================================================== STATIONS & TABLES

class StationsScreen extends StatelessWidget {
  const StationsScreen({super.key});

  Future<void> _edit(BuildContext context, Future<void> Function() reload,
      [Station? s]) async {
    final v = await formDialog(
        context, s == null ? 'New pick-up station' : 'Edit station', [
      FieldSpec('name', 'Station name', initial: s?.name ?? ''),
      FieldSpec('fee', 'Delivery fee (UGX)',
          initial: s == null ? '' : '${s.fee.round()}',
          keyboard: TextInputType.number),
    ]);
    if (v == null || !context.mounted) return;
    final ok = await guarded(
        context,
        () => Api.call('saveStation', {
              if (s != null) 'id': s.id,
              'name': v['name'],
              'fee': double.tryParse(v['fee'] ?? '') ?? -1,
            }),
        success: 'Station saved');
    if (ok) {
      await reload();
      RestaurantStore.instance.loadMenu();
    }
  }

  @override
  Widget build(BuildContext context) {
    return RemoteView<MenuBundle>(
      title: 'Stations & Tables',
      load: Api.menu,
      fab: (context, reload) => FloatingActionButton.extended(
        onPressed: () => _edit(context, reload),
        icon: const Icon(Icons.add_location_alt),
        label: const Text('New station'),
      ),
      builder: (context, m, reload) => Narrow(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.table_restaurant),
                title: Text('${m.tableCount} tables'),
                subtitle: const Text('Customers choose their table from this list'),
                trailing: TextButton(
                  onPressed: () async {
                    final v = await formDialog(context, 'Number of tables', [
                      FieldSpec('n', 'Tables', initial: '${m.tableCount}', keyboard: TextInputType.number),
                    ]);
                    if (v == null || !context.mounted) return;
                    final ok = await guarded(
                        context,
                        () => Api.call('saveTableCount',
                            {'tableCount': int.tryParse(v['n'] ?? '') ?? 0}),
                        success: 'Tables updated');
                    if (ok) {
                      await reload();
                      RestaurantStore.instance.loadMenu();
                    }
                  },
                  child: const Text('Change'),
                ),
              ),
            ),
            const SectionTitle('Delivery pick-up stations'),
            if (m.stations.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No stations yet. Customers cannot choose delivery until you add one.')),
            for (final s in m.stations)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.location_on),
                  title: Text(s.name),
                  subtitle: Text('Delivery fee ${ugx(s.fee)}'),
                  onTap: () => _edit(context, reload, s),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final yes = await confirmDialog(
                          context, 'Remove station?', 'Remove "${s.name}"?',
                          action: 'Remove');
                      if (!yes || !context.mounted) return;
                      final ok = await guarded(context,
                          () => Api.call('deleteStation', {'id': s.id}),
                          success: 'Station removed');
                      if (ok) {
                        await reload();
                        RestaurantStore.instance.loadMenu();
                      }
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ================================================================== STATISTICS

class BarChart extends StatelessWidget {
  final List<Map<String, dynamic>> series;
  final String metric;
  const BarChart(this.series, this.metric, {super.key});

  @override
  Widget build(BuildContext context) {
    final values = [for (final s in series) (s[metric] as num).toDouble()];
    final maxV = values.fold<double>(0, (a, b) => b > a ? b : a);
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: 230,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < series.length; i++)
              SizedBox(
                width: 46,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(values[i] == 0 ? '' : compact(values[i]),
                        style: const TextStyle(fontSize: 10)),
                    const SizedBox(height: 4),
                    Container(
                      width: 26,
                      height: maxV == 0 ? 2.0 : (150 * values[i] / maxV).clamp(2.0, 150.0).toDouble(),
                      decoration: BoxDecoration(
                          color: values[i] == 0 ? Colors.white24 : color,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(4))),
                    ),
                    const SizedBox(height: 4),
                    Text('${series[i]['label']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10)),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});
  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  String mode = 'day';
  String metric = 'sales';
  late DateTimeRange range = DateTimeRange(
      start: DateTime.now().subtract(const Duration(days: 13)), end: DateTime.now());
  int year = DateTime.now().year;

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: now,
      initialDateRange: range,
    );
    if (r == null) return;
    var end = r.end;
    if (end.difference(r.start).inDays > 91) {
      end = r.start.add(const Duration(days: 91));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Showing the first 92 days of your selection.')));
      }
    }
    setState(() => range = DateTimeRange(start: r.start, end: end));
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = RestaurantStore.instance.role == UserRole.admin;
    final thisYear = DateTime.now().year;
    return RemoteView<Map<String, dynamic>>(
      key: ValueKey('$mode|${ymd(range.start)}|${ymd(range.end)}|$year'),
      title: 'Statistics',
      load: () => Api.map('stats', {
        'mode': mode,
        'from': ymd(range.start),
        'to': ymd(range.end),
        'year': year,
      }),
      builder: (context, r, reload) {
        final series = (r['series'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        final totals = Map<String, dynamic>.from(r['totals'] as Map);
        final byPayment = Map<String, dynamic>.from(r['byPayment'] as Map);
        final byMode = Map<String, dynamic>.from(r['byMode'] as Map);
        final best = (r['bestSellers'] as List).cast<Map>();
        final out = Map<String, dynamic>.from(r['outcomes'] as Map);
        final staff = r['staff'] == null
            ? <Map<String, dynamic>>[]
            : (r['staff'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        final metricLabel = switch (metric) {
          'orders' => 'Orders',
          'servings' => 'Servings',
          _ => 'Sales (UGX)',
        };
        return Narrow(
          width: 900,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('Figures use completed orders only (approved, cooked and handed over).',
                  style: TextStyle(fontSize: 12, color: kMuted)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final e in {'Daily': 'day', 'Monthly': 'month', 'Yearly': 'year'}.entries)
                    ChoiceChip(
                      label: Text(e.key),
                      selected: mode == e.value,
                      onSelected: (_) => setState(() => mode = e.value),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (mode == 'day')
                OutlinedButton.icon(
                  onPressed: _pickRange,
                  icon: const Icon(Icons.date_range),
                  label: Text('${ymd(range.start)}  to  ${ymd(range.end)}'),
                ),
              if (mode == 'month')
                Wrap(
                  spacing: 8,
                  children: [
                    for (final y in [thisYear - 2, thisYear - 1, thisYear])
                      ChoiceChip(
                        label: Text('$y'),
                        selected: year == y,
                        onSelected: (_) => setState(() => year = y),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final e in {'Sales': 'sales', 'Orders': 'orders', 'Servings': 'servings'}.entries)
                    ChoiceChip(
                      label: Text(e.key),
                      selected: metric == e.value,
                      onSelected: (_) => setState(() => metric = e.value),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(metricLabel, style: Theme.of(context).textTheme.titleMedium),
              BarChart(series, metric),
              const SizedBox(height: 8),
              StatCard('Sales', ugx(totals['sales'] as num), Icons.trending_up),
              StatCard('Completed orders', '${totals['orders']}', Icons.task_alt),
              StatCard('Total servings', '${totals['servings']}', Icons.restaurant),
              StatCard('Average order', ugx(r['averageOrder'] as num), Icons.receipt),
              StatCard('Average time, order to handover', '${r['averageMinutes']} min', Icons.timer),
              const SectionTitle('Sales by payment method'),
              if (byPayment.isEmpty) const Text('No sales in this period.'),
              for (final e in byPayment.entries)
                ListTile(
                    dense: true,
                    leading: const Icon(Icons.payments),
                    title: Text(e.key),
                    trailing: Text(ugx(e.value as num))),
              const SectionTitle('Sales by order type'),
              for (final e in byMode.entries)
                ListTile(
                    dense: true,
                    leading: const Icon(Icons.restaurant_menu),
                    title: Text(e.key),
                    trailing: Text(ugx(e.value as num))),
              const SectionTitle('Best sellers'),
              if (best.isEmpty) const Text('Nothing sold in this period.'),
              for (final b in best)
                ListTile(
                  dense: true,
                  leading: Icon(b['kind'] == 'combo' ? Icons.dinner_dining : Icons.star),
                  title: Text('${b['name']}${b['kind'] == 'combo' ? ' (combo)' : ''}'),
                  subtitle: Text('${b['qty']} sold • ${b['servings']} servings'),
                  trailing: Text(ugx(b['total'] as num)),
                ),
              const SectionTitle('Order outcomes (orders placed in this period)'),
              Text('Placed ${out['placed']}  •  Rejected ${out['rejected']}  •  '
                  'Cancelled ${out['cancelled']}  •  Delivery failed ${out['failed']}'),
              Text('Low-stock items right now: ${r['lowStockCount']}'),
              if (isAdmin) ...[
                const SectionTitle('Staff performance'),
                if (staff.isEmpty) const Text('No staff activity in this period.'),
                for (final s in staff)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.badge),
                      title: Text('${s['name']} (${roleLabel('${s['role']}')})'),
                      subtitle: Text(switch ('${s['role']}') {
                        'manager' => 'Orders approved: ${s['approved']}',
                        'kitchen' => 'Orders cooked: ${s['cooked']}',
                        _ => 'Handed over: ${s['handedOver']} • ${ugx(s['sales'] as num)}',
                      }),
                    ),
                  ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }
}

// ================================================================== USERS (admin)

class UserManagementScreen extends StatelessWidget {
  const UserManagementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return RemoteView<Rows>(
      title: 'Users',
      load: () => Api.list('listUsers'),
      fab: (context, reload) => FloatingActionButton.extended(
        onPressed: () async {
          final v = await formDialog(
            context,
            'New staff account',
            const [
              FieldSpec('name', 'Full name'),
              FieldSpec('username', 'Username (letters/numbers)'),
              FieldSpec('email', 'Email (for password reset, optional)',
                  keyboard: TextInputType.emailAddress),
              FieldSpec('role', 'Role', initial: 'waiter', options: kStaffRoles),
              FieldSpec('password', 'First password (6+ characters)', obscure: true),
            ],
            action: 'Create',
          );
          if (v == null || !context.mounted) return;
          final ok = await guarded(context, () => Api.call('saveUser', v),
              success: 'Account created. They must choose their own password at first sign-in.');
          if (ok) await reload();
        },
        icon: const Icon(Icons.person_add),
        label: const Text('Add user'),
      ),
      builder: (context, users, reload) => Narrow(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 90),
          children: [
            for (final u in users)
              ListTile(
                leading: CircleAvatar(
                    backgroundColor: u['active'] == true ? null : Colors.grey.shade700,
                    child: const Icon(Icons.account_circle)),
                title: Text('${u['name']}  (${u['username']})'),
                subtitle: Text(
                    '${roleLabel('${u['role']}')}${'${u['email']}'.isEmpty ? '' : ' • ${u['email']}'}'
                    '${u['active'] == true ? '' : ' • DISABLED'}'),
                trailing: PopupMenuButton<String>(
                  onSelected: (a) async {
                    final id = (u['id'] as num).toInt();
                    if (a == 'edit') {
                      final v = await formDialog(
                        context,
                        'Edit ${u['username']}',
                        [
                          FieldSpec('name', 'Full name', initial: '${u['name']}'),
                          FieldSpec('email', 'Email', initial: '${u['email']}',
                              keyboard: TextInputType.emailAddress),
                          FieldSpec('role', 'Role', initial: '${u['role']}', options: kStaffRoles),
                        ],
                      );
                      if (v == null || !context.mounted) return;
                      final ok = await guarded(context,
                          () => Api.call('updateUser', {'id': id, ...v}),
                          success: 'User updated');
                      if (ok) await reload();
                    } else if (a == 'pw') {
                      final v = await formDialog(
                        context,
                        'Reset password for ${u['username']}',
                        const [FieldSpec('password', 'Temporary password (6+ characters)', obscure: true)],
                        action: 'Reset',
                      );
                      if (v == null || !context.mounted) return;
                      final ok = await guarded(
                          context,
                          () => Api.call('resetUserPassword', {'id': id, 'password': v['password']}),
                          success: 'Password reset. They must choose a new one at next sign-in.');
                      if (ok) await reload();
                    } else if (a == 'toggle') {
                      final ok = await guarded(
                          context,
                          () => Api.call('setUserActive', {'id': id, 'active': u['active'] != true}));
                      if (ok) await reload();
                    } else if (a == 'delete') {
                      final yes = await confirmDialog(context, 'Delete user?',
                          'Permanently delete ${u['name']}? To keep them but stop sign-in, use Disable instead.',
                          action: 'Delete');
                      if (!yes || !context.mounted) return;
                      final ok = await guarded(context,
                          () => Api.call('deleteUser', {'id': id}),
                          success: 'User deleted');
                      if (ok) await reload();
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                    const PopupMenuItem(value: 'pw', child: Text('Reset password')),
                    PopupMenuItem(
                        value: 'toggle',
                        child: Text(u['active'] == true ? 'Disable' : 'Enable')),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ================================================================== INVENTORY & OTHERS

class InventoryScreen extends StatelessWidget {
  const InventoryScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return RemoteView<Rows>(
      title: 'Inventory & Stock',
      load: () => Api.list('listInventory'),
      fab: (context, reload) => FloatingActionButton.extended(
        onPressed: () async {
          final v = await formDialog(context, 'New stock item', const [
            FieldSpec('name', 'Item name'),
            FieldSpec('unit', 'Unit (kg, litres, crates...)'),
            FieldSpec('stock', 'Current stock', keyboard: TextInputType.number),
            FieldSpec('minimum', 'Low-stock level', keyboard: TextInputType.number),
          ]);
          if (v == null || !context.mounted) return;
          final ok = await guarded(
              context,
              () => Api.call('saveInventoryItem', {
                    'name': v['name'],
                    'unit': v['unit'],
                    'stock': double.tryParse(v['stock'] ?? '') ?? -1,
                    'minimum': double.tryParse(v['minimum'] ?? '') ?? -1,
                  }),
              success: 'Stock item added');
          if (ok) await reload();
        },
        icon: const Icon(Icons.add),
        label: const Text('New item'),
      ),
      builder: (context, stock, reload) => Narrow(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
          children: [
            for (final x in stock)
              Card(
                child: ListTile(
                  leading: Icon((x['stock'] as num) <= (x['minimum'] as num)
                      ? Icons.warning_amber
                      : Icons.inventory),
                  title: Text('${x['name']}'),
                  subtitle: Text('${x['stock']} ${x['unit']} • minimum ${x['minimum']}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if ((x['stock'] as num) <= (x['minimum'] as num))
                        const Chip(label: Text('LOW')),
                      IconButton(
                        tooltip: 'Record purchase / adjustment',
                        icon: const Icon(Icons.edit),
                        onPressed: () async {
                          final v = await formDialog(context, 'Adjust ${x['name']}', const [
                            FieldSpec('change', 'Quantity (+ to add, - to remove)',
                                keyboard: TextInputType.numberWithOptions(
                                    signed: true, decimal: true)),
                            FieldSpec('reason', 'Reason (purchase, spoilage...)',
                                initial: 'Purchase'),
                          ]);
                          if (v == null || !context.mounted) return;
                          final ok = await guarded(
                              context,
                              () => Api.call('adjustStock', {
                                    'id': (x['id'] as num).toInt(),
                                    'change': double.tryParse(v['change'] ?? '') ?? 0,
                                    'reason': v['reason'],
                                  }),
                              success: 'Stock updated');
                          if (ok) await reload();
                        },
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return RemoteView<Rows>(
      title: 'Promotions List',
      load: () => Api.list('listSubscribers'),
      builder: (context, subs, reload) => Narrow(
        child: ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.campaign),
              title: Text('WhatsApp offers subscribers: ${subs.length}'),
              subtitle: const Text(
                  'Customers who agreed to receive promotions when ordering.'),
            ),
            for (final s in subs)
              ListTile(
                dense: true,
                leading: const Icon(Icons.phone),
                title: Text('${s['phone']}'),
                subtitle: Text('${s['name']}'),
              ),
          ],
        ),
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('System Settings')),
        body: Narrow(
          child: ListView(
            children: [
              ListTile(
                leading: Icon(Api.configured ? Icons.cloud_done : Icons.cloud_off),
                title: const Text('Database'),
                subtitle: Text(Api.configured
                    ? 'Connected to Google Sheets'
                    : 'Not connected (demo mode)'),
              ),
              const ListTile(
                  title: Text('Restaurant'),
                  subtitle: Text('Kanyatsi Restaurant, Kagando, Uganda')),
              const ListTile(
                  title: Text('Tables and delivery stations'),
                  subtitle: Text('Managed under Stations & Tables')),
              const ListTile(
                  title: Text('Payments'),
                  subtitle: Text('Cash, Mobile Money and Pay on Delivery are recorded by the manager')),
              const ListTile(
                  title: Text('Backup'),
                  subtitle: Text('Use File > Make a copy on the Google Sheet regularly')),
              const ListTile(
                  title: Text('Security'),
                  subtitle: Text('Role permissions are enforced by the script; passwords are stored hashed')),
              const ListTile(
                  title: Text('Notifications'),
                  subtitle: Text('Each role receives its own alerts: new orders, kitchen tickets, assignments and low-stock warnings')),
            ],
          ),
        ),
      );
}

class AuditScreen extends StatelessWidget {
  const AuditScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return RemoteView<Rows>(
      title: 'Audit Trail',
      load: () => Api.list('listAudit'),
      builder: (context, rows, reload) => Narrow(
        child: ListView(
          children: [
            if (rows.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Text('No activity yet.')),
            for (final a in rows)
              ListTile(
                leading: const Icon(Icons.security),
                title: Text('${a['action']}'),
                subtitle: Text(
                    '${a['user']} (${a['role']}) • ${a['timestamp']}\n${a['details']}'),
                isThreeLine: '${a['details']}'.isNotEmpty,
              ),
          ],
        ),
      ),
    );
  }
}
