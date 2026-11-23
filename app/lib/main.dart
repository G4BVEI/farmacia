import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

// Pode ser sobrescrita pelo dev.sh com --dart-define=API_BASE_URL=...
final String kBaseUrl = const String.fromEnvironment('API_BASE_URL').isNotEmpty
    ? const String.fromEnvironment('API_BASE_URL')
    : (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
    ? 'http://10.0.2.2:8000'
    : 'http://localhost:8000';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Dispara em paralelo; cada store trata erro internamente.
  vendasStore.load();
  catalog.reload();
  runApp(const FarmaciaApp());
}

// =====================================================================
// MODELS
// =====================================================================
class Medicamento {
  final int id, estoque;
  final String nome, principioAtivo, laboratorio, categoria;
  final double preco;
  final bool requerReceita;
  final String? descricao;

  Medicamento.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      nome = j['nome'],
      principioAtivo = j['principio_ativo'],
      laboratorio = j['laboratorio'],
      preco = (j['preco'] as num).toDouble(),
      estoque = j['estoque'],
      categoria = j['categoria'],
      requerReceita = j['requer_receita'],
      descricao = j['descricao'];

  bool get baixo => estoque <= 30;
}

class ItemVenda {
  final int medicamentoId, quantidade;
  final String nome;
  final double precoUnitario, subtotal;
  ItemVenda(this.medicamentoId, this.nome, this.quantidade, this.precoUnitario)
    : subtotal = _r2(precoUnitario * quantidade);

  ItemVenda.fromJson(Map<String, dynamic> j)
    : medicamentoId = j['medicamento_id'],
      nome = j['nome'],
      quantidade = j['quantidade'],
      precoUnitario = (j['preco_unitario'] as num).toDouble(),
      subtotal = (j['subtotal'] as num).toDouble();

  Map<String, dynamic> toJson() => {
    'medicamento_id': medicamentoId,
    'nome': nome,
    'quantidade': quantidade,
    'preco_unitario': precoUnitario,
    'subtotal': subtotal,
  };
}

class Venda {
  final int id;
  final String data, pagamento;
  final String? cliente;
  final List<ItemVenda> itens;
  final double subtotal, descontoPct, descontoValor, total;
  final bool cancelada;

  Venda({
    required this.id,
    required this.data,
    required this.itens,
    required this.subtotal,
    required this.descontoPct,
    required this.descontoValor,
    required this.total,
    required this.pagamento,
    this.cliente,
    this.cancelada = false,
  });

  Venda.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      data = j['data'],
      itens = (j['itens'] as List).map((e) => ItemVenda.fromJson(e)).toList(),
      subtotal = (j['subtotal'] as num).toDouble(),
      descontoPct = (j['desconto_pct'] as num).toDouble(),
      descontoValor = (j['desconto_valor'] as num).toDouble(),
      total = (j['total'] as num).toDouble(),
      pagamento = j['pagamento'],
      cliente = j['cliente'],
      cancelada = j['cancelada'] ?? false;

  Map<String, dynamic> toJson() => {
    'id': id,
    'data': data,
    'itens': itens.map((e) => e.toJson()).toList(),
    'subtotal': subtotal,
    'desconto_pct': descontoPct,
    'desconto_valor': descontoValor,
    'total': total,
    'pagamento': pagamento,
    'cliente': cliente,
    'cancelada': cancelada,
  };

  int get qtdItens => itens.fold(0, (a, b) => a + b.quantidade);
}

double _r2(double v) => (v * 100).roundToDouble() / 100;

// =====================================================================
// API
// =====================================================================
class Api {
  static const _h = {'Content-Type': 'application/json'};

  static dynamic _decode(http.Response res) {
    dynamic body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {}
    if (res.statusCode >= 200 && res.statusCode < 300) return body;
    final d = body is Map ? body['detail'] : null;
    throw Exception(d is String ? d : 'Erro ${res.statusCode}');
  }

  /// A API limita 50 por página: junta tudo.
  static Future<List<Medicamento>> listarTodos() async {
    final out = <Medicamento>[];
    for (var p = 1; ; p++) {
      final uri = Uri.parse('$kBaseUrl/medicamentos')
          .replace(queryParameters: {'pagina': '$p', 'por_pagina': '50'});
      final j = _decode(await http.get(uri));
      out.addAll((j['itens'] as List).map((e) => Medicamento.fromJson(e)));
      if (p >= (j['total_paginas'] as int)) break;
    }
    return out;
  }

