part of 'main.dart';

// ======================================================== CUSTOMER SIDE
// Profile, wallet, tokens, events, subscriptions, mobile money, receipts, contact links.

const Map<String, String> kPayLabels = {
  'Cash': 'Cash',
  'MTN': 'MTN Mobile Money',
  'Airtel': 'Airtel Money',
  'Wallet': 'My wallet',
  'Tokens': 'Tokens',
  'Pay on Delivery': 'Pay on delivery',
  'Subscription': 'Subscription',
};
String payLabel(String p) => kPayLabels[p] ?? p;
bool isMomo(String p) => p == 'MTN' || p == 'Airtel';

Future<void> registerPush({bool customer = false}) => PushService.init(
      (t) async {
        try {
          await Api.call(customer ? 'meRegisterDevice' : 'registerDevice', {'deviceToken': t});
        } catch (_) {}
      },
      (title, body) => Notify.show(DateTime.now().millisecondsSinceEpoch ~/ 1000, title, body),
    );

class CustomerStore extends ChangeNotifier {
  static final CustomerStore instance = CustomerStore._();
  CustomerStore._();

  Map<String, dynamic>? profile;
  Map<String, dynamic> extra = {};
  bool mustChange = false;

  bool get signedIn => Api.customerToken != null;
  String get name => '${profile?['name'] ?? ''}';
  String get phone => '${profile?['phone'] ?? ''}';
  num get wallet => (profile?['wallet'] as num?) ?? 0;
  int get tokens => ((profile?['tokens'] as num?) ?? 0).toInt();
  String get photoUrl => '${profile?['photoUrl'] ?? ''}';

  Future<void> restore() async {
    try {
      final p = await SharedPreferences.getInstance();
      final t = p.getString('customer_token');
      if (t == null || !Api.configured) return;
      Api.customerToken = t;
      notifyListeners();
      await refresh();
      registerPush(customer: true);
    } catch (_) {
      // offline at start: stay signed in, refresh later
    }
  }

  Future<void> refresh() async {
    final r = await Api.map('meProfile');
    profile = Map<String, dynamic>.from(r['profile'] as Map);
    extra = r;
    notifyListeners();
  }

  Future<void> _adopt(Map<String, dynamic> r) async {
    Api.customerToken = '${r['token']}';
    profile = Map<String, dynamic>.from(r['profile'] as Map);
    mustChange = r['mustChange'] == true;
    final p = await SharedPreferences.getInstance();
    await p.setString('customer_token', Api.customerToken!);
    notifyListeners();
    registerPush(customer: true);
  }

  Future<void> login(String phone, String password) async =>
      _adopt(await Api.map('meLogin', {'phone': phone, 'password': password}));

  Future<void> register(Map<String, dynamic> body) async =>
      _adopt(await Api.map('meRegister', body));

  Future<void> logout() async {
    try {
      await Api.call('meLogout');
    } catch (_) {}
    clearLocal();
  }

  void clearLocal() {
    Api.customerToken = null;
    profile = null;
    extra = {};
    SharedPreferences.getInstance().then((p) => p.remove('customer_token'));
    notifyListeners();
  }
}

/// Opens the profile (or the sign-in page first). Returns true when signed in.
Future<bool> requireCustomer(BuildContext context) async {
  if (CustomerStore.instance.signedIn) return true;
  final ok = await Navigator.push<bool>(
      context, MaterialPageRoute(builder: (_) => const CustomerAuthScreen()));
  return ok == true;
}

// ------------------------------------------------------------- mobile money helpers

class MomoInstructions extends StatelessWidget {
  final String provider; // MTN or Airtel
  const MomoInstructions(this.provider, {super.key});
  @override
  Widget build(BuildContext context) {
    final m = RestaurantStore.instance.menu?.momo[provider.toLowerCase()] ?? const {};
    final ussd = '${m['ussd'] ?? ''}', merchant = '${m['merchant'] ?? ''}';
    final how = '${m['instructions'] ?? ''}';
    return GlassCard(
      color: kPanelHi,
      border: kGold,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Pay with ${payLabel(provider)}',
              style: const TextStyle(fontWeight: FontWeight.w700, color: kGold)),
          const SizedBox(height: 6),
          if (ussd.isNotEmpty) Text('1. Dial $ussd on your phone'),
          if (merchant.isNotEmpty) ...[
            const SizedBox(height: 2),
            Row(
              children: [
                Expanded(child: Text('2. Merchant code: $merchant',
                    style: const TextStyle(fontWeight: FontWeight.w700))),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () => Clipboard.setData(ClipboardData(text: merchant)),
                ),
              ],
            ),
          ],
          if (ussd.isEmpty && merchant.isEmpty)
            const Text('The restaurant has not added payment numbers yet. Please ask the manager.'),
          if (how.isNotEmpty) Text(how, style: const TextStyle(color: kMuted, fontSize: 12)),
        ],
      ),
    );
  }
}

