part of 'main.dart';

// ======================================================== STAFF: payments, team, activity, events...

Future<String?> codeDialog(BuildContext context, String title,
    {String hint = 'CODE', String message = '', bool digits = false, String action = 'Continue'}) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (message.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(message)),
          TextField(
            controller: c,
            autofocus: true,
            maxLength: 10,
            autocorrect: false,
            textCapitalization: TextCapitalization.characters,
            keyboardType: digits ? TextInputType.number : TextInputType.text,
            textAlign: TextAlign.center,
            style: GoogleFonts.robotoMono(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 5),
            decoration: InputDecoration(hintText: hint, counterText: ''),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(action)),
      ],
    ),
  );
}

void say(BuildContext context, String m) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

// ------------------------------------------------------------- waiter desk

class WaiterDeskScreen extends StatelessWidget {
  const WaiterDeskScreen({super.key});

  Future<void> _collectByCode(BuildContext context, Future<void> Function() reload) async {
    final code = await codeDialog(context, "Customer's order code",
        message: 'Ask the customer for the code shown on their order screen.');
    if (code == null || code.isEmpty || !context.mounted) return;
    Map<String, dynamic>? chk;
    final found = await guarded(context, () async {
      chk = await Api.map('checkCode', {'code': code});
    });
    if (!found || chk == null || !context.mounted) return;
    if ('${chk!['type']}' != 'order') {
      say(context, 'That is not an order code.');
      return;
    }
    final o = Map<String, dynamic>.from(chk!['order'] as Map);
    final yes = await confirmDialog(
        context,
        'CASH COLLECTED?',
        'Order #${o['id']}\nAmount: ${ugx(o['total'] as num)}\n\n'
        'MAKE SURE YOU HAVE COLLECTED THE CASH before you press the button.',
        action: 'Cash collected');
    if (!yes || !context.mounted) return;
    final ok = await guarded(context, () => Api.call('collectCash', {'code': code}),
        success: 'Cash recorded. Give it to the manager together with this order code.');
    if (ok) await reload();
  }

  List<Widget> _actions(BuildContext context, Map<String, dynamic> o, Future<void> Function() reload) {
    final id = (o['id'] as num).toInt();
    final status = '${o['status']}';
    final pay = '${o['payment']}';
    final payStatus = '${o['paymentStatus']}';
    final fromApp = '${o['source']}' == 'app';
    final out = <Widget>[];
    final closed = ['Rejected', 'Cancelled', 'Failed', 'Completed'].contains(status);
    if (!closed && pay == 'Cash' && payStatus == 'Unpaid') {
      out.add(FilledButton.icon(
        onPressed: () async {
          if (fromApp) {
            await _collectByCode(context, reload);
          } else {
            final yes = await confirmDialog(
                context,
                'CASH COLLECTED?',
                'Order #$id\nAmount: ${ugx(o['total'] as num)}\n\nMAKE SURE YOU HAVE COLLECTED THE CASH.',
                action: 'Cash collected');
            if (!yes || !context.mounted) return;
            final ok = await guarded(context, () => Api.call('collectCash', {'id': id}),
                success: 'Cash recorded. Hand it to the manager.');
            if (ok) await reload();
          }
        },
        icon: const Icon(Icons.payments_outlined),
        label: Text(fromApp ? 'Collect cash (customer code)' : 'I collected the cash'),
      ));
    }
    if (!closed && isMomo(pay) && payStatus == 'Unpaid') {
      out.add(OutlinedButton.icon(
        onPressed: () async {
          final v = await proofDialog(context, provider: payLabel(pay));
          if (v == null || !context.mounted) return;
          final ok = await guarded(context, () => Api.call('staffPaymentProof', {'id': id, ...v}),
              success: 'Sent to the manager for approval');
          if (ok) await reload();
        },
        icon: const Icon(Icons.phone_android),
        label: const Text('Send payment proof'),
      ));
    }
    if (status == 'Assigned' && '${o['mode']}' != 'Delivery') {
      out.add(FilledButton.icon(
        onPressed: () async {
          final ok = await guarded(context, () => Api.call(fromApp ? 'serveOrder' : 'completeOrder', {'id': id}),
              success: fromApp ? 'Served. The customer can now press Receive food.' : 'Order completed');
          if (ok) await reload();
        },
        icon: const Icon(Icons.restaurant),
        label: Text(fromApp ? 'Serve food' : 'Mark served'),
      ));
    }
    if (status == 'Serving') {
      out.add(FilledButton.icon(
        onPressed: () async {
          final code = await codeDialog(context, "Customer's received code",
              message: 'The customer presses "Receive food" in their app and shows you a 6-digit code.',
              digits: true);
          if (code == null || code.isEmpty || !context.mounted) return;
          final ok = await guarded(context, () => Api.call('completeServe', {'id': id, 'code': code}),
              success: 'Order completed. Thank you!');
          if (ok) await reload();
        },
        icon: const Icon(Icons.pin_outlined),
        label: const Text("Enter customer's code"),
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) => RemoteView<Map<String, dynamic>>(
        title: 'My Orders',
        load: () => Api.map('waiterDesk'),
        autoRefresh: const Duration(seconds: 15),
        actions: [
          IconButton(
            tooltip: 'Check a code',
            icon: const Icon(Icons.fact_check_outlined),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const CheckCodeScreen())),
          ),
        ],
        builder: (context, r, reload) {
          final orders = (r['orders'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          final owed = (r['outstanding'] as num);
          return Narrow(
            width: 900,
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                GlassCard(
                  color: owed > 0 ? kWarnBg : kOkBg,
                  border: owed > 0 ? const Color(0xFFFF9F43) : const Color(0xFF4CC38A),
                  child: Row(
                    children: [
                      Icon(owed > 0 ? Icons.account_balance_wallet : Icons.verified, size: 30,
                          color: owed > 0 ? const Color(0xFFFF9F43) : const Color(0xFF4CC38A)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('CASH YOU MUST HAND IN', style: TextStyle(fontSize: 11, letterSpacing: 1.5, color: kMuted)),
                            Text(ugx(owed), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                            Text(owed > 0
                                ? '${r['outstandingCount']} order(s). Give the cash and each order code to the manager.'
                                : 'Nothing to hand in. Mobile money payments are not counted here.',
                                style: const TextStyle(color: kMuted, fontSize: 12)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => const RecordOrderScreen())).then((_) => reload()),
                        icon: const Icon(Icons.add_circle_outline),
                        label: const Text('Take an order'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.push(
                            context, MaterialPageRoute(builder: (_) => const CheckCodeScreen())),
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Check a code'),
                      ),
                    ),
                  ],
                ),
                if (orders.isEmpty)
                  const Padding(padding: EdgeInsets.all(24), child: Text('No orders for you right now.')),
                for (final o in orders) OrderCard(o, actions: _actions(context, o, reload)),
              ],
            ),
          );
        },
      );
}

// ------------------------------------------------------------- check any code

class CheckCodeScreen extends StatefulWidget {
  const CheckCodeScreen({super.key});
  @override
  State<CheckCodeScreen> createState() => _CheckCodeScreenState();
}

class _CheckCodeScreenState extends State<CheckCodeScreen> {
  final _code = TextEditingController();
  Map<String, dynamic>? _res;
  bool _invalid = false;
  bool _busy = false;

  Future<void> _check() async {
    final code = _code.text.trim();
    if (code.length < 4) return;
    setState(() {
      _busy = true;
      _res = null;
      _invalid = false;
    });
    try {
      final r = await Api.map('checkCode', {'code': code});
      if (!mounted) return;
      setState(() => _res = r);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.message == kSessionExpired) {
        handleSessionExpired(context);
        return;
      }
      setState(() => _invalid = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _result() {
    if (_invalid) {
      return GlassCard(
        color: const Color(0xFF3A1512),
        border: const Color(0xFFFF5A4D),
        child: const Row(children: [
          Icon(Icons.cancel, color: Color(0xFFFF5A4D), size: 32),
          SizedBox(width: 12),
          Expanded(child: Text('INVALID CODE', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18))),
        ]),
      );
    }
    final r = _res;
    if (r == null) return const SizedBox.shrink();
    final type = '${r['type']}';
    if (type == 'order') {
      final o = Map<String, dynamic>.from(r['order'] as Map);
      final done = r['completed'] == true;
      return Column(children: [
        GlassCard(
          color: done ? kOkBg : kWarnBg,
          border: done ? const Color(0xFF4CC38A) : const Color(0xFFFF9F43),
          child: Row(children: [
            Icon(done ? Icons.verified : Icons.hourglass_top, size: 32,
                color: done ? const Color(0xFF4CC38A) : const Color(0xFFFF9F43)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(done ? 'COMPLETED' : (r['pending'] == true ? 'PENDING' : '${o['status']}'.toUpperCase()),
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            ),
          ]),
        ),
        OrderCard(o),
      ]);
    }
    if (type == 'event') {
      final t = Map<String, dynamic>.from(r['ticket'] as Map);
      final used = '${t['usedAt']}'.isNotEmpty;
      return GlassCard(
        color: used ? kWarnBg : kOkBg,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('EVENT TICKET', style: TextStyle(color: used ? const Color(0xFFFF9F43) : const Color(0xFF4CC38A), fontWeight: FontWeight.w800)),
          Text('${t['eventTitle']} • ${t['packageName']}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          Text('${t['customerName']}'),
          Text('${t['eventDate']} ${t['eventTime']}', style: const TextStyle(color: kMuted)),
          const SizedBox(height: 8),
          if (used)
            Text('Already used ${t['usedAt']} by ${t['usedBy']}')
          else
            FilledButton.icon(
              onPressed: () async {
                final ok = await guarded(context, () => Api.call('admitEventCode', {'code': _code.text.trim()}),
                    success: 'Welcome in! Ticket marked as used.');
                if (ok) await _check();
              },
              icon: const Icon(Icons.login),
              label: const Text('Admit guest'),
            ),
        ]),
      );
    }
    final c = Map<String, dynamic>.from(r['claim'] as Map);
    final open = '${c['status']}' == 'Open';
    return GlassCard(
      color: open ? kOkBg : kWarnBg,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('SUBSCRIPTION MEAL', style: TextStyle(color: kGold, fontWeight: FontWeight.w800)),
        Text('${c['dishName']}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        Text('${c['customerName']} • ${c['date']} • ${c['status']}'),
        const SizedBox(height: 8),
        if (open)
          FilledButton.icon(
            onPressed: () async {
              var mode = 'Takeaway';
              int? table;
              final go = await showDialog<bool>(
                context: context,
                builder: (ctx) => StatefulBuilder(
                  builder: (ctx, setS) => AlertDialog(
                    title: const Text('Serve this meal'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'Takeaway', label: Text('Takeaway')),
                          ButtonSegment(value: 'Indoor', label: Text('Indoor')),
                        ],
                        selected: {mode},
                        onSelectionChanged: (s) => setS(() => mode = s.first),
                      ),
                      if (mode == 'Indoor')
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: TextField(
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: 'Table number'),
                            onChanged: (v) => table = int.tryParse(v),
                          ),
                        ),
                    ]),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send to kitchen')),
                    ],
                  ),
                ),
              );
              if (go != true || !mounted) return;
              final ok = await guarded(
                  context,
                  () => Api.call('redeemSubscriptionCode',
                      {'code': _code.text.trim(), 'mode': mode, 'table': table}),
                  success: 'Marked as paid subscription meal and sent to the kitchen.');
              if (ok) await _check();
            },
            icon: const Icon(Icons.restaurant_menu),
            label: const Text('Redeem and send to kitchen'),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Check a Code')),
        body: Narrow(
          width: 640,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                  'Enter the code a customer shows you. It can be an order code, an event ticket or a subscription meal code.',
                  style: TextStyle(color: kMuted)),
              const SizedBox(height: 12),
              TextField(
                controller: _code,
                autofocus: true,
                maxLength: 10,
                autocorrect: false,
                textCapitalization: TextCapitalization.characters,
                textAlign: TextAlign.center,
                onSubmitted: (_) => _check(),
                style: GoogleFonts.robotoMono(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 5),
                decoration: const InputDecoration(hintText: 'CODE', counterText: ''),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : _check,
                icon: const Icon(Icons.search),
                label: const Text('Check'),
              ),
              const SizedBox(height: 12),
              _result(),
            ],
          ),
        ),
      );
}