  static Future<void> salvar(int? id, Map<String, dynamic> payload) async {
    final uri = Uri.parse('$kBaseUrl/medicamentos${id == null ? '' : '/$id'}');
    final body = jsonEncode(payload);
    _decode(
      id == null
          ? await http.post(uri, headers: _h, body: body)
          : await http.put(uri, headers: _h, body: body),
    );
  }

  static Future<void> remover(int id) async =>
      _decode(await http.delete(Uri.parse('$kBaseUrl/medicamentos/$id')));

  static Future<void> ajustarEstoque(int id, int qtd, String motivo) async =>
      _decode(
        await http.patch(
          Uri.parse('$kBaseUrl/medicamentos/$id/estoque'),
          headers: _h,
          body: jsonEncode({'quantidade': qtd, 'motivo': motivo}),
        ),
      );

  // ---- VENDAS ----
  static Future<List<Venda>> listarVendas() async {
    final j = _decode(await http.get(Uri.parse('$kBaseUrl/vendas')));
    return (j as List)
        .map((e) => Venda.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<Venda> criarVenda(Map<String, dynamic> payload) async {
    final j = _decode(
      await http.post(
        Uri.parse('$kBaseUrl/vendas'),
        headers: _h,
        body: jsonEncode(payload),
      ),
    );
    return Venda.fromJson(j as Map<String, dynamic>);
  }

  static Future<Venda> cancelarVenda(int id) async {
    final j = _decode(
      await http.post(Uri.parse('$kBaseUrl/vendas/$id/cancelar'), headers: _h),
    );
    return Venda.fromJson(j as Map<String, dynamic>);
  }
}

// =====================================================================
// ESTADO: catálogo, carrinho e vendas
// =====================================================================
class Catalog extends ChangeNotifier {
  List<Medicamento> items = [];
  bool loading = true;
  String? error;

  Future<void> reload({bool silent = false}) async {
    if (!silent) {
      loading = true;
      error = null;
      notifyListeners();
    }
    try {
      items = await Api.listarTodos();
      error = null;
    } catch (e) {
      if (!silent || items.isEmpty) error = _msg(e);
    }
    loading = false;
    notifyListeners();
  }
}

final catalog = Catalog();

class CartLine {
  final Medicamento med;
  int qtd = 1;
  CartLine(this.med);
}

class Carrinho extends ChangeNotifier {
  final Map<int, CartLine> _l = {};
  List<CartLine> get lines => _l.values.toList();
  bool get vazio => _l.isEmpty;
  int get count => _l.values.fold(0, (a, b) => a + b.qtd);
  double get subtotal => _l.values.fold(0.0, (a, b) => a + b.med.preco * b.qtd);
  bool get precisaReceita => _l.values.any((l) => l.med.requerReceita);
  int qtd(int id) => _l[id]?.qtd ?? 0;

  bool add(Medicamento m) {
    final cur = qtd(m.id);
    if (cur >= m.estoque) return false;
    if (cur == 0) {
      _l[m.id] = CartLine(m);
    } else {
      _l[m.id]!.qtd++;
    }
    notifyListeners();
    return true;
  }

  void sub(int id) {
    final l = _l[id];
    if (l == null) return;
    if (--l.qtd <= 0) _l.remove(id);
    notifyListeners();
  }

  void clear() {
    _l.clear();
    notifyListeners();
  }
}

final carrinho = Carrinho();

/// Vendas agora vivem no servidor. A API faz o baixa de estoque
/// e o cancelamento de forma atômica (endpoints /vendas).
class VendasStore extends ChangeNotifier {
  final List<Venda> _v = [];
  bool loading = false;
  String? error;

  List<Venda> get vendas => _v.reversed.toList();
  List<Venda> get _ok => _v.where((v) => !v.cancelada).toList();
  List<Venda> get _hoje {
    final h = DateTime.now().toIso8601String().substring(0, 10);
    return _ok.where((v) => v.data.startsWith(h)).toList();
  }

  double get faturamentoHoje => _r2(_hoje.fold(0.0, (a, v) => a + v.total));
  int get vendasHoje => _hoje.length;
  double get ticketMedio =>
      _ok.isEmpty ? 0 : _r2(_ok.fold(0.0, (a, v) => a + v.total) / _ok.length);

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final list = await Api.listarVendas();
      _v
        ..clear()
        ..addAll(list);
    } catch (e) {
      error = _msg(e);
    }
    loading = false;
    notifyListeners();
  }

