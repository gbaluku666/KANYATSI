part of 'main.dart';

// ======================================================== STOCK & INVENTORY

Color stockColor(Map<String, dynamic> x) {
  if (x['out'] == true) return const Color(0xFFFF5A4D);
  if (x['low'] == true) return const Color(0xFFFF9F43);
  if ((x['percent'] as num) < 50) return kGold;
  return const Color(0xFF4CC38A);
}

Future<Uint8List?> pickPhotoLarge() async {
  try {
    final x = await ImagePicker().pickImage(
        source: ImageSource.gallery, maxWidth: 1400, maxHeight: 1400, imageQuality: 80);
    if (x == null) return null;
    return await x.readAsBytes();
  } catch (_) {
    return null;
  }
}

/// Horizontal bars: how much of each item is left. The lowest items come first.
class StockLevelChart extends StatelessWidget {
  final Rows items;
  const StockLevelChart(this.items, {super.key});

  @override
  Widget build(BuildContext context) {
    final sorted = [...items]
      ..sort((a, b) => (a['percent'] as num).compareTo(b['percent'] as num));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final x in sorted)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('${x['name']}',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    Text('${(x['percent'] as num).round()}%',
                        style: TextStyle(
                            color: stockColor(x), fontWeight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: ((x['percent'] as num).toDouble() / 100).clamp(0.0, 1.0),
                    minHeight: 12,
                    color: stockColor(x),
                    backgroundColor: Colors.white12,
                  ),
                ),
                const SizedBox(height: 2),
                Text('${x['stockText']}',
                    style: const TextStyle(fontSize: 12, color: kMuted)),
              ],
            ),
          ),
        const SizedBox(height: 6),
        const Row(
          children: [
            Icon(Icons.circle, size: 10, color: Color(0xFF4CC38A)),
            SizedBox(width: 4),
            Text('Good', style: TextStyle(fontSize: 11, color: kMuted)),
            SizedBox(width: 12),
            Icon(Icons.circle, size: 10, color: kGold),
            SizedBox(width: 4),
            Text('Below half', style: TextStyle(fontSize: 11, color: kMuted)),
            SizedBox(width: 12),
            Icon(Icons.circle, size: 10, color: Color(0xFFFF9F43)),
            SizedBox(width: 4),
            Text('Low', style: TextStyle(fontSize: 11, color: kMuted)),
            SizedBox(width: 12),
            Icon(Icons.circle, size: 10, color: Color(0xFFFF5A4D)),
            SizedBox(width: 4),
            Text('Out', style: TextStyle(fontSize: 11, color: kMuted)),
          ],
        ),
      ],
    );
  }
}

