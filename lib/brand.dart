part of 'main.dart';

// ======================================================== KANYATSI BRAND
// Colours come from the app icon: terracotta, thatch cream and straw gold.

const Color kBg = Color(0xFF120C09);
const Color kSurface = Color(0xFF1F1612);
const Color kSurface2 = Color(0xFF2B1E18);
const Color kLine = Color(0xFF4B3629);
const Color kAccent = Color(0xFFCF4F17);
const Color kGold = Color(0xFFE3B05A);
const Color kCream = Color(0xFFFFF1DC);
const Color kMuted = Color(0xFFBFAE9C);
const Color kWarnBg = Color(0xFF3B2A10);
const Color kOkBg = Color(0xFF12301E);
const Color kPanelHi = Color(0xFF2E1B12);

class _FadePageTransitions extends PageTransitionsBuilder {
  const _FadePageTransitions();
  @override
  Widget buildTransitions<T>(
      PageRoute<T> route,
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      Widget child) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    );
  }
}

ThemeData buildKanyatsiTheme() {
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  final body = GoogleFonts.poppinsTextTheme(base.textTheme)
      .apply(bodyColor: kCream, displayColor: kCream);
  TextStyle serif(TextStyle? s, {FontWeight w = FontWeight.w700}) =>
      GoogleFonts.playfairDisplay(textStyle: s, fontWeight: w, color: kCream);
  final text = body.copyWith(
    headlineMedium: serif(body.headlineMedium),
    headlineSmall: serif(body.headlineSmall),
    titleLarge: serif(body.titleLarge),
    titleMedium: serif(body.titleMedium, w: FontWeight.w600),
  );
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: kAccent,
    onPrimary: Colors.white,
    secondary: kGold,
    onSecondary: Color(0xFF2A1A08),
    error: Color(0xFFFF6B5E),
    onError: Colors.white,
    surface: kSurface,
    onSurface: kCream,
    primaryContainer: Color(0xFF5E2410),
    onPrimaryContainer: kCream,
    secondaryContainer: Color(0xFF4A3516),
    onSecondaryContainer: kCream,
    surfaceContainerHighest: kSurface2,
    onSurfaceVariant: kMuted,
    outline: kLine,
    outlineVariant: kLine,
  );
  final round14 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  OutlineInputBorder field(Color c, [double w = 1]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: c, width: w));
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: kBg.withValues(alpha: 0.90),
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      foregroundColor: kCream,
      titleTextStyle: GoogleFonts.playfairDisplay(
          fontSize: 20, fontWeight: FontWeight.w700, color: kCream),
    ),
    cardTheme: CardThemeData(
      color: kSurface.withValues(alpha: 0.93),
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: kLine.withValues(alpha: 0.7)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kSurface2.withValues(alpha: 0.85),
      border: field(kLine),
      enabledBorder: field(kLine),
      focusedBorder: field(kGold, 1.6),
      labelStyle: const TextStyle(color: kMuted),
      helperStyle: const TextStyle(color: kMuted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: round14,
        textStyle: GoogleFonts.poppins(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: kGold,
        side: BorderSide(color: kGold.withValues(alpha: 0.6)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: round14,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: kGold),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: kSurface2,
      selectedColor: kAccent,
      labelStyle: const TextStyle(color: kCream),
      secondaryLabelStyle: const TextStyle(color: kCream),
      checkmarkColor: Colors.white,
      side: const BorderSide(color: kLine),
      shape: const StadiumBorder(),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: kSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      titleTextStyle: GoogleFonts.playfairDisplay(
          fontSize: 20, fontWeight: FontWeight.w700, color: kCream),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: kSurface2,
      contentTextStyle: const TextStyle(color: kCream),
      shape: round14,
    ),
    dividerTheme: const DividerThemeData(color: kLine),
    listTileTheme: const ListTileThemeData(iconColor: kGold),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: kGold),
    popupMenuTheme: const PopupMenuThemeData(color: kSurface2),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: kAccent, foregroundColor: Colors.white),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: _FadePageTransitions(),
      TargetPlatform.iOS: _FadePageTransitions(),
    }),
  );
}