  Future<Venda> registrar(String pagamento, double pct, String? cliente) async {
    final linhas = carrinho.lines;
    final v = await Api.criarVenda({
      'itens': linhas
          .map((l) => {'medicamento_id': l.med.id, 'quantidade': l.qtd})
          .toList(),
      'pagamento': pagamento,
      'desconto_pct': pct,
      'cliente': cliente,
    });
    _v.add(v);
    notifyListeners();
    return v;
  }

  Future<void> cancelar(Venda v) async {
    final updated = await Api.cancelarVenda(v.id);
    final i = _v.indexWhere((x) => x.id == v.id);
    if (i >= 0) _v[i] = updated;
    notifyListeners();
  }
}

final vendasStore = VendasStore();

// =====================================================================
// HELPERS / WIDGETS COMUNS
// =====================================================================
String _msg(Object e) => e.toString().replaceFirst('Exception: ', '');

String formatMoney(double v) {
  final s = v.abs().toStringAsFixed(2).split('.');
  final i = s[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => '.');
  return '${v < 0 ? '-' : ''}R\$ $i,${s[1]}';
}

String formatDate(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  String t(int n) => n.toString().padLeft(2, '0');
  return '${t(d.day)}/${t(d.month)} às ${t(d.hour)}:${t(d.minute)}';
}

const _pagamentos = <String, (String, IconData)>{
  'pix': ('Pix', Icons.pix),
  'dinheiro': ('Dinheiro', Icons.payments_outlined),
  'debito': ('Débito', Icons.credit_card),
  'credito': ('Crédito', Icons.credit_score),
};

void _snack(ScaffoldMessengerState sm, String text, {bool erro = false}) {
  sm
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        backgroundColor: erro ? Colors.red.shade700 : null,
      ),
    );
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  const _Pill(this.text, this.color, {this.icon});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
        ],
        Text(
          text,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    ),
  );
}

const _tealDark = Color(0xFF0F766E);
const _tealLight = Color(0xFF14B8A6);

const _palette = [
  Color(0xFF0F766E),
  Color(0xFF3949AB),
  Color(0xFFEF6C00),
  Color(0xFF8E24AA),
  Color(0xFF1E88E5),
  Color(0xFFD81B60),
  Color(0xFF43A047),
  Color(0xFF6D4C41),
];
Color catColor(String c) =>
    _palette[c.codeUnits.fold(0, (a, b) => a + b) % _palette.length];

/// Cabeçalho em gradiente usado no topo de cada aba.
class _Hero extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? bottom;
  const _Hero({required this.title, this.subtitle, this.bottom});
  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: SystemUiOverlayStyle.light.copyWith(
      statusBarColor: Colors.transparent,
    ),
    child: Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [_tealDark, _tealLight],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.5,
                ),
              ),
              if (subtitle != null)
                Text(subtitle!, style: const TextStyle(color: Colors.white70)),
              if (bottom != null) ...[const SizedBox(height: 16), bottom!],
            ],
          ),
        ),
      ),
    ),
  );
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback? onRetry;
  const _Empty(this.icon, this.text, {this.onRetry});
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _tealDark.withValues(alpha: .08),
            ),
            child: Icon(icon, size: 44, color: _tealDark.withValues(alpha: .6)),
          ),
          const SizedBox(height: 16),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600], fontSize: 15),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Tentar novamente'),
            ),
          ],
        ],
      ),
    ),
  );
}