class StockScreen extends StatefulWidget {
  const StockScreen({super.key});
  @override
  State<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends State<StockScreen> {
  int days = 14;
  String usageKey = 'all';

  Future<void> _edit(BuildContext context, Map<String, dynamic> x,
      Future<void> Function() reload) async {
    final v = await formDialog(
      context,
      'Edit ${x['name']}',
      [
        FieldSpec('name', 'Item name', initial: '${x['name']}'),
        FieldSpec('unit', 'Measured in (kg, bottle, number...)', initial: '${x['unit']}'),
        FieldSpec('packName', 'Pack name (crate, sack... leave empty if none)',
            initial: '${x['packName']}'),
        FieldSpec('packSize', 'How many single items in one pack',
            initial: numText(x['packSize']), keyboard: TextInputType.number),
        FieldSpec('packPrice', 'Price of one pack',
            initial: numText(x['packPrice']), keyboard: TextInputType.number),
        FieldSpec('unitPrice', 'Price of one single item',
            initial: numText(x['unitPrice']), keyboard: TextInputType.number),
        FieldSpec('lowPct', 'Warn me when below (%)',
            initial: numText(x['lowPct']), keyboard: TextInputType.number),
      ],
    );
    if (v == null || !context.mounted) return;
    final ok = await guarded(
        context, () => Api.call('saveInventoryItem', {'id': _idOf(x), ...v}),
        success: 'Item updated');
    if (ok) await reload();
  }

  Future<void> _adjust(BuildContext context, Map<String, dynamic> x,
      Future<void> Function() reload) async {
    final v = await formDialog(context, 'Correct ${x['name']} (${x['unit']})', const [
      FieldSpec('change', 'Quantity (+ to add, - to remove)',
          keyboard: TextInputType.numberWithOptions(signed: true, decimal: true)),
      FieldSpec('reason', 'Reason (count correction, spoilage...)', initial: 'Correction'),
    ]);
    if (v == null || !context.mounted) return;
    final ok = await guarded(
        context,
        () => Api.call('adjustStock', {
              'id': _idOf(x),
              'change': double.tryParse(v['change'] ?? '') ?? 0,
              'reason': v['reason'],
            }),
        success: 'Stock corrected');
    if (ok) await reload();
  }

  @override
  Widget build(BuildContext context) {
    return RemoteView<Map<String, dynamic>>(
      key: ValueKey<int>(days),
      title: 'Inventory & Stock',
      load: () => Api.map('stockReport', {'days': days}),
      autoRefresh: const Duration(seconds: 30),
      actions: [
        IconButton(
          tooltip: 'Record items used',
          icon: const Icon(Icons.outbox),
          onPressed: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const UseStockScreen())),
        ),
        IconButton(
          tooltip: 'Stock history',
          icon: const Icon(Icons.history),
          onPressed: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const StockHistoryScreen())),
        ),
      ],
      fab: (context, reload) => FloatingActionButton.extended(
        onPressed: () async {
          final added = await Navigator.push<bool>(
              context, MaterialPageRoute(builder: (_) => const AddStockScreen()));
          if (added == true) await reload();
        },
        icon: const Icon(Icons.add_shopping_cart),
        label: const Text('Add stock'),
      ),
      builder: (context, r, reload) {
        final items = (r['items'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        final usage = (r['usage'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        final dayLabels = (r['days'] as List).map((e) => '$e').toList();
        final usageValue =
            (r['usageValue'] as List).map((e) => (e as num).toDouble()).toList();
        final summary = Map<String, dynamic>.from(r['summary'] as Map);
        final lowItems = items.where((x) => x['low'] == true).toList();

        List<double> daily = usageValue;
        var chartTitle = 'Value of items used per day (UGX)';
        if (usageKey != 'all') {
          final u = usage.where((e) => '${e['id']}' == usageKey).toList();
          if (u.isNotEmpty) {
            daily = (u.first['series'] as List).map((e) => (e as num).toDouble()).toList();
            chartTitle = '${u.first['name']} used per day (${u.first['unit']})';
          }
        }
        final series = <Map<String, dynamic>>[
          for (var i = 0; i < dayLabels.length && i < daily.length; i++)
            {'label': dayLabels[i], 'v': daily[i]}
        ];

        return Narrow(
          width: 900,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 100),
            children: [
              if (lowItems.isNotEmpty)
                GlassCard(
                  color: kWarnBg,
                  border: const Color(0xFFFF9F43),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Color(0xFFFF9F43)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Running low: ${lowItems.map((x) => '${x['name']} (${(x['percent'] as num).round()}%)').join(', ')}. '
                          'Time to buy more.',
                        ),
                      ),
                    ],
                  ),
                ),
              Row(
                children: [
                  Expanded(child: _MiniStat('Items', '${summary['items']}', Icons.inventory_2)),
                  const SizedBox(width: 8),
                  Expanded(
                      child: _MiniStat('Low / out', '${summary['low']} / ${summary['out']}',
                          Icons.warning_amber_rounded)),
                  const SizedBox(width: 8),
                  Expanded(
                      child: _MiniStat('Stock value', compact(summary['stockValue'] as num),
                          Icons.payments)),
                ],
              ),
              const SectionTitle('Stock levels'),
              GlassCard(
                child: items.isEmpty
                    ? const Text('No stock yet. Tap "Add stock" to start.')
                    : StockLevelChart(items),
              ),
              const SectionTitle('Usage'),
              Wrap(
                spacing: 8,
                children: [
                  for (final e in {'7 days': 7, '14 days': 14, '30 days': 30}.entries)
                    ChoiceChip(
                      label: Text(e.key),
                      selected: days == e.value,
                      onSelected: (_) => setState(() => days = e.value),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    label: const Text('All (value)'),
                    selected: usageKey == 'all',
                    onSelected: (_) => setState(() => usageKey = 'all'),
                  ),
                  for (final u in usage)
                    ChoiceChip(
                      label: Text('${u['name']}'),
                      selected: usageKey == '${u['id']}',
                      onSelected: (_) => setState(() => usageKey = '${u['id']}'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(chartTitle, style: Theme.of(context).textTheme.titleMedium),
                    if (usage.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('Nothing used in this period yet.',
                            style: TextStyle(color: kMuted)),
                      ),
                    BarChart(series, 'v'),
                  ],
                ),
              ),
              const SectionTitle('All items'),
              for (final x in items)
                Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: stockColor(x).withValues(alpha: 0.18),
                      child: Icon(
                          x['low'] == true ? Icons.warning_amber_rounded : Icons.inventory_2,
                          color: stockColor(x)),
                    ),
                    title: Text('${x['name']}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      '${x['stockText']} • ${(x['percent'] as num).round()}%'
                      '${(x['packSize'] as num) > 0 && '${x['packName']}'.isNotEmpty ? '\n1 ${x['packName']} = ${fmtNum(x['packSize'] as num)} ${x['unit']}' : ''}'
                      '${(x['packPrice'] as num) > 0 ? ' • ${ugx(x['packPrice'] as num)}/${x['packName']}' : ''}'
                      '${(x['unitPrice'] as num) > 0 ? ' • ${ugx(x['unitPrice'] as num)}/${x['unit']}' : ''}',
                    ),
                    isThreeLine: (x['packSize'] as num) > 0,
                    trailing: PopupMenuButton<String>(
                      onSelected: (a) async {
                        if (a == 'add') {
                          final added = await Navigator.push<bool>(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => AddStockScreen(itemId: _idOf(x))));
                          if (added == true) await reload();
                        } else if (a == 'edit') {
                          await _edit(context, x, reload);
                        } else if (a == 'adjust') {
                          await _adjust(context, x, reload);
                        } else if (a == 'delete') {
                          final yes = await confirmDialog(context, 'Delete item?',
                              'Remove ${x['name']} from stock records? Its history stays in the movements list.',
                              action: 'Delete');
                          if (!yes || !context.mounted) return;
                          final ok = await guarded(context,
                              () => Api.call('deleteInventoryItem', {'id': _idOf(x)}),
                              success: 'Item deleted');
                          if (ok) await reload();
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'add', child: Text('Add stock')),
                        PopupMenuItem(value: 'edit', child: Text('Edit units & prices')),
                        PopupMenuItem(value: 'adjust', child: Text('Correct quantity')),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
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
}

class _MiniStat extends StatelessWidget {
  final String label, value;
  final IconData icon;
  const _MiniStat(this.label, this.value, this.icon);
  @override
  Widget build(BuildContext context) => GlassCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Icon(icon, color: kGold, size: 22),
            const SizedBox(height: 4),
            Text(value,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            Text(label, style: const TextStyle(fontSize: 11, color: kMuted)),
          ],
        ),
      );
}