/// Phone number + transaction id / screenshot. Returns {payPhone, txnId, proofData} or null.
Future<Map<String, dynamic>?> proofDialog(BuildContext context,
    {required String provider, String phone = ''}) {
  final ph = TextEditingController(text: phone);
  final txn = TextEditingController();
  Uint8List? shot;
  String? error;
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: const Text('Confirm your payment'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ph,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(labelText: 'Phone number you paid from ($provider)'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: txn,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Transaction ID'),
              ),
              const SizedBox(height: 6),
              const Text('or', style: TextStyle(color: kMuted)),
              TextButton.icon(
                onPressed: () async {
                  final b = await pickPhotoLarge();
                  if (b != null) setS(() => shot = b);
                },
                icon: Icon(shot == null ? Icons.add_photo_alternate_outlined : Icons.check_circle),
                label: Text(shot == null ? 'Attach screenshot' : 'Screenshot attached'),
              ),
              if (error != null)
                Text(error!, style: const TextStyle(color: Color(0xFFFF6B5E))),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (ph.text.trim().length < 9) {
                setS(() => error = 'Enter the phone number you paid from.');
                return;
              }
              if (txn.text.trim().length < 6 && shot == null) {
                setS(() => error = 'Enter the transaction ID or attach a screenshot.');
                return;
              }
              Navigator.pop(ctx, {
                'payPhone': ph.text.trim(),
                'txnId': txn.text.trim(),
                'proofData': shot == null ? '' : base64Encode(shot!),
                'proofMime': 'image/jpeg',
              });
            },
            child: const Text('Send for approval'),
          ),
        ],
      ),
    ),
  );
}

/// Choose how to pay for an event ticket, subscription or top-up.
Future<Map<String, dynamic>?> payDialog(BuildContext context,
    {required num amount, bool wallet = true, String title = 'How will you pay?'}) {
  final cs = CustomerStore.instance;
  final ph = TextEditingController(text: cs.phone);
  final txn = TextEditingController();
  String method = '';
  Uint8List? shot;
  String? error;
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) {
        final momo = isMomo(method);
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Amount: ${ugx(amount)}',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final m in [if (wallet) 'Wallet', 'Cash', 'MTN', 'Airtel'])
                      ChoiceChip(
                        label: Text(payLabel(m)),
                        selected: method == m,
                        onSelected: (_) => setS(() {
                          method = m;
                          error = null;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (method == 'Wallet')
                  Text('Wallet balance: ${ugx(cs.wallet)}',
                      style: TextStyle(color: cs.wallet >= amount ? kGold : const Color(0xFFFF6B5E))),
                if (method == 'Cash')
                  const Text('Pay the cash to the manager. He confirms it and then your code is released.',
                      style: TextStyle(color: kMuted)),
                if (momo) ...[
                  MomoInstructions(method),
                  TextField(
                    controller: ph,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Phone number you paid from'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: txn,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(labelText: 'Transaction ID'),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      final b = await pickPhotoLarge();
                      if (b != null) setS(() => shot = b);
                    },
                    icon: Icon(shot == null ? Icons.add_photo_alternate_outlined : Icons.check_circle),
                    label: Text(shot == null ? 'Or attach screenshot' : 'Screenshot attached'),
                  ),
                ],
                if (error != null)
                  Text(error!, style: const TextStyle(color: Color(0xFFFF6B5E))),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (method.isEmpty) {
                  setS(() => error = 'Choose how you will pay.');
                  return;
                }
                if (method == 'Wallet' && cs.wallet < amount) {
                  setS(() => error = 'Not enough in your wallet. Top up first.');
                  return;
                }
                if (momo && (ph.text.trim().length < 9 || (txn.text.trim().length < 6 && shot == null))) {
                  setS(() => error = 'Enter your phone number and the transaction ID (or a screenshot).');
                  return;
                }
                Navigator.pop(ctx, {
                  'method': method,
                  'payPhone': ph.text.trim(),
                  'txnId': txn.text.trim(),
                  'proofData': shot == null ? '' : base64Encode(shot!),
                  'proofMime': 'image/jpeg',
                });
              },
              child: const Text('Continue'),
            ),
          ],
        );
      },
    ),
  );
}

void showReceipt(BuildContext context, Map<String, dynamic> r) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Receipt'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Center(child: Text('KANYATSI RESTAURANT', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 2))),
            const SizedBox(height: 8),
            Text('Order #${r['orderId']}  •  ${r['mode']}'),
            Text('${r['date']}', style: const TextStyle(color: kMuted, fontSize: 12)),
            Text('Customer: ${r['customer']}'),
            const Divider(),
            for (final l in (r['lines'] as List))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(child: Text('${l['qty']} x ${l['name']}')),
                    Text(ugx(l['lineTotal'] as num)),
                  ],
                ),
              ),
            const Divider(),
            if ((r['deliveryFee'] as num) > 0) Text('Delivery: ${ugx(r['deliveryFee'] as num)}'),
            Text(
                (r['tokensUsed'] as num) > 0
                    ? 'Paid with ${r['tokensUsed']} tokens'
                    : 'Total: ${ugx(r['total'] as num)}',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            Text('Paid by ${payLabel('${r['method']}')}'
                '${'${r['txnId']}'.isNotEmpty ? '  (ID ${r['txnId']})' : ''}'),
            const SizedBox(height: 8),
            const Center(child: Text('Thank you for dining with us!', style: TextStyle(color: kGold))),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
    ),
  );
}

// ------------------------------------------------------------- sign in / create profile

class CustomerAuthScreen extends StatefulWidget {
  const CustomerAuthScreen({super.key});
  @override
  State<CustomerAuthScreen> createState() => _CustomerAuthScreenState();
}

class _CustomerAuthScreenState extends State<CustomerAuthScreen> {
  bool _register = false;
  bool _busy = false;
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _pass = TextEditingController();
  Uint8List? _photo;