// ------------------------------------------------ sliding background pictures

/// Pictures the manager uploaded (loaded together with the menu).
final ValueNotifier<List<String>> kHeroImages = ValueNotifier<List<String>>(<String>[]);

const List<String> kBundledBackgrounds = [
  'assets/backgrounds/bg1_candlelight.jpg',
  'assets/backgrounds/bg2_emerald.jpg',
  'assets/backgrounds/bg3_burgundy.jpg',
  'assets/backgrounds/bg4_terracotta.jpg',
  'assets/backgrounds/bg5_copper.jpg',
];

class BrandBackdrop extends StatefulWidget {
  final Widget child;
  const BrandBackdrop({required this.child, super.key});
  @override
  State<BrandBackdrop> createState() => _BrandBackdropState();
}

class _BrandBackdropState extends State<BrandBackdrop> {
  int _i = 0;
  Timer? _timer;

  List<ImageProvider> _images() => <ImageProvider>[
        for (final u in kHeroImages.value) NetworkImage(u),
        for (final a in kBundledBackgrounds) AssetImage(a),
      ];

  @override
  void initState() {
    super.initState();
    kHeroImages.addListener(_onHeroChanged);
    _timer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted) return;
      final n = _images().length;
      final next = (_i + 1) % n;
      final imgs = _images();
      precacheImage(imgs[next], context).catchError((Object _) {});
      setState(() => _i = next);
    });
  }

  void _onHeroChanged() {
    if (mounted) setState(() => _i = 0);
  }

  @override
  void dispose() {
    kHeroImages.removeListener(_onHeroChanged);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final imgs = _images();
    final img = imgs[_i % imgs.length];
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: kBg),
        RepaintBoundary(
          child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 1800),
          child: _Slide(key: ValueKey<String>('$_i-${kHeroImages.value.length}'), image: img),
        ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.50),
                Colors.black.withValues(alpha: 0.20),
                Colors.black.withValues(alpha: 0.62),
              ],
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _Slide extends StatelessWidget {
  final ImageProvider image;
  const _Slide({required this.image, super.key});
  @override
  Widget build(BuildContext context) => SizedBox.expand(
        child: Image(
          image: image,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      );
}

// ------------------------------------------------------------- brand widgets

class BrandHeader extends StatelessWidget {
  final bool compact;
  const BrandHeader({this.compact = false, super.key});
  @override
  Widget build(BuildContext context) {
    final size = compact ? 84.0 : 118.0;
    return Column(
      children: [
        Container(
          width: size,
          height: size,
          padding: EdgeInsets.all(size * 0.14),
          decoration: BoxDecoration(
            color: kAccent,
            borderRadius: BorderRadius.circular(size * 0.26),
            border: Border.all(color: kGold.withValues(alpha: 0.55), width: 1.5),
            boxShadow: [
              BoxShadow(
                  color: kAccent.withValues(alpha: 0.45),
                  blurRadius: 28,
                  spreadRadius: 1),
            ],
          ),
          child: Image.asset('assets/logo.png', fit: BoxFit.contain),
        ),
        SizedBox(height: compact ? 12 : 18),
        Text(
          'KANYATSI',
          style: GoogleFonts.playfairDisplay(
              fontSize: compact ? 28 : 38,
              fontWeight: FontWeight.w800,
              letterSpacing: compact ? 6 : 8,
              color: kCream),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(width: 28, height: 1.5, color: kGold),
            const SizedBox(width: 10),
            Text('RESTAURANT',
                style: GoogleFonts.poppins(
                    fontSize: 12.5,
                    letterSpacing: 6,
                    fontWeight: FontWeight.w600,
                    color: kGold)),
            const SizedBox(width: 10),
            Container(width: 28, height: 1.5, color: kGold),
          ],
        ),
        if (!compact) ...[
          const SizedBox(height: 10),
          Text('Authentic taste, freshly prepared',
              style: GoogleFonts.poppins(fontSize: 12.5, color: kMuted)),
        ],
      ],
    );
  }
}