// ------------------------------------------------------------- payments desk (manager)

class PaymentsDeskScreen extends StatelessWidget {
  const PaymentsDeskScreen({super.key});

  @override
  Widget build(BuildContext context) => RemoteView<Map<String, dynamic>>(
        title: 'Payments',
        load: () => Api.map('paymentsDesk'),
        autoRefresh: const Duration(seconds: 15),
        builder: (context, r, reload) {
          List<Map<String, dynamic>> list(String k) =>
              (r[k] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          final cash = list('cash'), proofs = list('proofs'), reqs = list('requests'), by = list('byWaiter');
          return Narrow(
            width: 900,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 30),
              children: [
                const SectionTitle('Cash with waiters'),
                if (cash.isEmpty) const Text('No cash waiting to be handed in.', style: TextStyle(color: kMuted)),
                for (final w in by)
                  GlassCard(
                    color: kWarnBg,
                    child: Row(children: [
                      const Icon(Icons.person, color: kGold),
                      const SizedBox(width: 10),
                      Expanded(child: Text('${w['waiter']} must hand in ${w['orders']} order(s)')),
                      Text(ugx(w['total'] as num), style: const TextStyle(fontWeight: FontWeight.w800)),
                    ]),
                  ),
                for (final o in cash)
                  OrderCard(o, actions: [
                    FilledButton.icon(
                      onPressed: () async {
                        final code = await codeDialog(context, 'Cash received?',
                            message: '${o['cashByName']} hands you ${ugx(o['total'] as num)} for order #${o['id']}.\n'
                                'Enter the order code the waiter shows you.',
                            action: 'Cash received');
                        if (code == null || code.isEmpty || !context.mounted) return;
                        final ok = await guarded(context, () => Api.call('receiveCash', {'code': code}),
                            success: 'Cash received and recorded');
                        if (ok) await reload();
                      },
                      icon: const Icon(Icons.price_check),
                      label: const Text('Cash received (enter code)'),
                    ),
                  ]),
                const SectionTitle('Mobile money to verify'),
                if (proofs.isEmpty) const Text('Nothing to verify.', style: TextStyle(color: kMuted)),
                for (final o in proofs)
                  OrderCard(o, actions: [
                    if ('${o['proofUrl']}'.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () => showDialog<void>(
                            context: context,
                            builder: (ctx) => Dialog(child: InteractiveViewer(child: Image.network('${o['proofUrl']}')))),
                        icon: const Icon(Icons.image_outlined),
                        label: const Text('View screenshot'),
                      ),
                    FilledButton.icon(
                      onPressed: () async {
                        final ok = await guarded(context, () => Api.call('confirmPayment', {'id': o['id']}),
                            success: 'Payment approved');
                        if (ok) await reload();
                      },
                      icon: const Icon(Icons.check),
                      label: const Text('Approve payment'),
                    ),
                    OutlinedButton(
                      onPressed: () => reasonAction(context, 'Reject payment', 'rejectPayment',
                          (o['id'] as num).toInt(), reload, success: 'Payment rejected'),
                      child: const Text('Details do not match'),
                    ),
                  ]),
                const SectionTitle('Wallet, ticket and subscription payments'),
                if (reqs.isEmpty) const Text('Nothing waiting.', style: TextStyle(color: kMuted)),
                for (final q in reqs)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${q['note']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text('${q['customerName']} • ${ugx(q['amount'] as num)} • ${payLabel('${q['method']}')}'),
                          if ('${q['phone']}'.isNotEmpty || '${q['txnId']}'.isNotEmpty)
                            Text('From ${q['phone']}  ID ${q['txnId']}', style: const TextStyle(color: kMuted, fontSize: 12)),
                          if ('${q['method']}' == 'Cash')
                            const Text('Customer is paying cash to you. Confirm only when you have the money.',
                                style: TextStyle(color: kGold, fontSize: 12)),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            children: [
                              if ('${q['proofUrl']}'.isNotEmpty)
                                OutlinedButton.icon(
                                  onPressed: () => showDialog<void>(
                                      context: context,
                                      builder: (ctx) => Dialog(child: InteractiveViewer(child: Image.network('${q['proofUrl']}')))),
                                  icon: const Icon(Icons.image_outlined),
                                  label: const Text('Screenshot'),
                                ),
                              FilledButton.icon(
                                onPressed: () async {
                                  final ok = await guarded(
                                      context, () => Api.call('confirmPaymentRequest', {'id': q['id']}),
                                      success: 'Confirmed');
                                  if (ok) await reload();
                                },
                                icon: const Icon(Icons.check),
                                label: const Text('Confirmed'),
                              ),
                              OutlinedButton(
                                onPressed: () => reasonAction(context, 'Reject', 'rejectPaymentRequest',
                                    (q['id'] as num).toInt(), reload, success: 'Rejected'),
                                child: const Text('Reject'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      );
}

// ------------------------------------------------------------- team for the day

class AttendanceScreen extends StatelessWidget {
  const AttendanceScreen({super.key});
  @override
  Widget build(BuildContext context) => RemoteView<Map<String, dynamic>>(
        title: "Today's Team",
        load: () => Api.map('getAttendance'),
        builder: (context, r, reload) => _AttendanceForm(data: r, reload: reload),
      );
}

class _AttendanceForm extends StatefulWidget {
  final Map<String, dynamic> data;
  final Future<void> Function() reload;
  const _AttendanceForm({required this.data, required this.reload});
  @override
  State<_AttendanceForm> createState() => _AttendanceFormState();
}

class _AttendanceFormState extends State<_AttendanceForm> {
  late final Set<int> _sel;
  late bool _auto;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final staff = (widget.data['staff'] as List).map((e) => Map<String, dynamic>.from(e as Map));
    _sel = {for (final s in staff) if (s['present'] == true) (s['id'] as num).toInt()};
    _auto = widget.data['autoAssign'] != false;
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    Map<String, dynamic>? res;
    final ok = await guarded(context, () async {
      res = await Api.map('setAttendance', {'userIds': _sel.toList(), 'autoAssign': _auto});
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      say(context, 'Saved. ${(res?['assigned'] ?? 0)} waiting order(s) were given out.');
      await widget.reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final staff = (widget.data['staff'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final isSet = widget.data['isSet'] == true;
    Widget group(String role, String title) {
      final list = staff.where((s) => '${s['role']}' == role).toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(title),
          if (list.isEmpty) Text('No ${title.toLowerCase()} yet.', style: const TextStyle(color: kMuted)),
          for (final s in list)
            Card(
              child: SwitchListTile(
                value: _sel.contains((s['id'] as num).toInt()),
                onChanged: (v) => setState(() {
                  final id = (s['id'] as num).toInt();
                  if (v) {
                    _sel.add(id);
                  } else {
                    _sel.remove(id);
                  }
                }),
                title: Text('${s['name']}'),
                subtitle: Text(_sel.contains((s['id'] as num).toInt()) ? 'Working today' : 'Not working today'),
              ),
            ),
        ],
      );
    }

    return Narrow(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 30),
        children: [
          GlassCard(
            color: isSet ? kOkBg : kWarnBg,
            child: Row(children: [
              Icon(isSet ? Icons.check_circle : Icons.info_outline, color: kGold),
              const SizedBox(width: 10),
              Expanded(
                child: Text(isSet
                    ? "Today's team is set (${widget.data['date']}). You can still change it."
                    : "A new day has started. Choose who is working today, then save. Orders are given only to workers marked here."),
              ),
            ]),
          ),
          group('waiter', 'Waiters'),
          group('delivery', 'Delivery men'),
          group('kitchen', 'Kitchen'),
          const SizedBox(height: 6),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _auto,
            onChanged: (v) => setState(() => _auto = v),
            title: const Text('Give out ready orders automatically'),
            subtitle: const Text('To the free worker who has completed the fewest tasks today.'),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text("Save today's team"),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- staff activity

class WorkerStatsScreen extends StatefulWidget {
  const WorkerStatsScreen({super.key});
  @override
  State<WorkerStatsScreen> createState() => _WorkerStatsScreenState();
}

class _WorkerStatsScreenState extends State<WorkerStatsScreen> {
  int days = 7;

  @override
  Widget build(BuildContext context) => RemoteView<Map<String, dynamic>>(
        key: ValueKey<int>(days),
        title: 'Staff Activity',
        load: () => Api.map('workerStats', {'days': days}),
        builder: (context, r, reload) {
          final workers = (r['workers'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          final daily = (r['daily'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          Widget role(String key, String title, String taskLabel) {
            final ws = workers.where((w) => '${w['role']}' == key).toList()
              ..sort((a, b) => (b['tasks'] as num).compareTo(a['tasks'] as num));
            final dailySeries = <Map<String, dynamic>>[
              for (final d in daily) {'label': '${d['date']}'.substring(5), 'v': (d[key] as num).toDouble()}
            ];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionTitle(title),
                if (ws.isEmpty) const Text('No one with this role yet.', style: TextStyle(color: kMuted)),
                if (ws.isNotEmpty)
                  GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('$taskLabel per person', style: const TextStyle(color: kGold, fontWeight: FontWeight.w700)),
                        BarChart(<Map<String, dynamic>>[
                          for (final w in ws) {'label': '${w['name']}', 'v': (w['tasks'] as num).toDouble()}
                        ], 'v'),
                        const SizedBox(height: 10),
                        Text('$taskLabel per day', style: const TextStyle(color: kGold, fontWeight: FontWeight.w700)),
                        BarChart(dailySeries, 'v'),
                      ],
                    ),
                  ),
                for (final w in ws)
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: ((w['tasks'] as num) == 0 ? const Color(0xFFFF5A4D) : const Color(0xFF4CC38A))
                            .withValues(alpha: 0.18),
                        child: Icon((w['tasks'] as num) == 0 ? Icons.person_off : Icons.person,
                            color: (w['tasks'] as num) == 0 ? const Color(0xFFFF5A4D) : const Color(0xFF4CC38A)),
                      ),
                      title: Text('${w['name']}  •  ${w['tasks']} task(s)',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        key == 'kitchen'
                            ? 'Cooked ${w['cooked']} • present ${w['daysPresent']} day(s)'
                            : key == 'waiter'
                                ? 'Completed ${w['completed']} • took ${w['recorded']} orders • cash taken ${ugx(w['cashCollected'] as num)}'
                                    '${(w['cashOutstanding'] as num) > 0 ? ' • still owes ${ugx(w['cashOutstanding'] as num)}' : ''} • present ${w['daysPresent']} day(s)'
                                : 'Deliveries ${w['completed']} • present ${w['daysPresent']} day(s)',
                      ),
                      isThreeLine: true,
                      trailing: (w['tasks'] as num) == 0
                          ? const Text('No activity', style: TextStyle(color: Color(0xFFFF5A4D), fontSize: 11))
                          : null,
                    ),
                  ),
              ],
            );
          }

          return Narrow(
            width: 900,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 30),
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    for (final d in [7, 14, 30])
                      ChoiceChip(
                        label: Text('$d days'),
                        selected: days == d,
                        onSelected: (_) => setState(() => days = d),
                      ),
                  ],
                ),
                role('waiter', 'Waiters', 'Tasks'),
                role('kitchen', 'Kitchen', 'Orders cooked'),
                role('delivery', 'Delivery men', 'Deliveries'),
              ],
            ),
          );
        },
      );
}

// ------------------------------------------------------------- table codes

class TableCodesScreen extends StatefulWidget {
  const TableCodesScreen({super.key});
  @override
  State<TableCodesScreen> createState() => _TableCodesScreenState();
}

class _TableCodesScreenState extends State<TableCodesScreen> {
  final _count = TextEditingController();
  int _key = 0;

  @override
  Widget build(BuildContext context) => RemoteView<Map<String, dynamic>>(
        key: ValueKey<int>(_key),
        title: 'Table Codes',
        load: () => Api.map('listTableCodes'),
        builder: (context, r, reload) {
          final codes = (r['codes'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          if (_count.text.isEmpty) _count.text = '${codes.length}';
          final required = r['required'] == true;
          return Narrow(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 30),
              children: [
                const Text(
                  'Give each table its own 6-digit code and write it on the table. Customers must type the code '
                  'of their table before they can order. Switch it off if you do not want a code.',
                  style: TextStyle(color: kMuted),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: required,
                  title: const Text('Customers must enter the table code'),
                  onChanged: (v) async {
                    final ok = await guarded(context, () => Api.call('setTableCodesRequired', {'required': v}));
                    if (ok) setState(() => _key++);
                  },
                ),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _count,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'How many tables?'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: () async {
                      final n = int.tryParse(_count.text.trim()) ?? 0;
                      final yes = await confirmDialog(context, 'Generate new codes?',
                          'This creates $n new codes and switches table codes ON. Old codes stop working, so you must '
                          'write the new ones on the tables.',
                          action: 'Generate');
                      if (!yes || !context.mounted) return;
                      final ok = await guarded(context, () => Api.call('generateTableCodes', {'count': n}),
                          success: 'Codes created');
                      if (ok) {
                        _count.clear();
                        setState(() => _key++);
                      }
                    },
                    icon: const Icon(Icons.casino_outlined),
                    label: const Text('Generate'),
                  ),
                ]),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(
                        text: codes.map((c) => 'Table ${c['table']}: ${c['code']}').join('\n')));
                    say(context, 'All codes copied. Paste them to print or share.');
                  },
                  icon: const Icon(Icons.copy_all),
                  label: const Text('Copy all codes'),
                ),
                const SectionTitle('Codes'),
                if (codes.every((c) => '${c['code']}'.isEmpty))
                  const Text('No codes yet. Press Generate.', style: TextStyle(color: kMuted)),
                for (final c in codes)
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(
                          backgroundColor: kAccent.withValues(alpha: 0.2),
                          child: Text('${c['table']}', style: const TextStyle(fontWeight: FontWeight.w800))),
                      title: Text('Table ${c['table']}'),
                      trailing: Text('${c['code']}'.isEmpty ? '-' : '${c['code']}',
                          style: GoogleFonts.robotoMono(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: 3, color: kGold)),
                    ),
                  ),
              ],
            ),
          );
        },
      );
}