  Future<void> _submit() async {
    setState(() => _busy = true);
    final store = CustomerStore.instance;
    final ok = await guarded(context, () async {
      if (_register) {
        await store.register({
          'name': _name.text.trim(),
          'phone': _phone.text.trim(),
          'password': _pass.text,
          if (_photo != null) 'photoData': base64Encode(_photo!),
          'photoMime': 'image/jpeg',
        });
      } else {
        await store.login(_phone.text.trim(), _pass.text);
      }
    }, success: _register ? 'Profile created. Welcome!' : 'Welcome back!');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok && !_register && store.mustChange) await _forceNewPassword(_pass.text);
    if (!mounted) return;
    if (ok) Navigator.pop(context, true);
  }

  // The manager gave a temporary password: the customer must choose their own now.
  Future<void> _forceNewPassword(String current) async {
    while (mounted) {
      final v = await formDialog(
        context,
        'Choose your own password',
        const [FieldSpec('np', 'New password (6+ characters)', obscure: true)],
        action: 'Save password',
      );
      if (v == null || !mounted) return; // still asked again next time they sign in
      final ok = await guarded(
          context,
          () => Api.call('meChangePassword', {'oldPassword': current, 'newPassword': v['np']}),
          success: 'Password changed');
      if (ok) {
        CustomerStore.instance.mustChange = false;
        return;
      }
    }
  }

  void _forgot() {
    final phones = ((RestaurantStore.instance.menu?.info['phones'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forgot your password?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Ask the manager or any staff member at Kanyatsi Restaurant to reset it for you. '
                'They will give you a temporary password. Sign in with it and you will be asked to choose your own.\n\n'
                'Your wallet, tokens, tickets and subscriptions stay safe.'),
            for (final p in phones)
              TextButton.icon(
                onPressed: () => openLink(context, 'tel:${'${p['number']}'.replaceAll(' ', '')}'),
                icon: const Icon(Icons.call, size: 18),
                label: Text('${'${p['label']}'.isEmpty ? 'Call' : p['label']}: ${p['number']}'),
              ),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text(_register ? 'Create Profile' : 'Sign In')),
        body: Narrow(
          width: 520,
          child: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              const BrandHeader(compact: true),
              const SizedBox(height: 14),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Sign in')),
                  ButtonSegment(value: true, label: Text('New profile')),
                ],
                selected: {_register},
                onSelectionChanged: (s) => setState(() => _register = s.first),
              ),
              const SizedBox(height: 8),
              const Text(
                'A profile keeps your orders, wallet, tokens, tickets and subscriptions in one place.',
                textAlign: TextAlign.center,
                style: TextStyle(color: kMuted, fontSize: 12),
              ),
              const SizedBox(height: 14),
              if (_register) ...[
                Center(
                  child: GestureDetector(
                    onTap: () async {
                      final b = await pickPhoto();
                      if (b != null) setState(() => _photo = b);
                    },
                    child: CircleAvatar(
                      radius: 44,
                      backgroundColor: kSurface2,
                      backgroundImage: _photo == null ? null : MemoryImage(_photo!),
                      child: _photo == null
                          ? const Icon(Icons.add_a_photo_outlined, color: kGold)
                          : null,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                const Center(child: Text('Profile picture (optional)', style: TextStyle(color: kMuted, fontSize: 12))),
                const SizedBox(height: 10),
                TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Your name', prefixIcon: Icon(Icons.person_outline)),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone number', prefixIcon: Icon(Icons.phone_outlined)),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pass,
                obscureText: true,
                onSubmitted: (_) => _busy ? null : _submit(),
                decoration: InputDecoration(
                    labelText: 'Password',
                    helperText: _register ? 'At least 6 characters' : null,
                    prefixIcon: const Icon(Icons.lock_outline)),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(_register ? 'Create my profile' : 'Sign in'),
              ),
              if (!_register)
                TextButton(onPressed: _forgot, child: const Text('Forgot password?')),
            ],
          ),
        ),
      );
}

// ------------------------------------------------------------- profile

class CustomerProfileScreen extends StatelessWidget {
  const CustomerProfileScreen({super.key});