// ------------------------------------------------------------- add stock

class AddStockScreen extends StatefulWidget {
  final int? itemId;
  const AddStockScreen({this.itemId, super.key});
  @override
  State<AddStockScreen> createState() => _AddStockScreenState();
}

class _AddStockScreenState extends State<AddStockScreen> {
  Rows? _items;
  List<String> _units = [];
  String? _loadError;
  bool _isNew = false;
  int? _selected;
  bool _hasPack = false;
  bool _inPacks = false;
  bool _busy = false;

  final _name = TextEditingController();
  final _unit = TextEditingController();
  final _packName = TextEditingController();
  final _packSize = TextEditingController();
  final _packPrice = TextEditingController();
  final _unitPrice = TextEditingController();
  final _qty = TextEditingController();
  final _lowPct = TextEditingController(text: '25');
  final _note = TextEditingController();

  static const _unitIdeas = ['number', 'kg', 'litre', 'bottle', 'packet', 'bunch', 'piece', 'tin'];
  static const _packIdeas = ['crate', 'sack', 'carton', 'box', 'bundle', 'tray'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await Api.list('listInventory');
      try {
        _units = [for (final u in (await Api.call('listUnits')) as List) '$u'];
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _items = rows;
        _loadError = null;
        if (rows.isEmpty) {
          _isNew = true;
        } else {
          _pick(widget.itemId ?? _idOf(rows.first));
        }
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.message == kSessionExpired) {
        handleSessionExpired(context);
        return;
      }
      setState(() => _loadError = e.message);
    }
  }

  void _pick(int id) {
    final rows = _items ?? <Map<String, dynamic>>[];
    final x = rows.where((e) => _idOf(e) == id).toList();
    if (x.isEmpty) return;
    final it = x.first;
    _selected = id;
    _unit.text = '${it['unit']}';
    _packName.text = '${it['packName']}';
    _packSize.text = numText(it['packSize']);
    _packPrice.text = numText(it['packPrice']);
    _unitPrice.text = numText(it['unitPrice']);
    _lowPct.text = numText(it['lowPct']).isEmpty ? '25' : numText(it['lowPct']);
    _hasPack = '${it['packName']}'.isNotEmpty || (it['packSize'] as num) > 0;
    _inPacks = false;
  }

  String get _unitLabel => _unit.text.trim().isEmpty ? 'items' : _unit.text.trim();
  String get _packLabel => _packName.text.trim().isEmpty ? 'pack' : _packName.text.trim();

  String get _preview {
    final q = parseNum(_qty.text);
    if (q == null || q <= 0) return '';
    final size = parseNum(_packSize.text);
    if (_hasPack && _inPacks) {
      if (size == null || size <= 0) {
        return 'Enter how many $_unitLabel are in one $_packLabel to continue.';
      }
      final pp = parseNum(_packPrice.text);
      return 'Adding ${fmtNum(q * size)} $_unitLabel (${fmtNum(q)} $_packLabel x ${fmtNum(size)})'
          '${pp != null ? '. Cost ${ugx(q * pp)}' : ''}';
    }
    final up = parseNum(_unitPrice.text);
    return 'Adding ${fmtNum(q)} $_unitLabel${up != null ? '. Cost ${ugx(q * up)}' : ''}';
  }

  void _say(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _submit() async {
    final unit = _unit.text.trim();
    final q = parseNum(_qty.text);
    if (_isNew && _name.text.trim().isEmpty) {
      _say('Enter the item name.');
      return;
    }
    if (unit.isEmpty) {
      _say('Say how this item is measured (kg, bottle, number...).');
      return;
    }
    if (q == null || q <= 0) {
      _say('Enter how many you bought.');
      return;
    }
    if (_hasPack && _inPacks && (parseNum(_packSize.text) ?? 0) <= 0) {
      _say('Enter how many $_unitLabel are in one $_packLabel, or buy by single items.');
      return;
    }
    final body = <String, dynamic>{
      if (!_isNew) 'itemId': _selected,
      if (_isNew) 'name': _name.text.trim(),
      'unit': unit,
      'packName': _hasPack ? _packName.text.trim() : '',
      'packSize': _hasPack ? _packSize.text.trim() : '',
      'packPrice': _hasPack ? _packPrice.text.trim() : '',
      'unitPrice': _unitPrice.text.trim(),
      'lowPct': _lowPct.text.trim(),
      'qty': q,
      'qtyUnit': (_hasPack && _inPacks) ? 'pack' : 'base',
      'note': _note.text.trim(),
    };
    setState(() => _busy = true);
    final ok = await guarded(context, () => Api.call('addStock', body),
        success: 'Stock added');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  Widget _chips(List<String> ideas, TextEditingController c) => Wrap(
        spacing: 6,
        runSpacing: 0,
        children: [
          for (final u in ideas)
            ActionChip(
              label: Text(u),
              onPressed: () => setState(() => c.text = u),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final items = _items;
    Widget body;
    if (items == null && _loadError == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (items == null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_loadError ?? 'Could not load stock.', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );
    } else {
      body = Narrow(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (items.isNotEmpty)
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Existing item')),
                  ButtonSegment(value: true, label: Text('New item')),
                ],
                selected: {_isNew},
                onSelectionChanged: (s) => setState(() {
                  _isNew = s.first;
                  if (!_isNew && _selected != null) _pick(_selected!);
                  if (_isNew) {
                    _name.clear();
                    _unit.clear();
                    _packName.clear();
                    _packSize.clear();
                    _packPrice.clear();
                    _unitPrice.clear();
                    _hasPack = false;
                    _inPacks = false;
                  }
                }),
              ),
            const SizedBox(height: 14),
            if (_isNew)
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Item name (e.g. Soda, Cabbage, Rice)',
                    prefixIcon: Icon(Icons.label_outline)),
              )
            else
              InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'Item', prefixIcon: Icon(Icons.inventory_2_outlined)),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: _selected,
                    isExpanded: true,
                    dropdownColor: kSurface2,
                    items: [
                      for (final x in items)
                        DropdownMenuItem<int>(
                            value: _idOf(x),
                            child: Text('${x['name']}  (${x['stockText']})',
                                overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (v) => setState(() {
                      if (v != null) _pick(v);
                    }),
                  ),
                ),
              ),
            const SectionTitle('How is it measured?'),
            TextField(
              controller: _unit,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                  labelText: 'Unit of one single item',
                  helperText: 'Pick a unit below, or type your own (it is remembered for next time).'),
            ),
            const SizedBox(height: 6),
            _chips(_units.isEmpty ? _unitIdeas : _units, _unit),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _hasPack,
              onChanged: (v) => setState(() {
                _hasPack = v;
                if (!v) _inPacks = false;
              }),
              title: const Text('It also comes in packs (crate, sack, carton...)'),
              subtitle: const Text('Turn off for single things like 2 cabbages.'),
            ),
            if (_hasPack) ...[
              TextField(
                controller: _packName,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Pack name (e.g. crate)'),
              ),
              const SizedBox(height: 6),
              _chips(_units.isEmpty ? _packIdeas : _units, _packName),
              const SizedBox(height: 10),
              TextField(
                controller: _packSize,
                onChanged: (_) => setState(() {}),
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: 'How many $_unitLabel in one $_packLabel? (optional)',
                    helperText: 'Example: 24 bottles in one crate'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _packPrice,
                onChanged: (_) => setState(() {}),
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: 'Price of one $_packLabel (UGX)',
                    prefixIcon: const Icon(Icons.payments_outlined)),
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              controller: _unitPrice,
              onChanged: (_) => setState(() {}),
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                  labelText: 'Price of one single $_unitLabel (UGX)',
                  helperText: _hasPack
                      ? 'Leave empty to work it out from the pack price'
                      : null,
                  prefixIcon: const Icon(Icons.payments_outlined)),
            ),
            const SectionTitle('How many did you buy?'),
            if (_hasPack)
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: Text('Single $_unitLabel')),
                  ButtonSegment(value: true, label: Text('${_packLabel}s')),
                ],
                selected: {_inPacks},
                onSelectionChanged: (s) => setState(() => _inPacks = s.first),
              ),
            const SizedBox(height: 10),
            TextField(
              controller: _qty,
              onChanged: (_) => setState(() {}),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: _hasPack && _inPacks
                      ? 'Number of ${_packLabel}s'
                      : 'Number of $_unitLabel',
                  prefixIcon: const Icon(Icons.numbers)),
            ),
            if (_preview.isNotEmpty)
              GlassCard(
                color: kPanelHi,
                child: Row(
                  children: [
                    const Icon(Icons.calculate_outlined, color: kGold),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_preview)),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            TextField(
              controller: _lowPct,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Warn me when stock falls below (%)',
                  helperText: 'Measured against the amount you have right after buying',
                  prefixIcon: Icon(Icons.notifications_active_outlined)),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _note,
              decoration: const InputDecoration(
                  labelText: 'Note (supplier, receipt no... optional)',
                  prefixIcon: Icon(Icons.edit_note)),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _busy ? null : _submit,
              icon: _busy
                  ? const SizedBox(
                      height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.add_shopping_cart),
              label: const Text('Add to stock'),
            ),
          ],
        ),
      );
    }
    return Scaffold(appBar: AppBar(title: const Text('Add Stock')), body: body);
  }
}

