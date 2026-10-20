part of 'main.dart';

// ======================================================== DELIVERY (delivery man)

/// Jobs given to the signed-in delivery man.
class DeliveryJobsScreen extends StatelessWidget {
  const DeliveryJobsScreen({super.key});

  Future<void> _openCode(BuildContext context, Future<void> Function() reload) async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const DeliveryCodeScreen()));
    await reload();
  }

  @override
  Widget build(BuildContext context) => RemoteView<Rows>(
        title: 'My Deliveries',
        load: () => Api.list('listMine'),
        autoRefresh: const Duration(seconds: 15),
        onLoaded: (prev, cur) {
          if (prev != null && cur.length > prev.length) alertStaff();
        },
        actions: [
          IconButton(
            tooltip: 'Delivery records',
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const MyDeliveryHistoryScreen())),
          ),
        ],
        builder: (context, orders, reload) => Narrow(
          width: 900,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              FilledButton.icon(
                onPressed: () => _openCode(context, reload),
                icon: const Icon(Icons.pin_outlined),
                label: const Text("Enter customer's code"),
              ),
              const SizedBox(height: 8),
              const Text(
                'At the pick-up station, ask the customer for their delivery code. '
                'Enter it here to see the order and complete the hand-over.',
                style: TextStyle(color: kMuted, fontSize: 12),
              ),
              const SizedBox(height: 8),
              if (orders.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Nothing assigned to you right now.')),
              for (final o in orders)
                OrderCard(
                  o,
                  actions: [
                    FilledButton.icon(
                      onPressed: () => _openCode(context, reload),
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('Hand over (enter code)'),
                    ),
                    OutlinedButton(
                      onPressed: () => reasonAction(context, 'Delivery failed', 'failOrder',
                          (o['id'] as num).toInt(), reload,
                          success: 'Reported to the manager'),
                      child: const Text('Could not deliver'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      );
}

class MyDeliveryHistoryScreen extends StatelessWidget {
  const MyDeliveryHistoryScreen({super.key});
  @override
  Widget build(BuildContext context) => RemoteView<Rows>(
        title: 'Delivery Records',
        load: () => Api.list('listMyDone'),
        builder: (context, orders, reload) => Narrow(
          width: 900,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (orders.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(24), child: Text('No completed deliveries yet.')),
              for (final o in orders) OrderCard(o),
            ],
          ),
        ),
      );
}

/// The delivery man types the customer's code, sees the order, and the CUSTOMER
/// presses "Confirm picked up". The code then stops working.
class DeliveryCodeScreen extends StatefulWidget {
  const DeliveryCodeScreen({super.key});
  @override
  State<DeliveryCodeScreen> createState() => _DeliveryCodeScreenState();
}

class _DeliveryCodeScreenState extends State<DeliveryCodeScreen> {
  final _code = TextEditingController();
  Map<String, dynamic>? _details;
  Map<String, dynamic>? _done;
  bool _busy = false;
  bool _collected = false;

  void _say(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _lookup() async {
    final code = _code.text.trim();
    if (code.length < 4) {
      _say("Enter the customer's code.");
      return;
    }
    setState(() => _busy = true);
    Map<String, dynamic>? found;
    final ok = await guarded(context, () async {
      found = await Api.map('lookupDeliveryCode', {'code': code});
    });
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _details = found;
        _collected = false;
      }
    });
  }

  Future<void> _confirm() async {
    final d = _details;
    if (d == null) return;
    final due = (d['amountDue'] as num).toDouble();
    if (due > 0 && !_collected) {
      _say('Collect ${ugx(due)} from the customer first, then tick the box.');
      return;
    }
    setState(() => _busy = true);
    Map<String, dynamic>? result;
    final ok = await guarded(context, () async {
      result = await Api.map(
          'confirmDelivery', {'code': _code.text.trim(), 'collected': _collected});
    });
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _done = result;
    });
  }

  void _reset() => setState(() {
        _details = null;
        _done = null;
        _collected = false;
        _code.clear();
      });

  Widget _row(IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: kGold),
            const SizedBox(width: 8),
            Expanded(child: Text(text)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final d = _details;
    return Scaffold(
      appBar: AppBar(title: const Text('Customer Code')),
      body: Narrow(
        width: 560,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_done != null) ...[
              GlassCard(
                color: kOkBg,
                border: const Color(0xFF4CC38A),
                child: Column(
                  children: [
                    const Icon(Icons.check_circle, size: 56, color: Color(0xFF4CC38A)),
                    const SizedBox(height: 8),
                    Text('Delivered', style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 6),
                    Text(
                      'Order #${_done!['id']} is complete and recorded. '
                      'The code can no longer be used.'
                      '${(_done!['collected'] as num) > 0 ? '\nCash collected: ${ugx(_done!['collected'] as num)}' : ''}',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                  onPressed: () => Navigator.pop(context), child: const Text('Done')),
              TextButton(onPressed: _reset, child: const Text('Enter another code')),
            ] else if (d == null) ...[
              Text("Enter the customer's code",
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              const Text(
                'The customer received this code when they placed the order.',
                style: TextStyle(color: kMuted),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _code,
                autofocus: true,
                maxLength: 10,
                textCapitalization: TextCapitalization.characters,
                textAlign: TextAlign.center,
                autocorrect: false,
                onSubmitted: (_) => _busy ? null : _lookup(),
                style: GoogleFonts.robotoMono(
                    fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: 6),
                decoration: const InputDecoration(hintText: 'CODE', counterText: ''),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _busy ? null : _lookup,
                icon: _busy
                    ? const SizedBox(
                        height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.search),
                label: const Text('Show order'),
              ),
            ] else ...[
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Order #${d['id']}', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 6),
                    _row(Icons.person_outline, '${d['customer']}'),
                    _row(Icons.phone_outlined, '${d['phone']}'),
                    _row(Icons.location_on_outlined, 'Pick-up station: ${d['stationName']}'),
                    const Divider(),
                    const Text('Food ordered', style: TextStyle(color: kGold)),
                    for (final l in (d['lines'] as List)) Text('• $l'),
                    if ('${d['note']}'.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text('Customer note: ${d['note']}'),
                    ],
                    const Divider(),
                    _row(Icons.payments_outlined,
                        'Payment: ${d['payment']} • ${d['paymentStatus']}'),
                    Text(
                        'Food ${ugx(d['subtotal'] as num)} + delivery ${ugx(d['deliveryFee'] as num)} = ${ugx(d['total'] as num)}',
                        style: const TextStyle(color: kMuted, fontSize: 12)),
                  ],
                ),
              ),
              if ((d['amountDue'] as num) > 0)
                GlassCard(
                  color: kWarnBg,
                  border: const Color(0xFFFF9F43),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('COLLECT ${ugx(d['amountDue'] as num)}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 18,
                              color: Color(0xFFFF9F43))),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _collected,
                        onChanged: (v) => setState(() => _collected = v ?? false),
                        title: const Text('I have collected this payment'),
                      ),
                    ],
                  ),
                ),
              if ('${d['deliveryNote']}'.isNotEmpty)
                GlassCard(
                  color: kPanelHi,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.assignment_outlined, color: kGold),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text('Instructions from the manager:\n${d['deliveryNote']}'),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _busy ? null : _confirm,
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    backgroundColor: const Color(0xFF2E9E6B)),
                icon: _busy
                    ? const SizedBox(
                        height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.verified_outlined),
                label: const Text('Customer: Confirm picked up',
                    style: TextStyle(fontSize: 16)),
              ),
              const SizedBox(height: 6),
              const Text(
                'Hand the phone to the customer. When they press this button the order is '
                'marked delivered and the code stops working.',
                textAlign: TextAlign.center,
                style: TextStyle(color: kMuted, fontSize: 12),
              ),
              TextButton(onPressed: _reset, child: const Text('Not this order')),
            ],
          ],
        ),
      ),
    );
  }
}