  @override
  Widget build(BuildContext context) => RemoteView<Map<String, dynamic>>(
        title: 'My Profile',
        load: () async {
          final r = await Api.map('meProfile');
          final cs = CustomerStore.instance;
          cs.profile = Map<String, dynamic>.from(r['profile'] as Map);
          cs.extra = r;
          return r;
        },
        builder: (context, r, reload) {
          final p = Map<String, dynamic>.from(r['profile'] as Map);
          final rules = ((r['tokenRules'] as List?) ?? const [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          final pending = (r['pendingPayments'] as List?) ?? const [];
          Widget nav(IconData i, String t, Widget screen) => Card(
                child: ListTile(
                  leading: Icon(i, color: kGold),
                  title: Text(t),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
                    await reload();
                  },
                ),
              );
          return Narrow(
            child: ListView(
              padding: const EdgeInsets.all(14),
              children: [
                GlassCard(
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 34,
                        backgroundColor: kSurface2,
                        backgroundImage: '${p['photoUrl']}'.isEmpty ? null : NetworkImage('${p['photoUrl']}'),
                        child: '${p['photoUrl']}'.isEmpty ? const Icon(Icons.person, color: kGold, size: 34) : null,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${p['name']}', style: Theme.of(context).textTheme.titleLarge),
                            Text('${p['phone']}', style: const TextStyle(color: kMuted)),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Edit profile',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () async {
                          final v = await formDialog(context, 'Edit profile',
                              [FieldSpec('name', 'Your name', initial: '${p['name']}')]);
                          if (v == null || !context.mounted) return;
                          final b = await confirmDialog(context, 'Change picture?',
                              'Do you also want to choose a new profile picture?',
                              action: 'Choose picture');
                          Uint8List? photo;
                          if (b) photo = await pickPhoto();
                          if (!context.mounted) return;
                          final ok = await guarded(context, () async {
                            await Api.call('meUpdate', {
                              'name': v['name'],
                              if (photo != null) 'photoData': base64Encode(photo),
                              'photoMime': 'image/jpeg',
                            });
                          }, success: 'Profile updated');
                          if (ok) await reload();
                        },
                      ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: GlassCard(
                        child: Column(
                          children: [
                            const Icon(Icons.account_balance_wallet_outlined, color: kGold),
                            const SizedBox(height: 4),
                            Text(ugx(p['wallet'] as num),
                                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                            const Text('Wallet', style: TextStyle(color: kMuted, fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: GlassCard(
                        child: Column(
                          children: [
                            const Icon(Icons.stars_rounded, color: kGold),
                            const SizedBox(height: 4),
                            Text('${p['tokens']}',
                                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                            const Text('Tokens', style: TextStyle(color: kMuted, fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (pending.isNotEmpty)
                  GlassCard(
                    color: kWarnBg,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Waiting for the manager to confirm',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                        for (final x in pending)
                          Text('• ${x['note']} (${payLabel('${x['method']}')})'),
                      ],
                    ),
                  ),
                if (rules.isNotEmpty)
                  GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Earn tokens on every order',
                            style: TextStyle(fontWeight: FontWeight.w700, color: kGold)),
                        for (final x in rules)
                          Text('${ugx(x['min'] as num)} - ${(x['max'] as num) >= 1000000000 ? 'and above' : ugx(x['max'] as num)}  =  ${x['tokens']} tokens'),
                        const SizedBox(height: 4),
                        const Text('Spend tokens on meals marked with a token price.',
                            style: TextStyle(color: kMuted, fontSize: 12)),
                      ],
                    ),
                  ),
                nav(Icons.add_card, 'Top up wallet', const WalletTopUpScreen()),
                nav(Icons.receipt_long, 'My orders', const MyOrdersScreen()),
                nav(Icons.event_available, 'My event tickets', const MyTicketsScreen()),
                nav(Icons.card_membership, 'Subscriptions', const SubscriptionsScreen()),
                nav(Icons.notifications_none, 'Notifications', const CustomerNotificationsScreen()),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.password, color: kGold),
                    title: const Text('Change password'),
                    onTap: () async {
                      final v = await formDialog(context, 'Change password', const [
                        FieldSpec('old', 'Current password', obscure: true),
                        FieldSpec('new', 'New password (6+ characters)', obscure: true),
                      ]);
                      if (v == null || !context.mounted) return;
                      await guarded(
                          context,
                          () => Api.call('meChangePassword',
                              {'oldPassword': v['old'], 'newPassword': v['new']}),
                          success: 'Password changed');
                    },
                  ),
                ),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  onPressed: () async {
                    await CustomerStore.instance.logout();
                    if (context.mounted) Navigator.pop(context);
                  },
                  icon: const Icon(Icons.logout),
                  label: const Text('Sign out'),
                ),
              ],
            ),
          );
        },
      );
}

class CustomerNotificationsScreen extends StatelessWidget {
  const CustomerNotificationsScreen({super.key});
  @override
  Widget build(BuildContext context) => RemoteView<Rows>(
        title: 'Notifications',
        load: () => Api.list('meNotifications'),
        builder: (context, rows, reload) => Narrow(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (rows.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Nothing yet.')),
              for (final n in rows)
                Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: kAccent.withValues(alpha: 0.2),
                      child: Icon(notificationIcon('${n['kind']}'), color: kGold),
                    ),
                    title: Text('${n['title']}'),
                    subtitle: Text('${n['body']}\n${n['timestamp']}'),
                    isThreeLine: true,
                  ),
                ),
            ],
          ),
        ),
      );
}

// ------------------------------------------------------------- wallet

class WalletTopUpScreen extends StatefulWidget {
  const WalletTopUpScreen({super.key});
  @override
  State<WalletTopUpScreen> createState() => _WalletTopUpScreenState();
}

class _WalletTopUpScreenState extends State<WalletTopUpScreen> {
  final _amount = TextEditingController();
  int _key = 0;