// ------------------------------------------------------------- use stock

class UseStockScreen extends StatelessWidget {
  const UseStockScreen({super.key});
  @override
  Widget build(BuildContext context) => RemoteView<Rows>(
        title: 'Items Used',
        load: () => Api.list('listInventory'),
        builder: (context, items, reload) => _UseStockForm(items: items, reload: reload),
      );
}

class _UseStockForm extends StatefulWidget {
  final Rows items;
  final Future<void> Function() reload;
  const _UseStockForm({required this.items, required this.reload});
  @override
  State<_UseStockForm> createState() => _UseStockFormState();
}

class _UseStockFormState extends State<_UseStockForm> {
  final _qty = <int, TextEditingController>{};
  final _packMode = <int, bool>{};
  final _note = TextEditingController();
  final _search = TextEditingController();
  bool _busy = false;

  TextEditingController _c(int id) => _qty.putIfAbsent(id, () => TextEditingController());

  Rows get _chosen => widget.items.where((x) {
        final q = parseNum(_c(_idOf(x)).text);
        return q != null && q > 0;
      }).toList();

  String _line(Map<String, dynamic> x) {
    final id = _idOf(x);
    final pack = _packMode[id] ?? false;
    final label = pack ? '${x['packName']}' : '${x['unit']}';
    return '${fmtNum(parseNum(_c(id).text) ?? 0)} $label of ${x['name']}';
  }

