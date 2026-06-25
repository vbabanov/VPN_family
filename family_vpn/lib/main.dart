import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:v2ray_myanmar/v2ray_myanmar.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SeniorVpnApp());
}

class SeniorVpnApp extends StatelessWidget {
  const SeniorVpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigoAccent,
        textTheme: GoogleFonts.lexendTextTheme(),
      ),
      home: const VpnDashboard(),
    );
  }
}

class VpnDashboard extends StatefulWidget {
  const VpnDashboard({super.key});

  @override
  State<VpnDashboard> createState() => _VpnDashboardState();
}

class _VpnDashboardState extends State<VpnDashboard> {
  static const String _profileAssetPath = 'assets/vpn_profile.json';
  static const String _profileUrl =
      'https://api.kundi.lucartmax.kz/vpn/profile.json';
  static const Duration _profileRequestTimeout = Duration(seconds: 6);
  static const Duration _watchdogInterval = Duration(seconds: 5);
  static const Duration _stalledTrafficThreshold = Duration(seconds: 25);
  static const int _minimumOutgoingStallSpeed = 1024;

  late final V2rayMyanmar v2ray;
  Timer? _watchdogTimer;

  V2RayStatus v2rayStatus = V2RayStatus();
  bool _isCoreReady = false;
  bool _isLoading = false;
  bool _isProfileLoading = true;
  bool _shouldStayConnected = false;
  bool _isRefreshing = false;
  String? _profileError;
  String _profileSource = 'asset';
  VpnProfile? _profile;
  VpnEndpoint? _activeEndpoint;
  int _totalDown = 0;
  int _totalUp = 0;
  DateTime? _lastIncomingTrafficAt;

  @override
  void initState() {
    super.initState();
    _initEngine();
  }

  Future<void> _initEngine() async {
    v2ray = V2rayMyanmar(onStatusChanged: _handleStatusChanged);
    await Future.wait(<Future<void>>[
      v2ray.initializeV2Ray(),
      _loadProfile(showLoader: true),
    ]);

    if (!mounted) {
      return;
    }

    setState(() {
      _isCoreReady = true;
    });
    _startWatchdog();
  }

  Future<void> _loadProfile({required bool showLoader}) async {
    if (showLoader && mounted) {
      setState(() {
        _isProfileLoading = true;
      });
    }

    try {
      final profile = await _fetchProfileWithFallback();

      if (!mounted) {
        return;
      }

      setState(() {
        _profile = profile;
        _profileError = null;
        _isProfileLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _profileError = error.toString();
        _isProfileLoading = false;
      });
    }
  }

  Future<VpnProfile> _fetchProfileWithFallback() async {
    try {
      final response = await http
          .get(Uri.parse(_profileUrl))
          .timeout(_profileRequestTimeout);
      if (response.statusCode == 200) {
        final body = utf8.decode(response.bodyBytes).replaceFirst('\uFEFF', '');
        final json = jsonDecode(body) as Map<String, dynamic>;
        final profile = VpnProfile.fromJson(json);
        _profileSource = 'remote';
        return profile;
      }
    } catch (_) {
      // Fall back to bundled profile when the remote endpoint is unavailable.
    }

    final raw = await rootBundle.loadString(_profileAssetPath);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    _profileSource = 'asset';
    return VpnProfile.fromJson(json);
  }

  void _handleStatusChanged(V2RayStatus status) {
    final previousState = v2rayStatus.state.toLowerCase();
    final nextState = status.state.toLowerCase();

    if (mounted) {
      setState(() {
        v2rayStatus = status;
        if (nextState == 'connected') {
          _totalDown += status.downloadSpeed;
          _totalUp += status.uploadSpeed;
        }
      });
    }

    if (nextState == 'connected' && status.downloadSpeed > 0) {
      _lastIncomingTrafficAt = DateTime.now();
    }

    final lostConnection =
        previousState == 'connected' &&
        nextState != 'connected' &&
        _shouldStayConnected &&
        !_isLoading &&
        !_isRefreshing;

    if (lostConnection) {
      unawaited(_refreshConnection(silent: true));
    }
  }

  Future<void> _connect() async {
    if (!_isCoreReady || _isLoading || _isProfileLoading || _profile == null) {
      return;
    }

    await _loadProfile(showLoader: false);
    if (_profile == null) {
      return;
    }

    final granted = await v2ray.requestPermission();
    if (!granted) {
      return;
    }

    _shouldStayConnected = true;
    _lastIncomingTrafficAt = DateTime.now();
    await _connectWithFallback(showFailure: true);
  }

  Future<void> _refreshConnection({bool silent = false}) async {
    if (!_isCoreReady || _isLoading || _profile == null) {
      return;
    }

    _shouldStayConnected = true;
    _isRefreshing = true;
    await _loadProfile(showLoader: false);
    await _connectWithFallback(showFailure: !silent);
    _isRefreshing = false;
  }