  Future<void> _go() async {
    final amt = parseNum(_amount.text);
    if (amt == null || amt < 1000) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter an amount from UGX 1,000.')));
      return;
    }
    final pay = await payDialog(context, amount: amt, wallet: false, title: 'Pay in to your wallet');
    if (pay == null || !mounted) return;
    final ok = await guarded(context, () => Api.call('meTopUp', {'amount': amt.round(), ...pay}),
        success: 'Sent. Your wallet is updated when the manager confirms.');
    if (ok && mounted) {
      _amount.clear();
      setState(() => _key++);
    }
  }

  @override
  Widget build(BuildContext context) => RemoteView<Map<String, dynamic>>(
        key: ValueKey<int>(_key),
        title: 'Wallet',
        load: () async {
          final r = await Api.map('meProfile');
          CustomerStore.instance.profile = Map<String, dynamic>.from(r['profile'] as Map);
          return r;
        },
        builder: (context, r, reload) {
          final p = Map<String, dynamic>.from(r['profile'] as Map);
          final tx = (r['transactions'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          return Narrow(
            child: ListView(
              padding: const EdgeInsets.all(14),
              children: [
                GlassCard(
                  child: Column(
                    children: [
                      const Text('WALLET BALANCE', style: TextStyle(color: kGold, letterSpacing: 2, fontSize: 12)),
                      const SizedBox(height: 4),
                      Text(ugx(p['wallet'] as num),
                          style: GoogleFonts.playfairDisplay(fontSize: 34, fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _amount,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Amount to add (UGX)', prefixIcon: Icon(Icons.payments_outlined)),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _go,
                  icon: const Icon(Icons.add_card),
                  label: const Text('Top up'),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Pay by mobile money or give cash to the manager. Once he confirms, the money shows in your wallet. '
                  'You can then pay for orders, tickets and subscriptions from your wallet.',
                  style: TextStyle(color: kMuted, fontSize: 12),
                ),
                const SectionTitle('Wallet history'),
                if (tx.isEmpty) const Text('No wallet activity yet.', style: TextStyle(color: kMuted)),
                for (final t in tx)
                  Card(
                    child: ListTile(
                      leading: Icon((t['change'] as num) >= 0 ? Icons.south_west : Icons.north_east,
                          color: (t['change'] as num) >= 0 ? const Color(0xFF4CC38A) : const Color(0xFFFF9F43)),
                      title: Text('${(t['change'] as num) >= 0 ? '+' : ''}${ugx(t['change'] as num)}'),
                      subtitle: Text('${t['reason']}\n${t['timestamp']}'),
                      trailing: Text(ugx(t['balance'] as num), style: const TextStyle(color: kMuted, fontSize: 12)),
                      isThreeLine: true,
                    ),
                  ),
              ],
            ),
          );
        },
      );
}

// ------------------------------------------------------------- my orders

class MyOrdersScreen extends StatelessWidget {
  const MyOrdersScreen({super.key});
  @override
  Widget build(BuildContext context) => RemoteView<Rows>(
        title: 'My Orders',
        load: () => Api.list('meOrders'),
        builder: (context, rows, reload) => Narrow(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (rows.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('You have not ordered yet.')),
              for (final o in rows)
                Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: statusColor('${o['status']}').withValues(alpha: 0.2),
                      child: Icon(Icons.receipt_long, color: statusColor('${o['status']}')),
                    ),
                    title: Text('Order #${o['id']} • ${o['mode']}'),
                    subtitle: Text('${o['status']} • ${payLabel('${o['payment']}')} • '
                        '${(o['tokensUsed'] as num) > 0 ? '${o['tokensUsed']} tokens' : ugx(o['total'] as num)}'
                        '\n${o['createdAt']}'),
                    isThreeLine: true,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => OrderTrackingScreen(
                                orderId: (o['id'] as num).toInt(), phone: '${o['phone']}'))),
                  ),
                ),
            ],
          ),
        ),
      );
}

// ------------------------------------------------------------- events

class EventsScreen extends StatelessWidget {
  const EventsScreen({super.key});