  Future<void> _submit() async {
    final chosen = _chosen;
    if (chosen.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a quantity for at least one item.')));
      return;
    }
    final yes = await confirmDialog(
        context,
        'Take these out of stock?',
        chosen.map(_line).join('\n'),
        action: 'Record');
    if (!yes || !mounted) return;
    setState(() => _busy = true);
    final ok = await guarded(
        context,
        () => Api.call('useStock', {
              'items': [
                for (final x in chosen)
                  {
                    'id': _idOf(x),
                    'qty': parseNum(_c(_idOf(x)).text),
                    'qtyUnit': (_packMode[_idOf(x)] ?? false) ? 'pack' : 'base',
                  }
              ],
              'note': _note.text.trim(),
            }),
        success: 'Recorded. Stock updated.');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      for (final c in _qty.values) {
        c.clear();
      }
      _packMode.clear();
      _note.clear();
      await widget.reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final shown = widget.items
        .where((x) => q.isEmpty || '${x['name']}'.toLowerCase().contains(q))
        .toList();
    return Narrow(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 40),
        children: [
          const Text(
            'Choose what was used and how much. It is taken out of stock straight away. '
            'For example: Soda, 1 crate, or 6 single bottles.',
            style: TextStyle(color: kMuted),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
                hintText: 'Search items', prefixIcon: Icon(Icons.search)),
          ),
          const SizedBox(height: 6),
          if (widget.items.isEmpty)
            const Padding(
                padding: EdgeInsets.all(24),
                child: Text('There is nothing in stock yet. The manager adds stock first.')),
          for (final x in shown)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('${x['name']}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 16)),
                        ),
                        if (x['out'] == true)
                          const Text('OUT', style: TextStyle(color: Color(0xFFFF5A4D)))
                        else if (x['low'] == true)
                          const Text('LOW', style: TextStyle(color: Color(0xFFFF9F43))),
                      ],
                    ),
                    Text('Available: ${x['stockText']}',
                        style: const TextStyle(color: kMuted, fontSize: 12)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        SizedBox(
                          width: 110,
                          child: TextField(
                            controller: _c(_idOf(x)),
                            enabled: x['out'] != true,
                            onChanged: (_) => setState(() {}),
                            keyboardType:
                                const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(
                                labelText: 'Used', isDense: true),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ((x['packSize'] as num) > 0 && '${x['packName']}'.isNotEmpty)
                              ? SegmentedButton<bool>(
                                  showSelectedIcon: false,
                                  segments: [
                                    ButtonSegment(value: false, label: Text('${x['unit']}')),
                                    ButtonSegment(
                                        value: true, label: Text('${x['packName']}')),
                                  ],
                                  selected: {_packMode[_idOf(x)] ?? false},
                                  onSelectionChanged: (s) =>
                                      setState(() => _packMode[_idOf(x)] = s.first),
                                )
                              : Text('${x['unit']}',
                                  style: const TextStyle(color: kGold)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          TextField(
            controller: _note,
            decoration: const InputDecoration(
                labelText: 'Note (optional)', prefixIcon: Icon(Icons.edit_note)),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _busy ? null : _submit,
            icon: _busy
                ? const SizedBox(
                    height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check),
            label: Text(_chosen.isEmpty
                ? 'Record items used'
                : 'Record ${_chosen.length} item(s) used'),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- history

class StockHistoryScreen extends StatelessWidget {
  const StockHistoryScreen({super.key});
  @override
  Widget build(BuildContext context) => RemoteView<Rows>(
        title: 'Stock History',
        load: () => Api.list('listStockMovements'),
        builder: (context, rows, reload) => Narrow(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              if (rows.isEmpty)
                const Padding(padding: EdgeInsets.all(24), child: Text('No stock activity yet.')),
              for (final m in rows)
                Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: ((m['change'] as num) >= 0
                              ? const Color(0xFF4CC38A)
                              : const Color(0xFFFF9F43))
                          .withValues(alpha: 0.18),
                      child: Icon(
                          (m['change'] as num) >= 0 ? Icons.south_west : Icons.north_east,
                          color: (m['change'] as num) >= 0
                              ? const Color(0xFF4CC38A)
                              : const Color(0xFFFF9F43)),
                    ),
                    title: Text(
                        '${m['name']}  ${(m['change'] as num) >= 0 ? '+' : ''}${fmtNum(m['change'] as num)} ${m['unit']}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                        '${m['reason']}\n${m['by']} • ${m['timestamp']}'
                        '${(m['cost'] as num) > 0 ? ' • ${ugx(m['cost'] as num)}' : ''}'),
                    isThreeLine: true,
                    trailing: Text('left\n${fmtNum(m['balance'] as num)}',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 11, color: kMuted)),
                  ),
                ),
            ],
          ),
        ),
      );
}