class _PayTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _PayTile(this.label, this.icon, this.selected, this.onTap);
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected ? c.primaryContainer : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? c.primary : const Color(0xFFE3EAE8),
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(icon, color: selected ? c.primary : Colors.grey[600]),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: selected ? c.primary : Colors.grey[700],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  final int qtd;
  final VoidCallback onMinus, onPlus;
  const _Stepper(this.qtd, this.onMinus, this.onPlus);
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(24),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: onMinus,
          icon: Icon(qtd == 1 ? Icons.delete_outline : Icons.remove, size: 20),
        ),
        SizedBox(
          width: 22,
          child: Text(
            '$qtd',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: onPlus,
          icon: const Icon(Icons.add, size: 20),
        ),
      ],
    ),
  );
}

class MedicamentoTile extends StatelessWidget {
  final Medicamento m;
  final Widget? trailing;
  final VoidCallback? onTap;
  const MedicamentoTile(this.m, {super.key, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final cor = catColor(m.categoria);
    final (txt, estCor) = m.estoque == 0
        ? ('Esgotado', Colors.red.shade700)
        : m.baixo
        ? ('Baixo · ${m.estoque}', Colors.orange.shade800)
        : ('${m.estoque} un.', Colors.green.shade700);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 50,
                height: 50,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: cor.withValues(alpha: .13),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  m.nome[0].toUpperCase(),
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: cor,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m.nome,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${m.laboratorio} • ${m.categoria}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.grey[600], fontSize: 12.5),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          formatMoney(m.preco),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: c.primary,
                          ),
                        ),
                        _Pill(txt, estCor),
                        if (m.requerReceita)
                          const _Pill(
                            'Receita',
                            Colors.deepPurple,
                            icon: Icons.assignment,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              trailing ?? Icon(Icons.chevron_right, color: Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cabeçalho + busca + filtro de categoria + lista (usada em Vender e Estoque).
class CatalogView extends StatefulWidget {
  final String title;
  final Widget? Function(Medicamento) trailing;
  final void Function(Medicamento)? onTap;
  const CatalogView({
    super.key,
    required this.title,
    required this.trailing,
    this.onTap,
  });
  @override
  State<CatalogView> createState() => _CatalogViewState();
}

class _CatalogViewState extends State<CatalogView> {
  String _q = '';
  String? _cat;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListenableBuilder(
          listenable: catalog,
          builder: (_, __) => _Hero(
            title: widget.title,
            subtitle: catalog.loading
                ? 'Carregando…'
                : '${catalog.items.length} medicamentos',
            bottom: TextField(
              onChanged: (v) => setState(() => _q = v.toLowerCase().trim()),
              decoration: InputDecoration(
                hintText: 'Buscar medicamento…',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
        ListenableBuilder(
          listenable: catalog,
          builder: (_, __) {
            final cats = catalog.items.map((m) => m.categoria).toSet().toList()
              ..sort();
            if (cats.length < 2) return const SizedBox(height: 8);
            return SizedBox(
              height: 58,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                children: [
                  for (final c in [null, ...cats])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(c ?? 'Todos'),
                        selected: _cat == c,
                        onSelected: (_) => setState(() => _cat = c),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: Listenable.merge([catalog, carrinho]),
            builder: (context, _) {
              if (catalog.loading) {
                return const Center(child: CircularProgressIndicator());
              }
              if (catalog.error != null) {
                return _Empty(
                  Icons.cloud_off_rounded,
                  catalog.error!,
                  onRetry: catalog.reload,
                );
              }
              final list = catalog.items
                  .where(
                    (m) =>
                        (_cat == null || m.categoria == _cat) &&
                        (_q.isEmpty ||
                            m.nome.toLowerCase().contains(_q) ||
                            m.principioAtivo.toLowerCase().contains(_q) ||
                            m.laboratorio.toLowerCase().contains(_q)),
                  )
                  .toList();
              if (list.isEmpty) {
                return const _Empty(Icons.search_off, 'Nenhum medicamento');
              }
              return RefreshIndicator(
                onRefresh: catalog.reload,
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 100),
                  itemCount: list.length,
                  itemBuilder: (_, i) => MedicamentoTile(
                    list[i],
                    trailing: widget.trailing(list[i]),
                    onTap: widget.onTap == null
                        ? null
                        : () => widget.onTap!(list[i]),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// =====================================================================
// APP
// =====================================================================
class FarmaciaApp extends StatelessWidget {
  const FarmaciaApp({super.key});
  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0F766E));
    const line = Color(0xFFE3EAE8);
    OutlineInputBorder border() => OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: line),
    );
    return MaterialApp(
      title: 'Farmácia',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFF4F7F6),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF4F7F6),
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          titleTextStyle: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: Colors.black87,
          ),
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: line),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: border(),
          enabledBorder: border(),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          indicatorColor: scheme.primaryContainer,
        ),
        chipTheme: ChipThemeData(
          shape: const StadiumBorder(side: BorderSide(color: line)),
          backgroundColor: Colors.white,
          selectedColor: scheme.primaryContainer,
          showCheckmark: false,
          labelStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _i,
        children: const [VenderScreen(), EstoqueScreen(), VendasScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _i,
        onDestinationSelected: (i) {
          setState(() => _i = i);
          if (i == 1) catalog.reload(silent: true);
          if (i == 2) vendasStore.load();
        },
        destinations: [
          NavigationDestination(
            icon: ListenableBuilder(
              listenable: carrinho,
              builder: (_, __) => Badge(
                isLabelVisible: !carrinho.vazio,
                label: Text('${carrinho.count}'),
                child: const Icon(Icons.point_of_sale_outlined),
              ),
            ),
            selectedIcon: const Icon(Icons.point_of_sale),
            label: 'Vender',
          ),
          const NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            selectedIcon: Icon(Icons.inventory_2),
            label: 'Estoque',
          ),
          const NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: 'Vendas',
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// VENDER
// =====================================================================
class VenderScreen extends StatelessWidget {
  const VenderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: CatalogView(
              title: 'Nova venda',
              trailing: (m) {
                if (m.estoque == 0) return const SizedBox.shrink();
                return ListenableBuilder(
                  listenable: carrinho,
                  builder: (_, __) {
                    final q = carrinho.qtd(m.id);
                    if (q == 0) {
                      return IconButton.filled(
                        onPressed: () => carrinho.add(m),
                        icon: const Icon(Icons.add),
                      );
                    }
                    return _Stepper(q, () => carrinho.sub(m.id), () {
                      if (!carrinho.add(m)) {
                        _snack(
                          ScaffoldMessenger.of(context),
                          'Estoque máximo atingido (${m.estoque})',
                          erro: true,
                        );
                      }
                    });
                  },
                );
              },
            ),
          ),
          ListenableBuilder(
            listenable: carrinho,
            builder: (context, _) => AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              transitionBuilder: (child, a) => SizeTransition(
                sizeFactor: a,
                axisAlignment: -1,
                child: FadeTransition(opacity: a, child: child),
              ),
              child: carrinho.vazio
                  ? const SizedBox.shrink(key: ValueKey('vazio'))
                  : SafeArea(
                      key: const ValueKey('cheio'),
                      top: false,
                      child: Container(
                        margin: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [_tealDark, _tealLight],
                          ),
                          borderRadius: BorderRadius.circular(22),
                          boxShadow: [
                            BoxShadow(
                              color: _tealDark.withValues(alpha: .35),
                              blurRadius: 18,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: .18),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Badge(
                                label: Text('${carrinho.count}'),
                                backgroundColor: Colors.white,
                                textColor: _tealDark,
                                child: const Icon(
                                  Icons.shopping_bag_outlined,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Total parcial',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Text(
                                    formatMoney(carrinho.subtotal),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: _tealDark,
                              ),
                              onPressed: () => showModalBottomSheet(
                                context: context,
                                isScrollControlled: true,
                                showDragHandle: true,
                                useSafeArea: true,
                                builder: (_) => const _CheckoutSheet(),
                              ),
                              icon: const Icon(Icons.arrow_forward),
                              label: const Text('Finalizar'),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckoutSheet extends StatefulWidget {
  const _CheckoutSheet();
  @override
  State<_CheckoutSheet> createState() => _CheckoutSheetState();
}

class _CheckoutSheetState extends State<_CheckoutSheet> {
  String _pag = 'pix';
  double _pct = 0;
  bool _receita = false, _salvando = false;
  final _cliente = TextEditingController();

  @override
  void dispose() {
    _cliente.dispose();
    super.dispose();
  }

  Future<void> _finalizar() async {
    final sm = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    if (carrinho.precisaReceita && !_receita) {
      _snack(sm, 'Confirme a apresentação da receita', erro: true);
      return;
    }
    setState(() => _salvando = true);
    try {
      final v = await vendasStore.registrar(
        _pag,
        _pct,
        _cliente.text.trim().isEmpty ? null : _cliente.text.trim(),
      );
      carrinho.clear();
      catalog.reload(silent: true);
      nav.pop();
      _snack(sm, 'Venda #${v.id} realizada • ${formatMoney(v.total)}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _salvando = false);
      _snack(sm, _msg(e), erro: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: carrinho,
      builder: (context, _) {
        final desc = carrinho.subtotal * _pct / 100;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Finalizar venda',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                if (carrinho.vazio)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(child: Text('Carrinho vazio')),
                  ),
                for (final l in carrinho.lines)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      l.med.nome,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      '${l.qtd} × ${formatMoney(l.med.preco)} = ${formatMoney(l.med.preco * l.qtd)}',
                    ),
                    trailing: _Stepper(l.qtd, () => carrinho.sub(l.med.id), () {
                      if (!carrinho.add(l.med)) {
                        _snack(
                          ScaffoldMessenger.of(context),
                          'Estoque máximo atingido',
                          erro: true,
                        );
                      }
                    }),
                  ),
                if (!carrinho.vazio) ...[
                  const Divider(height: 28),
                  const Text(
                    'Pagamento',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final e in _pagamentos.entries)
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(
                              right: e.key == 'credito' ? 0 : 8,
                            ),
                            child: _PayTile(
                              e.value.$1,
                              e.value.$2,
                              _pag == e.key,
                              () => setState(() => _pag = e.key),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Desconto',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [0, 5, 10, 15, 20]
                        .map(
                          (d) => ChoiceChip(
                            label: Text(d == 0 ? 'Sem desconto' : '$d%'),
                            selected: _pct == d.toDouble(),
                            onSelected: (_) =>
                                setState(() => _pct = d.toDouble()),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _cliente,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      hintText: 'Cliente (opcional)',
                      prefixIcon: Icon(Icons.person_outline),
                      isDense: true,
                    ),
                  ),
                  if (carrinho.precisaReceita)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(
                        Icons.assignment,
                        color: Colors.orange,
                      ),
                      title: const Text('Receita apresentada'),
                      value: _receita,
                      onChanged: (v) => setState(() => _receita = v),
                    ),
                  const SizedBox(height: 12),
                  if (_pct > 0)
                    Row(
                      children: [
                        const Text('Desconto'),
                        const Spacer(),
                        Text(
                          '- ${formatMoney(desc)}',
                          style: TextStyle(color: Colors.green.shade700),
                        ),
                      ],
                    ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Text(
                        'Total',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        formatMoney(carrinho.subtotal - desc),
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _salvando ? null : _finalizar,
                    icon: _salvando
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.check_circle),
                    label: Text(_salvando ? 'Processando…' : 'Confirmar venda'),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

// =====================================================================
// ESTOQUE (lista + cadastro/edição)
// =====================================================================
class EstoqueScreen extends StatelessWidget {
  const EstoqueScreen({super.key});

  Future<void> _abrir(BuildContext context, [Medicamento? m]) async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => MedicamentoForm(medicamento: m)),
    );
    if (ok == true) catalog.reload(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _abrir(context),
        icon: const Icon(Icons.add),
        label: const Text('Novo'),
      ),
      body: CatalogView(
        title: 'Estoque',
        trailing: (_) => null,
        onTap: (m) => _abrir(context, m),
      ),
    );
  }
}

class MedicamentoForm extends StatefulWidget {
  final Medicamento? medicamento;
  const MedicamentoForm({super.key, this.medicamento});
  @override
  State<MedicamentoForm> createState() => _MedicamentoFormState();
}

class _MedicamentoFormState extends State<MedicamentoForm> {
  final _key = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _c;
  late bool _receita;
  bool _salvando = false;

  Medicamento? get _m => widget.medicamento;

  @override
  void initState() {
    super.initState();
    final m = _m;
    _c = {
      'nome': TextEditingController(text: m?.nome),
      'principio_ativo': TextEditingController(text: m?.principioAtivo),
      'laboratorio': TextEditingController(text: m?.laboratorio),
      'categoria': TextEditingController(text: m?.categoria),
      'preco': TextEditingController(
        text: m?.preco.toStringAsFixed(2).replaceAll('.', ','),
      ),
      'estoque': TextEditingController(text: m?.estoque.toString()),
      'descricao': TextEditingController(text: m?.descricao),
    };
    _receita = m?.requerReceita ?? false;
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _t(String k) => _c[k]!.text.trim();

  Future<void> _salvar() async {
    if (!_key.currentState!.validate()) return;
    setState(() => _salvando = true);
    try {
      await Api.salvar(_m?.id, {
        'nome': _t('nome'),
        'principio_ativo': _t('principio_ativo'),
        'laboratorio': _t('laboratorio'),
        'categoria': _t('categoria'),
        'preco': double.parse(_t('preco').replaceAll(',', '.')),
        'estoque': int.parse(_t('estoque')),
        'requer_receita': _receita,
        'descricao': _t('descricao').isEmpty ? null : _t('descricao'),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _salvando = false);
      _snack(ScaffoldMessenger.of(context), _msg(e), erro: true);
    }
  }

  Future<void> _excluir() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Excluir medicamento'),
        content: Text('Excluir "${_m!.nome}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.remover(_m!.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) _snack(ScaffoldMessenger.of(context), _msg(e), erro: true);
    }
  }

  Widget _campo(
    String k,
    String label, {
    bool obrigatorio = true,
    int maxLines = 1,
    TextInputType? tipo,
    String? Function(String?)? validar,
  }) => TextFormField(
    controller: _c[k],
    maxLines: maxLines,
    keyboardType: tipo,
    decoration: InputDecoration(labelText: obrigatorio ? '$label *' : label),
    validator:
        validar ??
        (obrigatorio
            ? (v) => (v ?? '').trim().length < 2 ? 'Mínimo 2 caracteres' : null
            : null),
  );

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 12);
    return Scaffold(
      appBar: AppBar(
        title: Text(_m == null ? 'Novo medicamento' : 'Editar medicamento'),
        actions: [
          if (_m != null)
            IconButton(
              onPressed: _excluir,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: Form(
        key: _key,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _campo('nome', 'Nome'),
            gap,
            _campo('principio_ativo', 'Princípio ativo'),
            gap,
            _campo('laboratorio', 'Laboratório'),
            gap,
            _campo('categoria', 'Categoria'),
            gap,
            Row(
              children: [
                Expanded(
                  child: _campo(
                    'preco',
                    'Preço (R\$)',
                    tipo: const TextInputType.numberWithOptions(decimal: true),
                    validar: (v) {
                      final d = double.tryParse((v ?? '').replaceAll(',', '.'));
                      return d == null || d <= 0 ? 'Preço > 0' : null;
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _campo(
                    'estoque',
                    'Estoque',
                    tipo: TextInputType.number,
                    validar: (v) {
                      final i = int.tryParse(v ?? '');
                      return i == null || i < 0 ? 'Inválido' : null;
                    },
                  ),
                ),
              ],
            ),
            gap,
            _campo('descricao', 'Descrição', obrigatorio: false, maxLines: 3),
            const SizedBox(height: 8),
            Card(
              child: SwitchListTile(
                title: const Text('Requer receita'),
                value: _receita,
                onChanged: (v) => setState(() => _receita = v),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _salvando ? null : _salvar,
              icon: const Icon(Icons.save),
              label: Text(_salvando ? 'Salvando…' : 'Salvar'),
            ),
          ],
        ),
      ),
    );
  }
}

// =====================================================================
// VENDAS (resumo + histórico)
// =====================================================================
Widget _metric(String label, String value) => Expanded(
  child: Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .16),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    ),
  ),
);

class VendasScreen extends StatelessWidget {
  const VendasScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Scaffold(
      body: ListenableBuilder(
        listenable: vendasStore,
        builder: (context, _) {
          if (vendasStore.loading && vendasStore.vendas.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (vendasStore.error != null && vendasStore.vendas.isEmpty) {
            return _Empty(
              Icons.cloud_off_rounded,
              vendasStore.error!,
              onRetry: vendasStore.load,
            );
          }
          final list = vendasStore.vendas;
          return RefreshIndicator(
            onRefresh: vendasStore.load,
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _Hero(
                  title: 'Vendas',
                  subtitle: 'Faturamento de hoje',
                  bottom: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatMoney(vendasStore.faturamentoHoje),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 38,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          _metric('Vendas hoje', '${vendasStore.vendasHoje}'),
                          const SizedBox(width: 10),
                          _metric(
                            'Ticket médio',
                            formatMoney(vendasStore.ticketMedio),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 22, 20, 8),
                  child: Text(
                    'Histórico',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                ),
                if (list.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 24),
                    child: _Empty(
                      Icons.receipt_long_outlined,
                      'Nenhuma venda ainda',
                    ),
                  ),
                for (final v in list)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: Card(
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 4,
                        ),
                        leading: Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: v.cancelada
                                ? Colors.grey.shade200
                                : c.primaryContainer,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            _pagamentos[v.pagamento]?.$2 ?? Icons.receipt,
                            color: v.cancelada ? Colors.grey : c.primary,
                          ),
                        ),
                        title: Row(
                          children: [
                            Text(
                              'Venda #${v.id}',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                decoration: v.cancelada
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                            if (v.cancelada) ...[
                              const SizedBox(width: 8),
                              const _Pill('Cancelada', Colors.red),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          '${formatDate(v.data)} • ${v.qtdItens} item(s)',
                        ),
                        trailing: Text(
                          formatMoney(v.total),
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w800,
                            color: v.cancelada ? Colors.grey : null,
                          ),
                        ),
                        onTap: () => showModalBottomSheet(
                          context: context,
                          isScrollControlled: true,
                          showDragHandle: true,
                          useSafeArea: true,
                          builder: (_) => _VendaSheet(v),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _VendaSheet extends StatefulWidget {
  final Venda v;
  const _VendaSheet(this.v);
  @override
  State<_VendaSheet> createState() => _VendaSheetState();
}

class _VendaSheetState extends State<_VendaSheet> {
  bool _busy = false;

  Future<void> _cancelar() async {
    final sm = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cancelar venda'),
        content: const Text('Os itens voltam para o estoque.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Voltar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancelar venda'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await vendasStore.cancelar(widget.v);
      catalog.reload(silent: true);
      nav.pop();
      _snack(sm, 'Venda cancelada e estoque devolvido');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(sm, _msg(e), erro: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.v;
    Widget linha(String a, String b, {bool forte = false, Color? cor}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Text(
                a,
                style: TextStyle(
                  fontSize: forte ? 18 : 14,
                  fontWeight: forte ? FontWeight.w800 : FontWeight.normal,
                ),
              ),
              const Spacer(),
              Text(
                b,
                style: TextStyle(
                  fontSize: forte ? 22 : 14,
                  fontWeight: forte ? FontWeight.w800 : FontWeight.w600,
                  color: cor,
                ),
              ),
            ],
          ),
        );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'Venda #${v.id}',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              if (v.cancelada) const _Pill('Cancelada', Colors.red),
            ],
          ),
          Text(
            '${formatDate(v.data)} • ${_pagamentos[v.pagamento]?.$1 ?? v.pagamento}${v.cliente != null ? ' • ${v.cliente}' : ''}',
            style: TextStyle(color: Colors.grey[600]),
          ),
          const Divider(height: 28),
          for (final it in v.itens)
            linha('${it.quantidade}× ${it.nome}', formatMoney(it.subtotal)),
          const Divider(height: 28),
          linha('Subtotal', formatMoney(v.subtotal)),
          if (v.descontoValor > 0)
            linha(
              'Desconto (${v.descontoPct.toStringAsFixed(0)}%)',
              '- ${formatMoney(v.descontoValor)}',
              cor: Colors.green.shade700,
            ),
          linha('Total', formatMoney(v.total), forte: true),
          if (!v.cancelada) ...[
            const SizedBox(height: 20),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red.shade700,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _busy ? null : _cancelar,
              icon: const Icon(Icons.cancel_outlined),
              label: Text(_busy ? 'Cancelando…' : 'Cancelar venda'),
            ),
          ],
        ],
      ),
    );
  }
}