  Future<void> _connectWithFallback({required bool showFailure}) async {
    final profile = _profile;
    if (profile == null) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    final endpointsToTry = _buildEndpointOrder(profile);
    String? lastError;

    for (final endpoint in endpointsToTry) {
      try {
        await v2ray.stopV2Ray();

        final configLink = _buildConfigLink(profile, endpoint);
        final v2rayUrl = V2rayMyanmar.parseFromURL(configLink);

        await v2ray.startV2Ray(
          remark: 'VPS:${endpoint.port}:${endpoint.serverName}',
          config: v2rayUrl.getFullConfiguration(),
        );

        final connected = await _waitUntilConnected();
        if (connected) {
          if (!mounted) {
            return;
          }

          setState(() {
            _activeEndpoint = endpoint;
            _isLoading = false;
          });
          _lastIncomingTrafficAt = DateTime.now();
          return;
        }

        lastError =
            'Connection timeout on ${endpoint.serverName}:${endpoint.port}';
      } catch (error) {
        lastError = error.toString();
      }
    }

    _shouldStayConnected = false;
    await v2ray.stopV2Ray();

    if (showFailure && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(lastError ?? 'Unable to connect to VPS'),
        ),
      );
    }

    if (mounted) {
      setState(() {
        _activeEndpoint = null;
        _isLoading = false;
      });
    }
  }

  List<VpnEndpoint> _buildEndpointOrder(VpnProfile profile) {
    final endpoints = profile.endpoints;
    if (_activeEndpoint == null) {
      return endpoints;
    }

    final prioritized = <VpnEndpoint>[];
    for (final endpoint in endpoints) {
      if (endpoint == _activeEndpoint) {
        prioritized.add(endpoint);
      }
    }
    for (final endpoint in endpoints) {
      if (endpoint != _activeEndpoint) {
        prioritized.add(endpoint);
      }
    }
    return prioritized;
  }

  String _buildConfigLink(VpnProfile profile, VpnEndpoint endpoint) {
    return 'vless://${profile.uuid}@${profile.host}:${endpoint.port}?type=tcp&security=reality&pbk=${profile.publicKey}&fp=${profile.fingerprint}&sni=${endpoint.serverName}&sid=${profile.shortId}&spx=${profile.spiderX}&flow=${profile.flow}#VPS';
  }

  Future<bool> _waitUntilConnected() async {
    const deadline = Duration(seconds: 8);
    const poll = Duration(milliseconds: 250);
    final stopwatch = Stopwatch()..start();

    while (stopwatch.elapsed < deadline) {
      if (v2rayStatus.state.toLowerCase() == 'connected') {
        return true;
      }
      await Future<void>.delayed(poll);
    }

    return false;
  }

  Future<void> _stop() async {
    _shouldStayConnected = false;
    await v2ray.stopV2Ray();

    if (!mounted) {
      return;
    }

    setState(() {
      _activeEndpoint = null;
      _totalDown = 0;
      _totalUp = 0;
      _isLoading = false;
    });
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(_watchdogInterval, (_) {
      _checkForStalledIncomingTraffic();
    });
  }

  void _checkForStalledIncomingTraffic() {
    if (!_shouldStayConnected ||
        _isLoading ||
        _isRefreshing ||
        v2rayStatus.state.toLowerCase() != 'connected') {
      return;
    }

    final lastIncoming = _lastIncomingTrafficAt;
    if (lastIncoming == null) {
      return;
    }

    final hasOutgoingTraffic =
        v2rayStatus.uploadSpeed >= _minimumOutgoingStallSpeed;
    final hasNoIncomingTraffic = v2rayStatus.downloadSpeed == 0;
    final stalled =
        DateTime.now().difference(lastIncoming) >= _stalledTrafficThreshold;

    if (hasOutgoingTraffic && hasNoIncomingTraffic && stalled) {
      unawaited(_refreshConnection(silent: true));
    }
  }

  @override
  void dispose() {
    _watchdogTimer?.cancel();
    super.dispose();
  }

  String _fmt(int bytes) {
    if (bytes <= 0) {
      return '0 B';
    }

    const units = <String>['B', 'KB', 'MB', 'GB'];
    final index = (log(bytes) / log(1024)).floor().clamp(0, units.length - 1);
    final value = bytes / pow(1024, index);
    return '${value.toStringAsFixed(1)} ${units[index]}';
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = v2rayStatus.state.toLowerCase() == 'connected';
    final buttonLabel = isConnected
        ? 'DISCONNECT'
        : _isLoading
        ? 'CONNECTING...'
        : 'CONNECT';
    final buttonAction = isConnected ? _stop : _connect;
    final buttonColor = isConnected ? Colors.redAccent : Colors.indigoAccent;

    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              _buildHeader(),
              const Spacer(),
              _buildShield(isConnected),
              const SizedBox(height: 10),
              Text(
                'Core Status: ${v2rayStatus.state}',
                style: TextStyle(fontSize: 10, color: Colors.grey[400]),
              ),
              const SizedBox(height: 8),
              Text(
                _buildConnectionHint(isConnected),
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              if (isConnected) _buildStatsPanel() else _buildProfileCard(),
              const SizedBox(height: 30),
              _buildActionBtn(buttonLabel, buttonColor, buttonAction),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  String _buildConnectionHint(bool isConnected) {
    if (_isProfileLoading) {
      return 'Loading VPN profile...';
    }
    if (_profileError != null) {
      return 'Profile loading failed';
    }
    if (isConnected && _activeEndpoint != null) {
      return 'Connected via ${_activeEndpoint!.serverName}:${_activeEndpoint!.port}';
    }
    if (_isLoading && _profile != null) {
      return 'Trying ${_profile!.serverNames.length} names on ${_profile!.ports.length} ports';
    }
    return 'Single VPS mode with $_profileSource JSON profile and automatic refresh';
  }

  Widget _buildHeader() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'Family VPN Pro',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }

  Widget _buildShield(bool active) {
    return Container(
      width: 170,
      height: 170,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? Colors.green[50] : Colors.indigo[50],
        border: Border.all(
          color: active ? Colors.green[100]! : Colors.indigo[100]!,
          width: 8,
        ),
      ),
      child: Icon(
        active ? Icons.verified_user : Icons.shield_outlined,
        size: 85,
        color: active ? Colors.green : Colors.indigo,
      ),
    );
  }

  Widget _buildStatsPanel() {
    return Container(
      padding: const EdgeInsets.all(25),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 20),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _stat(
                Icons.arrow_downward,
                'DOWNLOAD',
                '${_fmt(v2rayStatus.downloadSpeed)}/s',
              ),
              _stat(
                Icons.arrow_upward,
                'UPLOAD',
                '${_fmt(v2rayStatus.uploadSpeed)}/s',
              ),
            ],
          ),
          const Divider(height: 40),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _stat(Icons.cloud_download, 'TOTAL DOWN', _fmt(_totalDown)),
              _stat(Icons.cloud_upload, 'TOTAL UP', _fmt(_totalUp)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProfileCard() {
    if (_isProfileLoading) {
      return _buildInfoCard(
        title: 'Loading profile',
        subtitle: 'Reading VPN settings from JSON',
      );
    }

    if (_profileError != null) {
      return _buildInfoCard(
        title: 'Profile error',
        subtitle: _profileError!,
      );
    }

    final profile = _profile;
    if (profile == null) {
      return _buildInfoCard(
        title: 'Profile missing',
        subtitle: 'VPN profile is not available',
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 20),
        ],
      ),
      child: Column(
        children: [
          const Icon(
            Icons.cloud_queue_rounded,
            color: Colors.indigoAccent,
            size: 34,
          ),
          const SizedBox(height: 10),
          const Text(
            'Single VPS',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            'Host: ${profile.host}',
            style: TextStyle(color: Colors.grey[700]),
          ),
          const SizedBox(height: 4),
          Text(
            'Ports: ${profile.ports.join(', ')}',
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            'Names: ${profile.serverNames.join(', ')}',
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            'Profile source: $_profileSource',
            style: TextStyle(color: Colors.grey[500], fontSize: 11),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard({required String title, required String subtitle}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 20),
        ],
      ),
      child: Column(
        children: [
          const Icon(
            Icons.info_outline,
            color: Colors.indigoAccent,
            size: 34,
          ),
          const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _stat(IconData icon, String label, String value) {
    return Column(
      children: [
        Icon(icon, size: 22, color: Colors.indigoAccent),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
        ),
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            color: Colors.grey,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildActionBtn(String label, Color color, VoidCallback action) {
    final canPress = !_isLoading && !_isProfileLoading && _profile != null;

    return SizedBox(
      width: double.infinity,
      height: 65,
      child: ElevatedButton(
        onPressed: canPress ? action : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
      ),
    );
  }
}

class VpnProfile {
  const VpnProfile({
    required this.host,
    required this.uuid,
    required this.publicKey,
    required this.shortId,
    required this.spiderX,
    required this.fingerprint,
    required this.flow,
    required this.ports,
    required this.serverNames,
  });

  final String host;
  final String uuid;
  final String publicKey;
  final String shortId;
  final String spiderX;
  final String fingerprint;
  final String flow;
  final List<int> ports;
  final List<String> serverNames;

  List<VpnEndpoint> get endpoints {
    final result = <VpnEndpoint>[];
    for (final port in ports) {
      for (final serverName in serverNames) {
        result.add(VpnEndpoint(port: port, serverName: serverName));
      }
    }
    return result;
  }

  factory VpnProfile.fromJson(Map<String, dynamic> json) {
    return VpnProfile(
      host: json['host'] as String,
      uuid: json['uuid'] as String,
      publicKey: json['publicKey'] as String,
      shortId: json['shortId'] as String,
      spiderX: json['spiderX'] as String,
      fingerprint: json['fingerprint'] as String? ?? 'chrome',
      flow: json['flow'] as String? ?? 'xtls-rprx-vision',
      ports: (json['ports'] as List<dynamic>).cast<int>(),
      serverNames: (json['serverNames'] as List<dynamic>).cast<String>(),
    );
  }
}

class VpnEndpoint {
  const VpnEndpoint({
    required this.port,
    required this.serverName,
  });

  final int port;
  final String serverName;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is VpnEndpoint &&
        other.port == port &&
        other.serverName == serverName;
  }

  @override
  int get hashCode => Object.hash(port, serverName);
}