class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final Color? border;
  const GlassCard(
      {required this.child,
      this.padding = const EdgeInsets.all(16),
      this.color,
      this.border,
      super.key});
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: padding,
        decoration: BoxDecoration(
          color: color ?? kSurface.withValues(alpha: 0.80),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: border ?? kGold.withValues(alpha: 0.25)),
        ),
        child: child,
      );
}

/// The customer's one-time delivery code, shown large with a copy button.
class DeliveryCodeCard extends StatelessWidget {
  final String code;
  final String title;
  final String message;
  const DeliveryCodeCard(this.code,
      {this.title = 'YOUR DELIVERY CODE',
      this.message = 'Show this code to the delivery man when he arrives. '
          'It can be used only once, so do not share it with anyone else.',
      super.key});
  @override
  Widget build(BuildContext context) => GlassCard(
        color: kPanelHi,
        border: kGold,
        child: Column(
          children: [
            Text(title,
                style: const TextStyle(
                    color: kGold, fontWeight: FontWeight.w700, letterSpacing: 2, fontSize: 12)),
            const SizedBox(height: 8),
            SelectableText(
              code,
              style: GoogleFonts.robotoMono(
                  fontSize: 32, fontWeight: FontWeight.w800, letterSpacing: 6, color: kCream),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: kMuted, fontSize: 12),
            ),
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Code copied')));
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy code'),
            ),
          ],
        ),
      );
}

String fmtNum(num v) {
  final d = v.toDouble();
  if (d == d.roundToDouble()) return d.round().toString();
  return d.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
}

String numText(dynamic v) {
  final n = (v is num) ? v.toDouble() : 0.0;
  return n <= 0 ? '' : fmtNum(n);
}

double? parseNum(String s) => double.tryParse(s.trim().replaceAll(',', ''));

// ------------------------------------------------------------- notifications

class Notify {
  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static Future<void> init() async {
    try {
      await _plugin.initialize(const InitializationSettings(
          android: AndroidInitializationSettings('ic_stat')));
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  static Future<void> askPermission() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
    } catch (_) {}
  }

  static Future<void> show(int id, String title, String body) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'kanyatsi_updates',
            'Restaurant updates',
            channelDescription: 'Orders, stock and delivery updates',
            importance: Importance.high,
            priority: Priority.high,
            icon: 'ic_stat',
          ),
        ),
      );
    } catch (_) {}
  }
}

final ValueNotifier<int> kUnread = ValueNotifier<int>(0);

int _idOf(Map<String, dynamic> r) => (r['id'] as num).toInt();

/// Checks for new messages for the signed-in role every 15 seconds and shows
/// them as phone notifications. Wrap the staff dashboard with it.
class NotificationWatcher extends StatefulWidget {
  final Widget child;
  const NotificationWatcher({required this.child, super.key});
  @override
  State<NotificationWatcher> createState() => _NotificationWatcherState();
}

