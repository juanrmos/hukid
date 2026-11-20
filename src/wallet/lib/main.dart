import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'issuance.dart';
import 'keystore.dart';
import 'oid4vci_client.dart';

const bool _allowInsecureLoopback = bool.fromEnvironment(
  'HUKID_ALLOW_INSECURE_LOOPBACK',
);

void main() => runApp(WalletApp.live());

class WalletApp extends StatelessWidget {
  const WalletApp({
    super.key,
    this.adapter = const UnavailableIssuer(),
    this.vault,
    this.enableDeepLinks = false,
  });

  factory WalletApp.live({
    Key? key,
    Oid4vciHttpClient? httpClient,
    Oid4vciConfig config = const Oid4vciConfig(
      allowInsecureLoopback: _allowInsecureLoopback,
    ),
  }) {
    final vault = AndroidEncryptedVault();
    final keyStore = AndroidKeystoreHolderKeyStore();
    final adapter = Oid4vciOfferAdapter(
      keyStore: keyStore,
      vault: vault,
      httpClient: httpClient,
      config: config,
    );
    return WalletApp(
      key: key,
      adapter: adapter,
      vault: vault,
      enableDeepLinks: true,
    );
  }

  final OfferAdapter adapter;
  final CredentialVault? vault;
  final bool enableDeepLinks;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'HukID Wallet',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff5027bc),
        primary: const Color(0xff5027bc),
        surface: Colors.white,
        onSurface: const Color(0xff24173d),
      ),
      scaffoldBackgroundColor: Colors.white,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.all(16),
        ),
      ),
    ),
    home: WalletHome(
      adapter: adapter,
      vault: vault,
      enableDeepLinks: enableDeepLinks,
    ),
  );
}

class WalletHome extends StatefulWidget {
  const WalletHome({
    super.key,
    this.adapter = const UnavailableIssuer(),
    this.vault,
    this.enableDeepLinks = false,
  });

  final OfferAdapter adapter;
  final CredentialVault? vault;
  final bool enableDeepLinks;

  @override
  State<WalletHome> createState() => _WalletHomeState();
}

class _WalletHomeState extends State<WalletHome> {
  static const _deepLinkChannel = MethodChannel(
    'dev.example.hukid_wallet/deeplink',
  );

  List<StoredCredential> _credentials = const <StoredCredential>[];
  List<PendingDeferredIssuance> _pending = const <PendingDeferredIssuance>[];
  String? _statusNote;

  @override
  void initState() {
    super.initState();
    unawaited(_reloadVault());
    if (widget.enableDeepLinks) {
      _deepLinkChannel.setMethodCallHandler(_handleDeepLinkCall);
      unawaited(_consumeInitialDeepLink());
    }
  }

  @override
  void dispose() {
    if (widget.enableDeepLinks) {
      _deepLinkChannel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  Future<void> _handleDeepLinkCall(MethodCall call) async {
    if (call.method == 'onLink' && call.arguments is String) {
      await _openReceivePage(initialLink: call.arguments as String);
    }
  }

  Future<void> _consumeInitialDeepLink() async {
    try {
      final link = await _deepLinkChannel.invokeMethod<String>(
        'consumeInitialLink',
      );
      if (link != null && link.isNotEmpty && mounted) {
        await _openReceivePage(initialLink: link);
      }
    } catch (_) {
      // Ignora canal no disponible en plataformas sin soporte nativo.
    }
  }

  Future<void> _reloadVault() async {
    final vault = widget.vault;
    if (vault == null) return;
    try {
      final creds = await vault.listCredentials();
      final pending = await vault.listPendingDeferred();
      if (!mounted) return;
      setState(() {
        _credentials = creds;
        _pending = pending;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _statusNote = 'No se pudo leer el almacén cifrado local.';
      });
    }
  }

  Future<void> _openReceivePage({String? initialLink}) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            ReceivePage(adapter: widget.adapter, initialLink: initialLink),
      ),
    );
    await _reloadVault();
  }

  Future<void> _pollPendingItem(PendingDeferredIssuance item) async {
    setState(() {
      _statusNote = 'Consultando emisión diferida…';
    });
    final outcome = await widget.adapter.pollDeferred(item);
    await _reloadVault();
    if (!mounted) return;
    setState(() {
      if (outcome.state == ReceiptState.stored) {
        _statusNote = 'Credencial emitida y guardada cifrada.';
      } else if (outcome.state == ReceiptState.pending) {
        _statusNote =
            'El emisor aún procesa la firma (${item.configurationId}).';
      } else {
        _statusNote = 'No se pudo recuperar la emisión diferida.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isLab = widget.adapter is UnavailableIssuer;
    final count = _credentials.length;
    final countLabel = count == 1 ? '1 credencial' : '$count credenciales';

    return Scaffold(
      appBar: AppBar(title: const Text('hukid.')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('Mi wallet', style: Theme.of(context).textTheme.headlineLarge),
            const Text('Tus credenciales. Tú decides.'),
            const SizedBox(height: 24),
            Text(countLabel),
            if (_credentials.isEmpty)
              const Card(
                color: Color(0xfff3effb),
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Icon(Icons.wallet_outlined, size: 48),
                      SizedBox(height: 16),
                      Text('Este espacio es tuyo.'),
                      Text('Todavía no hay credenciales en tu wallet.'),
                    ],
                  ),
                ),
              )
            else
              ..._credentials.map(
                (cred) => Card(
                  color: const Color(0xfff3effb),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          cred.title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text('Emisor: ${cred.issuerDisplayName}'),
                        Text(
                          'Llave vinculada: ${cred.holderJkt.substring(0, cred.holderJkt.length < 12 ? cred.holderJkt.length : 12)}…',
                        ),
                        Text('Recibida: ${cred.receivedAtIso.split('T').first}'),
                      ],
                    ),
                  ),
                ),
              ),
            if (_pending.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'Emisiones diferidas pendientes',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              ..._pending.map(
                (item) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.title),
                        Text('Emisor: ${item.issuerDisplayName}'),
                        const SizedBox(height: 8),
                        FilledButton(
                          onPressed: () => unawaited(_pollPendingItem(item)),
                          child: const Text('Consultar estado'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            if (_statusNote != null) ...[
              const SizedBox(height: 12),
              Text(_statusNote!),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Recibir credencial'),
              onPressed: () => unawaited(_openReceivePage()),
            ),
            const SizedBox(height: 24),
            Text(
              isLab
                  ? 'Laboratorio Android · Sin emisor configurado.'
                  : 'HukID Wallet · OID4VCI + Android Keystore (ES256 / AES-GCM).',
            ),
            if (isLab)
              const Text('Sin cámara, recepción real ni almacenamiento todavía.'),
          ],
        ),
      ),
    );
  }
}