// ------------------------------------------------------------- gallery (manager)

class BackgroundsScreen extends StatelessWidget {
  const BackgroundsScreen({super.key});

  Future<void> _save(BuildContext context, List<String> urls, Future<void> Function() reload,
      String success) async {
    final ok = await guarded(context, () async {
      final r = await Api.map('saveHeroImages', {'images': urls});
      kHeroImages.value = [for (final u in (r['images'] as List)) '$u'];
    }, success: success);
    if (ok) await reload();
  }

  @override
  Widget build(BuildContext context) => RemoteView<List<String>>(
        title: 'Background Pictures',
        load: () async {
          final m = await Api.map('getMenu');
          final list = [for (final u in ((m['heroImages'] as List?) ?? const [])) '$u'];
          kHeroImages.value = list;
          return list;
        },
        fab: (context, reload) => FloatingActionButton.extended(
          onPressed: () async {
            final current = [...kHeroImages.value];
            final bytes = await pickPhotoLarge();
            if (bytes == null || !context.mounted) return;
            String? url;
            final up = await guarded(context, () async {
              url = await withProgress<String>(context, () async {
                final r = await Api.map(
                    'uploadImage',
                    {'data': base64Encode(bytes), 'mime': 'image/jpeg', 'size': 1400},
                    const Duration(seconds: 120));
                return '${r['url']}';
              });
            });
            if (!up || url == null || !context.mounted) return;
            await _save(context, [...current, url!], reload, 'Picture added');
          },
          icon: const Icon(Icons.add_photo_alternate),
          label: const Text('Add picture'),
        ),
        builder: (context, urls, reload) => Narrow(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 100),
            children: [
              const Text(
                'These pictures slide in the background of the app, together with the '
                'built-in ones. Add photos of your food and restaurant (portrait photos look best).',
                style: TextStyle(color: kMuted),
              ),
              const SizedBox(height: 12),
              if (urls.isEmpty)
                const GlassCard(child: Text('No pictures added yet. Tap "Add picture".')),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 0.8,
                children: [
                  for (final u in urls)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.network(u,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  const ColoredBox(color: kSurface2, child: Icon(Icons.broken_image))),
                          Positioned(
                            top: 6,
                            right: 6,
                            child: CircleAvatar(
                              backgroundColor: Colors.black54,
                              child: IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.white),
                                onPressed: () async {
                                  final yes = await confirmDialog(context, 'Remove picture?',
                                      'It will stop appearing in the background.',
                                      action: 'Remove');
                                  if (!yes || !context.mounted) return;
                                  await _save(context, [for (final x in urls) if (x != u) x],
                                      reload, 'Picture removed');
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
}