class _NotificationWatcherState extends State<NotificationWatcher>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Notify.askPermission();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _poll());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _poll();
  }

  Future<void> _poll() async {
    if (_busy || !mounted || Api.token == null) return;
    _busy = true;
    try {
      final rows = await Api.list('listNotifications');
      final prefs = await SharedPreferences.getInstance();
      final me = RestaurantStore.instance.staffName;
      final shownKey = 'n_shown_$me';
      final readKey = 'n_read_$me';
      var maxId = 0;
      for (final r in rows) {
        if (_idOf(r) > maxId) maxId = _idOf(r);
      }
      if (!prefs.containsKey(shownKey)) {
        await prefs.setInt(shownKey, maxId);
        await prefs.setInt(readKey, maxId);
      }
      final shown = prefs.getInt(shownKey) ?? 0;
      final read = prefs.getInt(readKey) ?? 0;
      final fresh = rows.where((r) => _idOf(r) > shown).toList()
        ..sort((a, b) => _idOf(a).compareTo(_idOf(b)));
      for (final r in fresh.take(4)) {
        await Notify.show(_idOf(r), '${r['title']}', '${r['body']}');
      }
      if (fresh.isNotEmpty) await prefs.setInt(shownKey, maxId);
      kUnread.value = rows.where((r) => _idOf(r) > read).length;
    } on ApiException catch (e) {
      if (e.message == kSessionExpired && mounted) handleSessionExpired(context);
    } catch (_) {
      // ignore: a missed check is retried in 15 seconds
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

Future<void> markNotificationsRead(Rows rows) async {
  try {
    var maxId = 0;
    for (final r in rows) {
      if (_idOf(r) > maxId) maxId = _idOf(r);
    }
    final prefs = await SharedPreferences.getInstance();
    final me = RestaurantStore.instance.staffName;
    await prefs.setInt('n_read_$me', maxId);
    final shown = prefs.getInt('n_shown_$me') ?? 0;
    if (maxId > shown) await prefs.setInt('n_shown_$me', maxId);
    kUnread.value = 0;
  } catch (_) {}
}

class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: kUnread,
        builder: (_, n, __) => IconButton(
          tooltip: 'Notifications',
          icon: Badge(
            isLabelVisible: n > 0,
            label: Text('$n'),
            child: const Icon(Icons.notifications_outlined),
          ),
          onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const NotificationCenterScreen())),
        ),
      );
}

IconData notificationIcon(String kind) => switch (kind) {
      'stock' => Icons.warning_amber_rounded,
      'payment' => Icons.payments_outlined,
      'tokens' => Icons.stars_rounded,
      'event' => Icons.event_available,
      'subscription' => Icons.card_membership,
      'assignment' => Icons.delivery_dining,
      'alert' => Icons.error_outline,
      'broadcast' => Icons.campaign,
      _ => Icons.receipt_long,
    };

class NotificationCenterScreen extends StatelessWidget {
  const NotificationCenterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isManager = RestaurantStore.instance.role == UserRole.admin ||
        RestaurantStore.instance.role == UserRole.manager;
    return RemoteView<Rows>(
      title: 'Notifications',
      load: () => Api.list('listNotifications'),
      autoRefresh: const Duration(seconds: 20),
      onLoaded: (prev, cur) => markNotificationsRead(cur),
      fab: isManager
          ? (context, reload) => FloatingActionButton.extended(
                onPressed: () async {
                  final v = await formDialog(
                    context,
                    'Send a notice to staff',
                    const [
                      FieldSpec('to', 'Send to',
                          initial: 'everyone',
                          options: ['everyone', 'kitchen', 'waiter', 'delivery', 'manager']),
                      FieldSpec('title', 'Title'),
                      FieldSpec('body', 'Message (optional)'),
                    ],
                    action: 'Send',
                  );
                  if (v == null || !context.mounted) return;
                  final to = v['to'] ?? 'everyone';
                  final roles = to == 'everyone' ? kStaffRoles : <String>[to];
                  final ok = await guarded(
                      context,
                      () => Api.call('sendNotification',
                          {'roles': roles, 'title': v['title'], 'body': v['body']}),
                      success: 'Notice sent');
                  if (ok) await reload();
                },
                icon: const Icon(Icons.send),
                label: const Text('Send notice'),
              )
          : null,
      builder: (context, rows, reload) => Narrow(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 90),
          children: [
            if (rows.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No notifications yet. New orders, stock warnings and '
                      'assignments for your role appear here.')),
            for (final n in rows)
              Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: kAccent.withValues(alpha: 0.2),
                    child: Icon(notificationIcon('${n['kind']}'), color: kGold),
                  ),
                  title: Text('${n['title']}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('${n['body']}\n${n['timestamp']}'),
                  isThreeLine: '${n['body']}'.isNotEmpty,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