// ------------------------------------------------------------- kitchen requests

class _ReqLine {
  int? itemId;
  final name = TextEditingController();
  final qty = TextEditingController();
  final unit = TextEditingController();
}

class KitchenRequestScreen extends StatefulWidget {
  const KitchenRequestScreen({super.key});
  @override
  State<KitchenRequestScreen> createState() => _KitchenRequestScreenState();
}

class _KitchenRequestScreenState extends State<KitchenRequestScreen> {
  Rows _stock = [];
  Rows _mine = [];
  List<String> _units = [];
  final List<_ReqLine> _lines = [_ReqLine()];
  final _note = TextEditingController();
  bool _busy = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await Api.list('listInventory');
      final m = await Api.list('myStockRequests');
      final u = (await Api.call('listUnits')) as List;
      if (!mounted) return;
      setState(() {
        _stock = s;
        _mine = m;
        _units = u.map((e) => '$e').toList();
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.message == kSessionExpired) {
        handleSessionExpired(context);
        return;
      }
      setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final items = <Map<String, dynamic>>[];
    for (final l in _lines) {
      final q = parseNum(l.qty.text);
      final hasName = l.itemId != null || l.name.text.trim().isNotEmpty;
      if (!hasName && q == null) continue;
      if (!hasName || q == null || q <= 0) {
        say(context, 'Each line needs an item and a quantity.');
        return;
      }
      items.add({'itemId': l.itemId, 'name': l.name.text.trim(), 'qty': q, 'unit': l.unit.text.trim()});
    }
    if (items.isEmpty) {
      say(context, 'Add at least one item.');
      return;
    }
    setState(() => _busy = true);
    final ok = await guarded(context, () => Api.call('createStockRequest', {'items': items, 'note': _note.text.trim()}),
        success: 'Request sent to the manager');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      setState(() {
        _lines
          ..clear()
          ..add(_ReqLine());
        _note.clear();
      });
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Request Items')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Narrow(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(14, 6, 14, 30),
                  children: [
                    const Text('Ask the manager for items the kitchen needs. Pick from stock or type what you need.',
                        style: TextStyle(color: kMuted)),
                    const SizedBox(height: 8),
                    for (var i = 0; i < _lines.length; i++)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: [
                              InputDecorator(
                                decoration: const InputDecoration(labelText: 'Item'),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<int?>(
                                    value: _lines[i].itemId,
                                    isExpanded: true,
                                    dropdownColor: kSurface2,
                                    hint: const Text('Type below, or pick from stock'),
                                    items: [
                                      const DropdownMenuItem<int?>(value: null, child: Text('Type it myself')),
                                      for (final s in _stock)
                                        DropdownMenuItem<int?>(
                                            value: _idOf(s), child: Text('${s['name']}  (${s['stockText']})', overflow: TextOverflow.ellipsis)),
                                    ],
                                    onChanged: (v) => setState(() {
                                      _lines[i].itemId = v;
                                      if (v != null) {
                                        final it = _stock.firstWhere((s) => _idOf(s) == v);
                                        _lines[i].name.text = '${it['name']}';
                                        _lines[i].unit.text = '${it['unit']}';
                                      }
                                    }),
                                  ),
                                ),
                              ),
                              if (_lines[i].itemId == null) ...[
                                const SizedBox(height: 8),
                                TextField(
                                  controller: _lines[i].name,
                                  textCapitalization: TextCapitalization.sentences,
                                  decoration: const InputDecoration(labelText: 'Item name'),
                                ),
                              ],
                              const SizedBox(height: 8),
                              Row(children: [
                                Expanded(
                                  child: TextField(
                                    controller: _lines[i].qty,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    decoration: const InputDecoration(labelText: 'Quantity'),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextField(
                                    controller: _lines[i].unit,
                                    decoration: const InputDecoration(labelText: 'Unit (kg, crate...)'),
                                  ),
                                ),
                                if (_lines.length > 1)
                                  IconButton(
                                      onPressed: () => setState(() => _lines.removeAt(i)),
                                      icon: const Icon(Icons.close)),
                              ]),
                              if (_units.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Wrap(
                                    spacing: 6,
                                    children: [
                                      for (final u in _units.take(10))
                                        ActionChip(label: Text(u), onPressed: () => setState(() => _lines[i].unit.text = u)),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    TextButton.icon(
                      onPressed: () => setState(() => _lines.add(_ReqLine())),
                      icon: const Icon(Icons.add),
                      label: const Text('Add another item'),
                    ),
                    TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note (optional)')),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _busy ? null : _send,
                      icon: const Icon(Icons.send),
                      label: const Text('Send request'),
                    ),
                    const SectionTitle('My recent requests'),
                    if (_mine.isEmpty) const Text('None yet.', style: TextStyle(color: kMuted)),
                    for (final q in _mine)
                      Card(
                        child: ListTile(
                          title: Text('${fmtNum(q['qty'] as num)} ${q['unit']} ${q['itemName']}'),
                          subtitle: Text('${q['createdAt']}'),
                          trailing: Chip(label: Text('${q['status']}')),
                        ),
                      ),
                  ],
                ),
              ),
      );
}

class StockRequestsScreen extends StatelessWidget {
  const StockRequestsScreen({super.key});
  @override
  Widget build(BuildContext context) => RemoteView<Rows>(
        title: 'Kitchen Requests',
        load: () => Api.list('listStockRequests'),
        autoRefresh: const Duration(seconds: 30),
        builder: (context, rows, reload) => Narrow(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (rows.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No requests yet.')),
              for (final q in rows)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(
                            child: Text('${fmtNum(q['qty'] as num)} ${q['unit']} ${q['itemName']}',
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                          ),
                          Chip(label: Text('${q['status']}')),
                        ]),
                        Text('From ${q['by']} • ${q['createdAt']}', style: const TextStyle(color: kMuted, fontSize: 12)),
                        if ('${q['note']}'.isNotEmpty) Text('${q['note']}'),
                        if ('${q['status']}' == 'Open')
                          Wrap(
                            spacing: 8,
                            children: [
                              for (final a in ['Bought', 'Approved', 'Declined'])
                                OutlinedButton(
                                  onPressed: () async {
                                    final ok = await guarded(
                                        context, () => Api.call('resolveStockRequest', {'id': q['id'], 'status': a}));
                                    if (ok) await reload();
                                  },
                                  child: Text(a == 'Declined' ? 'Decline' : a),
                                ),
                            ],
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

// ------------------------------------------------------------- admin: contact, mobile money, tokens

class ContactSettingsScreen extends StatefulWidget {
  const ContactSettingsScreen({super.key});
  @override
  State<ContactSettingsScreen> createState() => _ContactSettingsScreenState();
}

class _ContactSettingsScreenState extends State<ContactSettingsScreen> {
  bool _loading = true;
  String? _error;
  final _location = TextEditingController();
  final _labels = List.generate(4, (_) => TextEditingController());
  final _numbers = List.generate(4, (_) => TextEditingController());
  final _social = {
    'whatsapp': TextEditingController(),
    'instagram': TextEditingController(),
    'email': TextEditingController(),
    'x': TextEditingController(),
  };
  final _mtn = List.generate(3, (_) => TextEditingController());
  final _airtel = List.generate(3, (_) => TextEditingController());
  final List<List<TextEditingController>> _rules = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final m = await Api.map('getMenu');
      final info = Map<String, dynamic>.from((m['info'] as Map?) ?? const {});
      final momo = Map<String, dynamic>.from((m['momo'] as Map?) ?? const {});
      final rules = ((m['tokenRules'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      if (!mounted) return;
      setState(() {
        _location.text = '${info['location'] ?? ''}';
        final phones = ((info['phones'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        for (var i = 0; i < 4; i++) {
          _labels[i].text = i < phones.length ? '${phones[i]['label']}' : '';
          _numbers[i].text = i < phones.length ? '${phones[i]['number']}' : '';
        }
        final social = Map<String, dynamic>.from((info['social'] as Map?) ?? const {});
        for (final e in _social.entries) {
          e.value.text = '${social[e.key] ?? ''}'.replaceFirst('mailto:', '');
        }
        void fill(List<TextEditingController> c, Map<String, dynamic>? x) {
          c[0].text = '${x?['ussd'] ?? ''}';
          c[1].text = '${x?['merchant'] ?? ''}';
          c[2].text = '${x?['instructions'] ?? ''}';
        }
        fill(_mtn, momo['mtn'] as Map<String, dynamic>?);
        fill(_airtel, momo['airtel'] as Map<String, dynamic>?);
        _rules
          ..clear()
          ..addAll([
            for (final r in rules)
              [
                TextEditingController(text: fmtNum(r['min'] as num)),
                TextEditingController(text: (r['max'] as num) >= 1000000000 ? '' : fmtNum(r['max'] as num)),
                TextEditingController(text: '${r['tokens']}'),
              ]
          ]);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Widget _f(TextEditingController c, String label, {int lines = 1, TextInputType? k}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(controller: c, minLines: lines, maxLines: lines, keyboardType: k, decoration: InputDecoration(labelText: label)),
      );

  Future<void> _saveInfo() async {
    final ok = await guarded(context, () => Api.call('saveRestaurantInfo', {
          'location': _location.text.trim(),
          'phones': [
            for (var i = 0; i < 4; i++)
              if (_numbers[i].text.trim().isNotEmpty)
                {'label': _labels[i].text.trim(), 'number': _numbers[i].text.trim()}
          ],
          'social': {for (final e in _social.entries) e.key: e.value.text.trim()},
        }), success: 'Location, numbers and links saved');
    if (ok) await RestaurantStore.instance.loadMenu();
  }

  Future<void> _saveMomo() async {
    Map<String, String> one(List<TextEditingController> c) =>
        {'ussd': c[0].text.trim(), 'merchant': c[1].text.trim(), 'instructions': c[2].text.trim()};
    final ok = await guarded(context, () => Api.call('saveMomoSettings', {'momo': {'mtn': one(_mtn), 'airtel': one(_airtel)}}),
        success: 'Mobile money details saved');
    if (ok) await RestaurantStore.instance.loadMenu();
  }

  Future<void> _saveRules() async {
    final rules = <Map<String, dynamic>>[];
    for (final r in _rules) {
      final min = parseNum(r[0].text);
      final max = r[1].text.trim().isEmpty ? 1000000000.0 : parseNum(r[1].text);
      final t = int.tryParse(r[2].text.trim());
      if (min == null || max == null || t == null) {
        say(context, 'Check the numbers in each rule.');
        return;
      }
      rules.add({'min': min, 'max': max, 'tokens': t});
    }
    final ok = await guarded(context, () => Api.call('saveTokenRules', {'rules': rules}), success: 'Token rules saved');
    if (ok) await RestaurantStore.instance.loadMenu();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Restaurant Settings')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text(_error!))
                : Narrow(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 40),
                      children: [
                        const SectionTitle('Location, service numbers and links'),
                        _f(_location, 'Restaurant location'),
                        for (var i = 0; i < 4; i++)
                          Row(children: [
                            Expanded(child: _f(_labels[i], 'Label ${i + 1} (e.g. Orders)')),
                            const SizedBox(width: 8),
                            Expanded(child: _f(_numbers[i], 'Service number ${i + 1}', k: TextInputType.phone)),
                          ]),
                        const Text('Connect with us links (full web addresses starting with https://)',
                            style: TextStyle(color: kMuted, fontSize: 12)),
                        const SizedBox(height: 6),
                        _f(_social['whatsapp']!, 'WhatsApp link (e.g. https://wa.me/2567XXXXXXXX)'),
                        _f(_social['instagram']!, 'Instagram page link'),
                        _f(_social['email']!, 'Email address'),
                        _f(_social['x']!, 'X (Twitter) page link'),
                        FilledButton(onPressed: _saveInfo, child: const Text('Save location & links')),
                        const SectionTitle('MTN Mobile Money'),
                        _f(_mtn[0], 'USSD code customers dial'),
                        _f(_mtn[1], 'Merchant code'),
                        _f(_mtn[2], 'How to pay (extra steps)', lines: 3),
                        const SectionTitle('Airtel Money'),
                        _f(_airtel[0], 'USSD code customers dial'),
                        _f(_airtel[1], 'Merchant code'),
                        _f(_airtel[2], 'How to pay (extra steps)', lines: 3),
                        FilledButton(onPressed: _saveMomo, child: const Text('Save mobile money details')),
                        const SectionTitle('Token rewards'),
                        const Text('A customer earns tokens when a bill falls in a range. Leave "to" empty for "and above".',
                            style: TextStyle(color: kMuted, fontSize: 12)),
                        const SizedBox(height: 8),
                        for (var i = 0; i < _rules.length; i++)
                          Row(children: [
                            Expanded(child: _f(_rules[i][0], 'From (UGX)', k: TextInputType.number)),
                            const SizedBox(width: 6),
                            Expanded(child: _f(_rules[i][1], 'To (UGX)', k: TextInputType.number)),
                            const SizedBox(width: 6),
                            Expanded(child: _f(_rules[i][2], 'Tokens', k: TextInputType.number)),
                            IconButton(onPressed: () => setState(() => _rules.removeAt(i)), icon: const Icon(Icons.close)),
                          ]),
                        TextButton.icon(
                          onPressed: () => setState(() => _rules.add([
                                TextEditingController(),
                                TextEditingController(),
                                TextEditingController()
                              ])),
                          icon: const Icon(Icons.add),
                          label: const Text('Add a range'),
                        ),
                        FilledButton(onPressed: _saveRules, child: const Text('Save token rules')),
                        const Padding(
                          padding: EdgeInsets.only(top: 10),
                          child: Text('Set the token price of each meal under Menu → edit dish.',
                              style: TextStyle(color: kMuted, fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
      );
}

// ------------------------------------------------------------- category background pictures

class CategoryPicturesScreen extends StatefulWidget {
  const CategoryPicturesScreen({super.key});
  @override
  State<CategoryPicturesScreen> createState() => _CategoryPicturesScreenState();
}

class _CategoryPicturesScreenState extends State<CategoryPicturesScreen> {
  String? _cat;
  int _key = 0;

  @override
  Widget build(BuildContext context) => RemoteView<Map<String, dynamic>>(
        key: ValueKey<int>(_key),
        title: 'Menu Backgrounds',
        load: () => Api.map('getMenu'),
        builder: (context, m, reload) {
          final dishes = (m['dishes'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          final cats = <String>{for (final d in dishes) '${d['category']}'}.toList()..sort();
          final all = Map<String, dynamic>.from((m['categoryImages'] as Map?) ?? const {});
          final cat = _cat ?? (cats.isEmpty ? null : cats.first);
          final urls = cat == null ? <String>[] : [for (final u in ((all[cat] as List?) ?? const [])) '$u'];
          return Narrow(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 40),
              children: [
                const Text(
                    'When a customer looks at a food category, these pictures slide in the background. '
                    'Add delicious photos for each category. If you add none, the dish photos are used.',
                    style: TextStyle(color: kMuted)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, children: [
                  for (final c in cats)
                    ChoiceChip(label: Text(c), selected: cat == c, onSelected: (_) => setState(() => _cat = c)),
                ]),
                const SizedBox(height: 10),
                if (cat != null)
                  FilledButton.icon(
                    onPressed: () async {
                      final bytes = await pickPhotoLarge();
                      if (bytes == null || !context.mounted) return;
                      String? url;
                      final up = await guarded(context, () async {
                        url = await withProgress<String>(context, () async {
                          final r = await Api.map('uploadImage',
                              {'data': base64Encode(bytes), 'mime': 'image/jpeg', 'size': 1400},
                              const Duration(seconds: 120));
                          return '${r['url']}';
                        });
                      });
                      if (!up || url == null || !context.mounted) return;
                      final ok = await guarded(context,
                          () => Api.call('saveCategoryImages', {'category': cat, 'images': [...urls, url!]}),
                          success: 'Picture added');
                      if (ok) setState(() => _key++);
                    },
                    icon: const Icon(Icons.add_photo_alternate),
                    label: Text('Add picture to $cat'),
                  ),
                const SizedBox(height: 10),
                if (urls.isEmpty && cat != null)
                  const Text('No pictures for this category yet.', style: TextStyle(color: kMuted)),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.2,
                  children: [
                    for (final u in urls)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Stack(fit: StackFit.expand, children: [
                          Image.network(u, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const ColoredBox(color: kSurface2, child: Icon(Icons.broken_image))),
                          Positioned(
                            top: 6,
                            right: 6,
                            child: CircleAvatar(
                              backgroundColor: Colors.black54,
                              child: IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.white),
                                onPressed: () async {
                                  final ok = await guarded(
                                      context,
                                      () => Api.call('saveCategoryImages',
                                          {'category': cat, 'images': [for (final x in urls) if (x != u) x]}),
                                      success: 'Picture removed');
                                  if (ok) setState(() => _key++);
                                },
                              ),
                            ),
                          ),
                        ]),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      );
}

// ------------------------------------------------------------- events (manager)

class EventsAdminScreen extends StatelessWidget {
  const EventsAdminScreen({super.key});
  @override
  Widget build(BuildContext context) => RemoteView<Rows>(
        title: 'Events',
        load: () => Api.list('listEventsAdmin'),
        fab: (context, reload) => FloatingActionButton.extended(
          onPressed: () async {
            final saved = await Navigator.push<bool>(
                context, MaterialPageRoute(builder: (_) => const EventFormScreen()));
            if (saved == true) await reload();
          },
          icon: const Icon(Icons.add),
          label: const Text('New event'),
        ),
        builder: (context, rows, reload) => Narrow(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 90),
            children: [
              if (rows.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No events yet. Tap "New event".')),
              for (final e in rows)
                Card(
                  child: ListTile(
                    leading: '${e['imageUrl']}'.isEmpty
                        ? const CircleAvatar(child: Icon(Icons.event))
                        : CircleAvatar(backgroundImage: NetworkImage('${e['imageUrl']}')),
                    title: Text('${e['title']}'),
                    subtitle: Text('${e['date']} ${e['time']} • ${(e['packages'] as List).length} package(s) • '
                        '${e['sold']} ticket(s) paid${e['active'] == true ? '' : ' • OFF'}'),
                    trailing: PopupMenuButton<String>(
                      onSelected: (a) async {
                        if (a == 'edit') {
                          final saved = await Navigator.push<bool>(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => EventFormScreen(existing: Map<String, dynamic>.from(e))));
                          if (saved == true) await reload();
                        } else {
                          final yes = await confirmDialog(context, 'Delete event?', 'Remove ${e['title']}?', action: 'Delete');
                          if (!yes || !context.mounted) return;
                          final ok = await guarded(context, () => Api.call('deleteEvent', {'id': e['id']}),
                              success: 'Event deleted');
                          if (ok) await reload();
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuItem(value: 'del', child: Text('Delete')),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}

class EventFormScreen extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const EventFormScreen({this.existing, super.key});
  @override
  State<EventFormScreen> createState() => _EventFormScreenState();
}

class _EventFormScreenState extends State<EventFormScreen> {
  final _title = TextEditingController();
  final _date = TextEditingController();
  final _time = TextEditingController();
  final _details = TextEditingController();
  String _image = '';
  bool _active = true;
  bool _busy = false;
  final List<List<TextEditingController>> _pk = [];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _title.text = '${e['title']}';
      _date.text = '${e['date']}';
      _time.text = '${e['time']}';
      _details.text = '${e['details']}';
      _image = '${e['imageUrl']}';
      _active = e['active'] != false;
      for (final p in (e['packages'] as List)) {
        _pk.add([
          TextEditingController(text: '${p['name']}'),
          TextEditingController(text: fmtNum(p['fee'] as num)),
          TextEditingController(text: '${p['details']}'),
        ]);
      }
    }
    if (_pk.isEmpty) {
      _pk.add([TextEditingController(text: 'Regular'), TextEditingController(), TextEditingController()]);
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
        context: context, initialDate: now, firstDate: now.subtract(const Duration(days: 1)), lastDate: DateTime(now.year + 3));
    if (d != null) {
      _date.text = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      setState(() {});
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final ok = await guarded(context, () => Api.call('saveEvent', {
          'item': {
            if (widget.existing != null) 'id': widget.existing!['id'],
            'title': _title.text.trim(),
            'date': _date.text.trim(),
            'time': _time.text.trim(),
            'details': _details.text.trim(),
            'imageUrl': _image,
            'active': _active,
            'packages': [
              for (final p in _pk)
                if (p[0].text.trim().isNotEmpty)
                  {'name': p[0].text.trim(), 'fee': parseNum(p[1].text) ?? 0, 'details': p[2].text.trim()}
            ],
          }
        }), success: 'Event saved');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.existing == null ? 'New Event' : 'Edit Event')),
        body: Narrow(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 40),
            children: [
              GestureDetector(
                onTap: () async {
                  final b = await pickPhotoLarge();
                  if (b == null || !mounted) return;
                  String? url;
                  final ok = await guarded(context, () async {
                    url = await withProgress<String>(context, () async {
                      final r = await Api.map('uploadImage',
                          {'data': base64Encode(b), 'mime': 'image/jpeg', 'size': 1200}, const Duration(seconds: 120));
                      return '${r['url']}';
                    });
                  });
                  if (ok && url != null && mounted) setState(() => _image = url!);
                },
                child: Container(
                  height: 170,
                  decoration: BoxDecoration(color: kSurface2, borderRadius: BorderRadius.circular(18), border: Border.all(color: kLine)),
                  clipBehavior: Clip.antiAlias,
                  child: _image.isEmpty
                      ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.add_photo_alternate_outlined, color: kGold, size: 36),
                          Text('Add event picture', style: TextStyle(color: kMuted)),
                        ]))
                      : Image.network(_image, fit: BoxFit.cover, width: double.infinity),
                ),
              ),
              const SizedBox(height: 12),
              TextField(controller: _title, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Event title')),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _date,
                    readOnly: true,
                    onTap: _pickDate,
                    decoration: const InputDecoration(labelText: 'Date', suffixIcon: Icon(Icons.calendar_month)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: TextField(controller: _time, decoration: const InputDecoration(labelText: 'Time (e.g. 7:00 PM)'))),
              ]),
              const SizedBox(height: 10),
              TextField(controller: _details, minLines: 3, maxLines: 6, decoration: const InputDecoration(labelText: 'Details')),
              const SectionTitle('Packages and fees'),
              for (var i = 0; i < _pk.length; i++)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(children: [
                      Row(children: [
                        Expanded(child: TextField(controller: _pk[i][0], decoration: const InputDecoration(labelText: 'Package (Regular, VIP...)'))),
                        const SizedBox(width: 8),
                        Expanded(child: TextField(controller: _pk[i][1], keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Fee (UGX)'))),
                        if (_pk.length > 1)
                          IconButton(onPressed: () => setState(() => _pk.removeAt(i)), icon: const Icon(Icons.close)),
                      ]),
                      const SizedBox(height: 8),
                      TextField(controller: _pk[i][2], decoration: const InputDecoration(labelText: 'What is included (optional)')),
                    ]),
                  ),
                ),
              if (_pk.length < 6)
                TextButton.icon(
                  onPressed: () => setState(() => _pk.add([TextEditingController(), TextEditingController(), TextEditingController()])),
                  icon: const Icon(Icons.add),
                  label: const Text('Add a package'),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _active,
                onChanged: (v) => setState(() => _active = v),
                title: const Text('Show to customers'),
              ),
              const SizedBox(height: 8),
              FilledButton(onPressed: _busy ? null : _save, child: const Text('Save event')),
            ],
          ),
        ),
      );
}

// ------------------------------------------------------------- subscription packages (manager)

class PackagesAdminScreen extends StatelessWidget {
  const PackagesAdminScreen({super.key});
  @override
  Widget build(BuildContext context) => RemoteView<Map<String, dynamic>>(
        title: 'Subscriptions',
        load: () => Api.map('listSubscriptionsAdmin'),
        fab: (context, reload) => FloatingActionButton.extended(
          onPressed: () async {
            final saved = await Navigator.push<bool>(
                context, MaterialPageRoute(builder: (_) => const PackageFormScreen()));
            if (saved == true) await reload();
          },
          icon: const Icon(Icons.add),
          label: const Text('New package'),
        ),
        builder: (context, r, reload) {
          final pk = (r['packages'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          final subs = (r['subscriptions'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          return Narrow(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
              children: [
                const SectionTitle('Packages'),
                if (pk.isEmpty) const Text('No packages yet.', style: TextStyle(color: kMuted)),
                for (final p in pk)
                  Card(
                    child: ListTile(
                      title: Text('${p['name']}${p['active'] == true ? '' : '  (OFF)'}'),
                      subtitle: Text('${p['days']} days • ${ugx(p['price'] as num)}\n'
                          '${(p['items'] as List).map((i) => '${i['qty']} x ${i['name']}').join(', ')}'),
                      isThreeLine: true,
                      trailing: PopupMenuButton<String>(
                        onSelected: (a) async {
                          if (a == 'edit') {
                            final saved = await Navigator.push<bool>(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => PackageFormScreen(existing: Map<String, dynamic>.from(p))));
                            if (saved == true) await reload();
                          } else {
                            final ok = await guarded(context, () => Api.call('deleteSubPackage', {'id': p['id']}),
                                success: 'Package switched off');
                            if (ok) await reload();
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('Edit')),
                          PopupMenuItem(value: 'off', child: Text('Switch off')),
                        ],
                      ),
                    ),
                  ),
                const SectionTitle('Subscribers'),
                if (subs.isEmpty) const Text('No subscribers yet.', style: TextStyle(color: kMuted)),
                for (final s in subs)
                  Card(
                    child: ListTile(
                      title: Text('${s['customerName']} • ${s['packageName']}'),
                      subtitle: Text('${s['status']} • ${s['startDate']} to ${s['endDate']}\n'
                          '${(s['balances'] as List).map((b) => '${b['name']}: ${b['qty']} left').join(', ')}'),
                      isThreeLine: true,
                    ),
                  ),
              ],
            ),
          );
        },
      );
}

class PackageFormScreen extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const PackageFormScreen({this.existing, super.key});
  @override
  State<PackageFormScreen> createState() => _PackageFormScreenState();
}

class _PackageFormScreenState extends State<PackageFormScreen> {
  final _name = TextEditingController();
  final _desc = TextEditingController();
  final _days = TextEditingController(text: '7');
  final _price = TextEditingController();
  final Map<int, TextEditingController> _qty = {};
  bool _active = true;
  bool _busy = false;
  MenuBundle? _menu;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _name.text = '${e['name']}';
      _desc.text = '${e['description']}';
      _days.text = '${e['days']}';
      _price.text = fmtNum(e['price'] as num);
      _active = e['active'] != false;
      for (final i in (e['items'] as List)) {
        _qty[(i['dishId'] as num).toInt()] = TextEditingController(text: '${i['qty']}');
      }
    }
    Api.menu().then((m) {
      if (mounted) setState(() => _menu = m);
    }).catchError((Object _) {});
  }

  Future<void> _save() async {
    final items = <Map<String, dynamic>>[
      for (final e in _qty.entries)
        if ((int.tryParse(e.value.text.trim()) ?? 0) > 0) {'dishId': e.key, 'qty': int.parse(e.value.text.trim())}
    ];
    setState(() => _busy = true);
    final ok = await guarded(context, () => Api.call('saveSubPackage', {
          'item': {
            if (widget.existing != null) 'id': widget.existing!['id'],
            'name': _name.text.trim(),
            'description': _desc.text.trim(),
            'days': int.tryParse(_days.text.trim()) ?? 0,
            'price': parseNum(_price.text) ?? -1,
            'items': items,
            'active': _active,
          }
        }), success: 'Package saved');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.existing == null ? 'New Package' : 'Edit Package')),
        body: Narrow(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 40),
            children: [
              TextField(controller: _name, decoration: const InputDecoration(labelText: 'Package name (e.g. Weekly Lunch)')),
              const SizedBox(height: 10),
              TextField(controller: _desc, decoration: const InputDecoration(labelText: 'Description (optional)')),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextField(controller: _days, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Period (days)'))),
                const SizedBox(width: 10),
                Expanded(child: TextField(controller: _price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Price (UGX)'))),
              ]),
              const SectionTitle('Food in this package'),
              const Text('Type how many meals of each dish the customer gets. Leave empty for dishes not included.',
                  style: TextStyle(color: kMuted, fontSize: 12)),
              if (_menu == null) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
              if (_menu != null)
                for (final d in _menu!.dishes)
                  Card(
                    child: ListTile(
                      title: Text(d.name),
                      subtitle: Text('${d.category} • ${ugx(d.price)}'),
                      trailing: SizedBox(
                        width: 80,
                        child: TextField(
                          controller: _qty.putIfAbsent(d.id, () => TextEditingController()),
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          decoration: const InputDecoration(hintText: '0', isDense: true),
                        ),
                      ),
                    ),
                  ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _active,
                onChanged: (v) => setState(() => _active = v),
                title: const Text('Available to customers'),
              ),
              FilledButton(onPressed: _busy ? null : _save, child: const Text('Save package')),
            ],
          ),
        ),
      );
}


// ------------------------------------------------------------- customers (reset a forgotten password)

class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});
  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  final _q = TextEditingController();
  Rows _rows = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await Api.call('listCustomers', {'q': _q.text.trim()});
      if (!mounted) return;
      setState(() {
        _rows = [for (final e in (r as List)) Map<String, dynamic>.from(e as Map)];
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

  Future<void> _reset(Map<String, dynamic> c) async {
    final yes = await confirmDialog(
        context,
        'Reset password?',
        '${c['name']} (${c['phone']}) will be signed out and must sign in with a temporary password. '
        'Only do this when you are sure it is the real customer.',
        action: 'Reset');
    if (!yes || !mounted) return;
    Map<String, dynamic>? res;
    final ok = await guarded(context, () async {
      res = await Api.map('resetCustomerPassword', {'id': c['id']});
    });
    if (!ok || res == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Temporary password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${res!['name']}  •  ${res!['phone']}'),
            const SizedBox(height: 12),
            SelectableText('${res!['tempPassword']}',
                style: GoogleFonts.robotoMono(fontSize: 32, fontWeight: FontWeight.w800, letterSpacing: 5, color: kGold)),
            const SizedBox(height: 10),
            Text('Give this to the customer now. It is shown only once and works until ${res!['expires']}. '
                'When they sign in they must choose their own password.',
                textAlign: TextAlign.center, style: const TextStyle(color: kMuted)),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: '${res!['tempPassword']}')),
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy'),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
        ],
      ),
    );
    await _search();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Customers')),
        body: Narrow(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
                child: TextField(
                  controller: _q,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    hintText: 'Search by name or phone number',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _search),
                  ),
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                        ? Center(child: Text(_error!))
                        : ListView(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                            children: [
                              if (_rows.isEmpty)
                                const Padding(padding: EdgeInsets.all(24), child: Text('No customers found.')),
                              for (final c in _rows)
                                Card(
                                  child: ListTile(
                                    leading: const CircleAvatar(child: Icon(Icons.person)),
                                    title: Text('${c['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                                    subtitle: Text('${c['phone']}\nWallet ${ugx(c['wallet'] as num)} • ${c['tokens']} tokens'
                                        '${c['tempPassword'] == true ? '\nTemporary password not yet changed' : ''}'),
                                    isThreeLine: true,
                                    trailing: OutlinedButton(
                                      onPressed: () => _reset(c),
                                      child: const Text('Reset password'),
                                    ),
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