class ReceivePage extends StatefulWidget {
  const ReceivePage({super.key, required this.adapter, this.initialLink});

  final OfferAdapter adapter;
  final String? initialLink;

  @override
  State<ReceivePage> createState() => _ReceivePageState();
}

class _ReceivePageState extends State<ReceivePage> {
  late final flow = Issuance(widget.adapter);
  final input = TextEditingController();
  bool consent = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialLink;
    if (initial != null && initial.trim().isNotEmpty) {
      input.text = initial.trim();
      unawaited(_inspectOffer());
    }
  }

  @override
  void dispose() {
    flow.cancel();
    input.dispose();
    super.dispose();
  }

  Future<void> _inspectOffer() async {
    consent = false;
    final task = flow.preview(input.text);
    if (mounted) setState(() {});
    await task;
    if (mounted) setState(() {});
  }

  Future<void> receive() async {
    final result = flow.receive(consent: consent);
    setState(() {});
    await result;
    if (mounted) setState(() {});
  }

  Future<void> pollDeferred() async {
    final result = flow.pollPending();
    setState(() {});
    await result;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final offer = flow.offer;
    final reviewing = flow.state == ReceiptState.preview;
    final loading = flow.state == ReceiptState.loading;

    return Scaffold(
      appBar: AppBar(title: const Text('Recibir credencial')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (offer == null) ...[
              const Text('Usar enlace'),
              Text(
                widget.adapter is UnavailableIssuer
                    ? 'No pegues datos personales ni códigos reales. '
                          'No se abrirán enlaces externos.'
                    : 'Pega el enlace openid-credential-offer:// emitido por tu organización.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: input,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Enlace de oferta',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: loading ? null : () => unawaited(_inspectOffer()),
                child: Text(loading ? 'Consultando…' : 'Revisar oferta'),
              ),
            ] else ...[
              Text(
                'Una credencial para ti',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 16),
              Text(offer.issuer),
              Text(offer.title),
              const Text(
                'Vista previa. No acredita firma, estado ni validez. '
                'Revisa qué recibirás antes de solicitarlo.',
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Consiento solicitar esta credencial al emisor.',
                ),
                value: consent,
                onChanged: reviewing
                    ? (value) => setState(() => consent = value == true)
                    : null,
              ),
              FilledButton(
                onPressed: reviewing && consent ? receive : null,
                child: const Text('Solicitar recepción'),
              ),
            ],
            if (flow.state == ReceiptState.pending) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: const Text('Recepción pendiente'),
              ),
              if (flow.deferred != null) ...[
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => unawaited(pollDeferred()),
                  child: const Text('Consultar ahora'),
                ),
              ],
            ],
            if (flow.state == ReceiptState.stored) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Credencial guardada'),
                    if (flow.credential != null)
                      Text(
                        'Almacenada cifrada (${flow.credential!.title}).',
                      ),
                  ],
                ),
              ),
            ],
            if (flow.state == ReceiptState.unavailable)
              Semantics(
                liveRegion: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Recepción no disponible'),
                    if (offer == null)
                      Text(
                        widget.adapter is UnavailableIssuer
                            ? 'Sin emisor configurado. Integración no disponible.'
                            : 'No se pudo verificar o completar la oferta.',
                      ),
                    const Text('No se guardó ninguna credencial.'),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () {
                flow.cancel();
                Navigator.of(context).pop();
              },
              child: Text(
                flow.state == ReceiptState.stored ? 'Volver' : 'Cancelar',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