  Future<void> _buy(BuildContext context, Map<String, dynamic> ev, Map<String, dynamic> pkg,
      Future<void> Function() reload) async {
    if (!await requireCustomer(context) || !context.mounted) return;
    final fee = pkg['fee'] as num;
    Map<String, dynamic>? pay = const {};
    if (fee > 0) {
      await CustomerStore.instance.refresh().catchError((Object _) {});
      if (!context.mounted) return;
      pay = await payDialog(context, amount: fee, title: 'Pay in advance');
      if (pay == null || !context.mounted) return;
    }
    Map<String, dynamic>? res;
    final ok = await guarded(context, () async {
      res = await Api.map('meBuyTicket', {'eventId': ev['id'], 'packageName': pkg['name'], ...?pay});
    });
    if (!ok || !context.mounted || res == null) return;
    final paid = '${res!['status']}' == 'Paid';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(paid ? 'You are in!' : 'Waiting for confirmation'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${ev['title']} • ${pkg['name']}'),
            const SizedBox(height: 10),
            if (paid) ...[
              SelectableText('${res!['code']}',
                  style: GoogleFonts.robotoMono(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: 5, color: kGold)),
              const SizedBox(height: 6),
              const Text('Show this code at the entrance.', textAlign: TextAlign.center),
            ] else
              const Text('Once the manager confirms your payment, your entry code appears under '
                  'My Profile → My event tickets.',
                  textAlign: TextAlign.center),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => RemoteView<Rows>(
        title: 'Events',
        load: () => Api.list('listEvents'),
        builder: (context, events, reload) => Narrow(
          child: ListView(
            padding: const EdgeInsets.all(14),
            children: [
              if (events.isEmpty)
                const Padding(padding: EdgeInsets.all(24), child: Text('No upcoming events right now. Check again soon!')),
              for (final e in events)
                GlassCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if ('${e['imageUrl']}'.isNotEmpty)
                        ClipRRect(
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                          child: Image.network('${e['imageUrl']}',
                              height: 180,
                              width: double.infinity,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const SizedBox(height: 60)),
                        ),
                      Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${e['title']}', style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: 4),
                            Row(children: [
                              const Icon(Icons.event, size: 16, color: kGold),
                              const SizedBox(width: 6),
                              Text('${e['date']}  ${e['time']}'),
                            ]),
                            if ('${e['details']}'.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text('${e['details']}', style: const TextStyle(color: kMuted)),
                            ],
                            const SizedBox(height: 10),
                            for (final p in (e['packages'] as List).map((x) => Map<String, dynamic>.from(x as Map)))
                              Container(
                                margin: const EdgeInsets.only(top: 6),
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                    color: kSurface2.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(14)),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text('${p['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                                          if ('${p['details']}'.isNotEmpty)
                                            Text('${p['details']}', style: const TextStyle(color: kMuted, fontSize: 12)),
                                          Text((p['fee'] as num) > 0 ? ugx(p['fee'] as num) : 'Free',
                                              style: const TextStyle(color: kGold)),
                                        ],
                                      ),
                                    ),
                                    FilledButton(
                                      onPressed: () => _buy(context, e, p, reload),
                                      child: Text((p['fee'] as num) > 0 ? 'Pay in advance' : 'Get ticket'),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
}

class MyTicketsScreen extends StatelessWidget {
  const MyTicketsScreen({super.key});
  @override
  Widget build(BuildContext context) => RemoteView<Rows>(
        title: 'My Tickets',
        load: () => Api.list('meTickets'),
        builder: (context, rows, reload) => Narrow(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (rows.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No tickets yet.')),
              for (final t in rows)
                GlassCard(
                  color: '${t['status']}' == 'Paid' ? kPanelHi : null,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${t['eventTitle']} • ${t['packageName']}',
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      Text('${t['eventDate']} ${t['eventTime']}', style: const TextStyle(color: kMuted)),
                      const SizedBox(height: 6),
                      if ('${t['status']}' == 'Paid') ...[
                        SelectableText('${t['code']}',
                            style: GoogleFonts.robotoMono(
                                fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: 5, color: kGold)),
                        Text('${t['usedAt']}'.isEmpty ? 'Show this code at the entrance.' : 'Used ${t['usedAt']}',
                            style: const TextStyle(color: kMuted, fontSize: 12)),
                      ] else
                        Text('${t['status']} - waiting for payment confirmation',
                            style: const TextStyle(color: Color(0xFFFF9F43))),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
}

// ------------------------------------------------------------- subscriptions

class SubscriptionsScreen extends StatefulWidget {
  const SubscriptionsScreen({super.key});
  @override
  State<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends State<SubscriptionsScreen> {
  bool _mine = false;

  Future<void> _subscribe(Map<String, dynamic> p) async {
    if (!await requireCustomer(context) || !mounted) return;
    await CustomerStore.instance.refresh().catchError((Object _) {});
    if (!mounted) return;
    final pay = await payDialog(context, amount: p['price'] as num, title: 'Pay for ${p['name']}');
    if (pay == null || !mounted) return;
    final ok = await guarded(context, () => Api.call('meBuyPackage', {'packageId': p['id'], ...pay}),
        success: '${pay['method']}' == 'Wallet'
            ? 'Subscription active!'
            : 'Sent. It becomes active when the manager confirms your payment.');
    if (ok && mounted) setState(() => _mine = true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Subscriptions')),
        body: Narrow(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Packages')),
                    ButtonSegment(value: true, label: Text('My subscriptions')),
                  ],
                  selected: {_mine},
                  onSelectionChanged: (s) => setState(() => _mine = s.first),
                ),
              ),
              Expanded(child: _mine ? _mineView() : _packagesView()),
            ],
          ),
        ),
      );

  Widget _packagesView() => RemoteView<Rows>(
        key: const ValueKey('pk'),
        title: '',
        bare: true,
        load: () => Api.list('listSubPackages'),
        builder: (context, rows, reload) => ListView(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
          children: [
            if (rows.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No packages yet.')),
            for (final p in rows)
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${p['name']}', style: Theme.of(context).textTheme.titleLarge),
                    if ('${p['description']}'.isNotEmpty)
                      Text('${p['description']}', style: const TextStyle(color: kMuted)),
                    const SizedBox(height: 6),
                    Text('${p['days']} days  •  ${ugx(p['price'] as num)}',
                        style: const TextStyle(color: kGold, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    for (final i in (p['items'] as List)) Text('• ${i['qty']} x ${i['name']}'),
                    const SizedBox(height: 8),
                    FilledButton(
                        onPressed: () => _subscribe(Map<String, dynamic>.from(p)),
                        child: const Text('Subscribe')),
                  ],
                ),
              ),
          ],
        ),
      );

  Widget _mineView() => RemoteView<Map<String, dynamic>>(
        key: const ValueKey('mine'),
        title: '',
        bare: true,
        load: () => Api.map('meSubscriptions'),
        builder: (context, r, reload) {
          final subs = (r['subscriptions'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          final claims = (r['openClaims'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
            children: [
              if (claims.isNotEmpty)
                GlassCard(
                  color: kPanelHi,
                  border: kGold,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("TODAY'S MEAL CODES",
                          style: TextStyle(color: kGold, fontWeight: FontWeight.w700, letterSpacing: 1.5, fontSize: 12)),
                      const Text('Give the code to the waiter when your meal is served.',
                          style: TextStyle(color: kMuted, fontSize: 12)),
                      for (final c in claims)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            children: [
                              Expanded(child: Text('${c['dishName']}')),
                              SelectableText('${c['code']}',
                                  style: GoogleFonts.robotoMono(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: 4)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              if (subs.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('You have no subscriptions yet.')),
              for (final s in subs)
                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text('${s['packageName']}', style: Theme.of(context).textTheme.titleMedium)),
                          Chip(label: Text('${s['status']}')),
                        ],
                      ),
                      if ('${s['status']}' == 'Pending')
                        const Text('Waiting for payment confirmation.', style: TextStyle(color: Color(0xFFFF9F43))),
                      if ('${s['endDate']}'.isNotEmpty)
                        Text('${s['startDate']} to ${s['endDate']}  •  ${s['daysLeft']} days left',
                            style: const TextStyle(color: kMuted, fontSize: 12)),
                      const SizedBox(height: 6),
                      for (final b in (s['balances'] as List))
                        Row(
                          children: [
                            Expanded(child: Text('${b['name']}  •  ${b['qty']} left')),
                            if ('${s['status']}' == 'Active' && (b['qty'] as num) > 0)
                              TextButton(
                                onPressed: () async {
                                  Map<String, dynamic>? res;
                                  final ok = await guarded(context, () async {
                                    res = await Api.map('meClaimMeal', {'subId': s['id'], 'dishId': b['dishId']});
                                  });
                                  if (ok) await reload();
                                  if (ok && res != null && context.mounted) {
                                    await showDialog<void>(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        title: Text('${res!['dishName']}'),
                                        content: Column(mainAxisSize: MainAxisSize.min, children: [
                                          SelectableText('${res!['code']}',
                                              style: GoogleFonts.robotoMono(
                                                  fontSize: 32, fontWeight: FontWeight.w800, letterSpacing: 6, color: kGold)),
                                          const SizedBox(height: 8),
                                          const Text('Show this code to the waiter. It is valid today only.',
                                              textAlign: TextAlign.center),
                                        ]),
                                        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
                                      ),
                                    );
                                  }
                                },
                                child: const Text('Choose today'),
                              ),
                          ],
                        ),
                      if ('${s['status']}' == 'Active')
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () async {
                              final v = await formDialog(context, 'Skip days', const [
                                FieldSpec('days', 'How many days will you miss? (1-7)',
                                    initial: '1', keyboard: TextInputType.number),
                              ], action: 'Skip');
                              if (v == null || !context.mounted) return;
                              final ok = await guarded(
                                  context,
                                  () => Api.call('meSkipDays',
                                      {'subId': s['id'], 'days': int.tryParse(v['days'] ?? '') ?? 0}),
                                  success: 'Done. Your end date moved forward.');
                              if (ok) await reload();
                            },
                            icon: const Icon(Icons.pause_circle_outline),
                            label: Text('Skip days (${s['pausedDays']}/14 used)'),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
      );
}

// ------------------------------------------------------------- contact & social

Future<void> openLink(BuildContext context, String url) async {
  if (url.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This link has not been added yet.')));
    return;
  }
  try {
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open the link.')));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open the link.')));
    }
  }
}

class ContactSection extends StatelessWidget {
  final Map<String, dynamic> info;
  const ContactSection(this.info, {super.key});

  @override
  Widget build(BuildContext context) {
    final location = '${info['location'] ?? ''}';
    final phones = ((info['phones'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final social = Map<String, dynamic>.from((info['social'] as Map?) ?? const {});
    Widget icon(String asset, String label, String key, Color c) {
      final url = '${social[key] ?? ''}';
      return Column(
        children: [
          Opacity(
            opacity: url.isEmpty ? 0.35 : 1,
            child: InkWell(
              borderRadius: BorderRadius.circular(30),
              onTap: () => openLink(context, url),
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(color: c.withValues(alpha: 0.18), shape: BoxShape.circle,
                    border: Border.all(color: c.withValues(alpha: 0.6))),
                child: Padding(
                  padding: const EdgeInsets.all(13),
                  child: Image.asset(asset, color: c, fit: BoxFit.contain),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 11, color: kMuted)),
        ],
      );
    }

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Find us', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.location_on_outlined, color: kGold),
              const SizedBox(width: 10),
              Expanded(child: Text(location.isEmpty ? 'Kagando, Uganda' : location)),
            ],
          ),
          if (phones.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Service numbers', style: TextStyle(color: kGold, fontWeight: FontWeight.w700)),
            for (final p in phones)
              InkWell(
                onTap: () => openLink(context, 'tel:${'${p['number']}'.replaceAll(' ', '')}'),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.phone_in_talk_outlined, size: 18, color: kGold),
                      const SizedBox(width: 10),
                      Expanded(child: Text('${'${p['label']}'.isEmpty ? '' : '${p['label']}: '}${p['number']}')),
                      const Icon(Icons.call, size: 18, color: kMuted),
                    ],
                  ),
                ),
              ),
          ],
          const SizedBox(height: 14),
          const Text('Connect with us', style: TextStyle(color: kGold, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              icon('assets/social/whatsapp.png', 'WhatsApp', 'whatsapp', const Color(0xFF25D366)),
              icon('assets/social/instagram.png', 'Instagram', 'instagram', const Color(0xFFE1306C)),
              icon('assets/social/email.png', 'Email', 'email', const Color(0xFFE3B05A)),
              icon('assets/social/x.png', 'X', 'x', Colors.white),
            ],
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- order tracking extras

/// Everything under the status on the customer's order screen: code, payment steps,
/// "Receive food" and the receipt.
class TrackingExtras extends StatelessWidget {
  final Map<String, dynamic> r;
  final String phone;
  final Future<void> Function() onChanged;
  const TrackingExtras({required this.r, required this.phone, required this.onChanged, super.key});

  @override
  Widget build(BuildContext context) {
    final id = (r['id'] as num).toInt();
    final status = '${r['status']}';
    final mode = '${r['mode']}';
    final pay = '${r['paymentMethod']}';
    final payStatus = '${r['paymentStatus']}';
    final code = '${r['code'] ?? ''}';
    final open = !['Completed', 'Rejected', 'Cancelled', 'Failed'].contains(status);
    final children = <Widget>[];

    if (code.isNotEmpty && open) {
      children.add(DeliveryCodeCard(
        code,
        title: mode == 'Delivery' ? 'YOUR DELIVERY CODE' : 'YOUR ORDER CODE',
        message: mode == 'Delivery'
            ? 'Show this code to the delivery man when he arrives. It can be used only once, so do not share it with anyone else.'
            : 'Keep this code. Show it to your waiter when you pay in cash, or if staff need to check your order.',
      ));
    }
    if (pay == 'Cash' && payStatus == 'Unpaid' && open && mode != 'Delivery') {
      children.add(const Padding(
        padding: EdgeInsets.only(top: 6),
        child: Text('Pay your waiter in cash and show your order code. The waiter records it.',
            style: TextStyle(color: kMuted, fontSize: 12)),
      ));
    }
    if (isMomo(pay) && payStatus == 'Unpaid' && open) {
      children.add(MomoInstructions(pay));
      children.add(FilledButton.icon(
        onPressed: () async {
          final v = await proofDialog(context, provider: payLabel(pay), phone: phone);
          if (v == null || !context.mounted) return;
          final ok = await guarded(context, () => Api.call('submitPaymentProof', {'orderId': id, 'phone': phone, ...v}),
              success: 'Sent. The manager will check and confirm your payment.');
          if (ok) await onChanged();
        },
        icon: const Icon(Icons.check_circle_outline),
        label: const Text('I have made the payment'),
      ));
    }
    if (payStatus == 'Proof submitted') {
      children.add(GlassCard(
        color: kWarnBg,
        child: const Row(children: [
          Icon(Icons.hourglass_top, color: Color(0xFFFF9F43)),
          SizedBox(width: 10),
          Expanded(child: Text('Payment sent. Waiting for the manager to confirm it.')),
        ]),
      ));
    }
    if (status == 'Serving') {
      final sc = '${r['serveCode'] ?? ''}';
      if (sc.isEmpty) {
        children.add(FilledButton.icon(
          onPressed: () async {
            final ok = await guarded(context, () => Api.call('receiveFood', {'orderId': id, 'phone': phone}));
            if (ok) await onChanged();
          },
          icon: const Icon(Icons.restaurant),
          label: const Text('Receive food'),
        ));
      } else {
        children.add(DeliveryCodeCard(
          sc,
          title: 'GIVE THIS CODE TO YOUR WAITER',
          message: 'Your waiter enters this code to confirm that you received your food.',
        ));
      }
    }
    if (status == 'Completed' && r['receipt'] != null) {
      children.add(OutlinedButton.icon(
        onPressed: () => showReceipt(context, Map<String, dynamic>.from(r['receipt'] as Map)),
        icon: const Icon(Icons.receipt_long),
        label: const Text('View receipt'),
      ));
    }
    if (((r['tokensEarned'] ?? 0) as num) > 0) {
      children.add(GlassCard(
        color: kPanelHi,
        child: Row(children: [
          const Icon(Icons.stars_rounded, color: kGold),
          const SizedBox(width: 10),
          Expanded(child: Text('You earned ${r['tokensEarned']} tokens with this order!')),
        ]),
      ));
    }
    if (r['codeUsed'] == true && mode == 'Delivery' && status == 'Completed') {
      children.add(const Padding(
        padding: EdgeInsets.only(top: 6),
        child: Text('Your delivery code has been used. Thank you!', style: TextStyle(color: kMuted, fontSize: 12)),
      ));
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

// ------------------------------------------------------------- menu background by food category

class MenuBackdropFrame extends StatelessWidget {
  final RestaurantStore store;
  final String category;
  final Widget child;
  const MenuBackdropFrame({required this.store, required this.category, required this.child, super.key});

  List<String> _urls() {
    final m = store.menu;
    if (m == null) return const [];
    final out = <String>[];
    if (category == 'All' || category == 'Combos') {
      for (final e in m.categoryImages.entries) {
        out.addAll(e.value.take(2));
      }
      final seen = <String, int>{};
      for (final d in m.dishes) {
        if (d.imageUrl.isEmpty) continue;
        final n = seen[d.category] ?? 0;
        if (n < 2) {
          out.add(d.imageUrl);
          seen[d.category] = n + 1;
        }
      }
    } else {
      out.addAll(m.categoryImages[category] ?? const []);
      out.addAll(m.dishes.where((d) => d.category == category && d.imageUrl.isNotEmpty).map((d) => d.imageUrl));
    }
    return out.toSet().take(12).toList();
  }

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          CategorySlideshow(key: ValueKey<String>(category), urls: _urls()),
          child,
        ],
      );
}

class CategorySlideshow extends StatefulWidget {
  final List<String> urls;
  const CategorySlideshow({required this.urls, super.key});
  @override
  State<CategorySlideshow> createState() => _CategorySlideshowState();
}

class _CategorySlideshowState extends State<CategorySlideshow> {
  int _i = 0;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || widget.urls.length < 2) return;
      final next = (_i + 1) % widget.urls.length;
      precacheImage(NetworkImage(widget.urls[next]), context).catchError((Object _) {});
      setState(() => _i = next);
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.urls.isEmpty) return const SizedBox.shrink();
    final url = widget.urls[_i % widget.urls.length];
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 1600),
          child: _Slide(key: ValueKey<String>('$_i$url'), image: NetworkImage(url)),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                kBg.withValues(alpha: 0.70),
                kBg.withValues(alpha: 0.55),
                kBg.withValues(alpha: 0.80),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
