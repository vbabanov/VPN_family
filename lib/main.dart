import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
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
  static const List<String> _profileUrls = <String>[
    'https://sister.lucartmax.kz/profile.json',
  ];
  static const String _cachedProfileKey = 'last_known_good_vpn_profile';
  static const Duration _profileRequestTimeout = Duration(seconds: 6);
  static const Duration _connectionStateTimeout = Duration(seconds: 4);
  static const Duration _healthProbeTimeout = Duration(seconds: 4);
  static const Duration _maximumRetryDelay = Duration(seconds: 30);

  late final V2rayMyanmar v2ray;
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  Timer? _watchdogTimer;
  Timer? _retryTimer;

  V2RayStatus v2rayStatus = V2RayStatus();
  bool _isCoreReady = false;
  bool _isLoading = false;
  bool _isProfileLoading = true;
  bool _shouldStayConnected = false;
  bool _isRefreshing = false;
  bool _isHealthCheckRunning = false;
  bool _isTunnelHealthy = false;
  String? _profileError;
  String _profileSource = 'asset';
  VpnProfile? _profile;
  VpnEndpoint? _activeEndpoint;
  int _totalDown = 0;
  int _totalUp = 0;
  int _lastCoreDown = 0;
  int _lastCoreUp = 0;
  int _completedDown = 0;
  int _completedUp = 0;
  int _consecutiveHealthFailures = 0;
  int _healthUrlIndex = 0;
  int _retryAttempt = 0;
  int _connectionGeneration = 0;
  Duration? _nextRetryDelay;

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
      if (_isCoreReady) {
        _startWatchdog();
      }
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
    for (final profileUrl in _profileUrls) {
      try {
        final response = await http
            .get(Uri.parse(profileUrl))
            .timeout(_profileRequestTimeout);
        if (response.statusCode == 200) {
          final body = utf8
              .decode(response.bodyBytes)
              .replaceFirst('\uFEFF', '');
          final json = jsonDecode(body) as Map<String, dynamic>;
          final profile = VpnProfile.fromJson(json);
          await _preferences.setString(_cachedProfileKey, body);
          _profileSource = Uri.parse(profileUrl).host;
          return profile;
        }
      } catch (_) {
        continue;
      }
    }

    try {
      final cachedProfile = await _preferences.getString(_cachedProfileKey);
      if (cachedProfile != null) {
        final json = jsonDecode(cachedProfile) as Map<String, dynamic>;
        final profile = VpnProfile.fromJson(json);
        _profileSource = 'cached';
        return profile;
      }
    } catch (_) {
      await _preferences.remove(_cachedProfileKey);
    }

    final raw = await rootBundle.loadString(_profileAssetPath);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    _profileSource = 'asset';
    return VpnProfile.fromJson(json);
  }

  void _handleStatusChanged(V2RayStatus status) {
    final previousState = v2rayStatus.state.toLowerCase();
    final nextState = status.state.toLowerCase();

    if (nextState == 'connected') {
      if (status.download < _lastCoreDown) {
        _completedDown += _lastCoreDown;
      }
      if (status.upload < _lastCoreUp) {
        _completedUp += _lastCoreUp;
      }
      _lastCoreDown = status.download;
      _lastCoreUp = status.upload;
      _totalDown = _completedDown + status.download;
      _totalUp = _completedUp + status.upload;
    }

    final lostConnection =
        previousState == 'connected' &&
        nextState != 'connected' &&
        _shouldStayConnected &&
        !_isLoading &&
        !_isRefreshing;

    if (mounted) {
      setState(() {
        v2rayStatus = status;
        if (nextState != 'connected') {
          _isTunnelHealthy = false;
        }
      });
    }

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
    _isTunnelHealthy = false;
    _retryAttempt = 0;
    _retryTimer?.cancel();
    final generation = ++_connectionGeneration;
    await _connectWithFallback(showFailure: true, generation: generation);
  }

  Future<void> _refreshConnection({bool silent = false}) async {
    if (!_isCoreReady ||
        _isLoading ||
        _isRefreshing ||
        !_shouldStayConnected ||
        _profile == null) {
      return;
    }

    _isRefreshing = true;
    final generation = ++_connectionGeneration;
    try {
      await _connectWithFallback(showFailure: !silent, generation: generation);
    } finally {
      _isRefreshing = false;
    }
  }

  Future<bool> _connectWithFallback({
    required bool showFailure,
    required int generation,
  }) async {
    final profile = _profile;
    if (profile == null) {
      return false;
    }

    _retryTimer?.cancel();
    if (mounted) {
      setState(() {
        _isLoading = true;
        _isTunnelHealthy = false;
        _nextRetryDelay = null;
      });
    }

    final endpointsToTry = _buildEndpointOrder(profile);
    String? lastError;

    for (final endpoint in endpointsToTry) {
      if (!_shouldStayConnected || generation != _connectionGeneration) {
        return false;
      }

      try {
        await v2ray.stopV2Ray();

        final configLink = _buildConfigLink(profile, endpoint);
        final v2rayUrl = V2rayMyanmar.parseFromURL(configLink);

        await v2ray.startV2Ray(
          remark: 'VPS:${endpoint.port}:${endpoint.serverName}',
          config: v2rayUrl.getFullConfiguration(),
          enableWatchdog: false,
        );

        if (!_shouldStayConnected || generation != _connectionGeneration) {
          await v2ray.stopV2Ray();
          return false;
        }

        final delay = await _waitUntilTunnelHealthy(profile, generation);
        if (!_shouldStayConnected || generation != _connectionGeneration) {
          await v2ray.stopV2Ray();
          return false;
        }
        if (delay != null) {
          if (!mounted) {
            return true;
          }

          setState(() {
            _activeEndpoint = endpoint;
            _isLoading = false;
            _isTunnelHealthy = true;
            _consecutiveHealthFailures = 0;
            _retryAttempt = 0;
          });
          return true;
        }

        lastError =
            'Tunnel check failed on ${endpoint.serverName}:${endpoint.port}';
      } catch (error) {
        lastError = error.toString();
      }
    }

    if (generation != _connectionGeneration || !_shouldStayConnected) {
      return false;
    }

    await v2ray.stopV2Ray();

    if (showFailure && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            lastError ?? 'VPS is unavailable. Automatic retry is enabled.',
          ),
        ),
      );
    }

    if (mounted) {
      setState(() {
        _activeEndpoint = null;
        _isLoading = false;
        _isTunnelHealthy = false;
      });
    }

    _scheduleRetry();
    return false;
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
    final flow = profile.flow.isEmpty ? '' : '&flow=${profile.flow}';
    return 'vless://${profile.uuid}@${profile.host}:${endpoint.port}?type=tcp&security=reality&pbk=${profile.publicKey}&fp=${profile.fingerprint}&sni=${endpoint.serverName}&sid=${profile.shortId}&spx=${profile.spiderX}$flow#VPS';
  }

  Future<int?> _waitUntilTunnelHealthy(
    VpnProfile profile,
    int generation,
  ) async {
    const poll = Duration(milliseconds: 250);
    final stopwatch = Stopwatch()..start();

    while (stopwatch.elapsed < _connectionStateTimeout) {
      if (!_shouldStayConnected || generation != _connectionGeneration) {
        return null;
      }
      if (v2rayStatus.state.toLowerCase() == 'connected') {
        return _probeTunnel(profile, tryAllUrls: true);
      }
      await Future<void>.delayed(poll);
    }

    return null;
  }

  Future<int?> _probeTunnel(
    VpnProfile profile, {
    required bool tryAllUrls,
  }) async {
    final urls = profile.healthCheckUrls;
    final attempts = tryAllUrls ? urls.length : 1;

    for (var attempt = 0; attempt < attempts; attempt++) {
      final index = (_healthUrlIndex + attempt) % urls.length;
      try {
        final delay = await v2ray
            .getConnectedServerDelay(url: urls[index])
            .timeout(_healthProbeTimeout, onTimeout: () => -1);
        if (delay > 0) {
          _healthUrlIndex = (index + 1) % urls.length;
          return delay;
        }
      } catch (_) {
        continue;
      }
    }

    _healthUrlIndex = (_healthUrlIndex + attempts) % urls.length;
    return null;
  }

  void _scheduleRetry() {
    if (!_shouldStayConnected || _retryTimer?.isActive == true) {
      return;
    }

    final retryExponent = min(_retryAttempt, 4);
    final baseSeconds = min(30, 2 << retryExponent);
    final delay = Duration(
      milliseconds: baseSeconds * 1000 + Random().nextInt(750),
    );
    _retryAttempt++;
    _nextRetryDelay = delay > _maximumRetryDelay ? _maximumRetryDelay : delay;

    if (mounted) {
      setState(() {});
    }

    _retryTimer = Timer(_nextRetryDelay!, () {
      _nextRetryDelay = null;
      unawaited(_refreshConnection(silent: true));
    });
  }

  Future<void> _stop() async {
    _shouldStayConnected = false;
    _connectionGeneration++;
    _retryTimer?.cancel();
    _nextRetryDelay = null;
    await v2ray.stopV2Ray();

    if (!mounted) {
      return;
    }

    setState(() {
      _activeEndpoint = null;
      _totalDown = 0;
      _totalUp = 0;
      _lastCoreDown = 0;
      _lastCoreUp = 0;
      _completedDown = 0;
      _completedUp = 0;
      _consecutiveHealthFailures = 0;
      _retryAttempt = 0;
      _isLoading = false;
      _isTunnelHealthy = false;
    });
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    final interval =
        _profile?.healthCheckInterval ?? const Duration(seconds: 15);
    _watchdogTimer = Timer.periodic(interval, (_) {
      unawaited(_checkTunnelHealth());
    });
  }

  Future<void> _checkTunnelHealth() async {
    final profile = _profile;
    if (!_shouldStayConnected ||
        _isLoading ||
        _isRefreshing ||
        _isHealthCheckRunning ||
        profile == null ||
        v2rayStatus.state.toLowerCase() != 'connected') {
      return;
    }

    _isHealthCheckRunning = true;
    try {
      final delay = await _probeTunnel(profile, tryAllUrls: false);
      if (!_shouldStayConnected) {
        return;
      }

      if (delay != null) {
        _consecutiveHealthFailures = 0;
        if (!_isTunnelHealthy && mounted) {
          setState(() {
            _isTunnelHealthy = true;
          });
        }
        return;
      }

      _consecutiveHealthFailures++;
      if (_consecutiveHealthFailures >= profile.maxConsecutiveHealthFailures) {
        if (mounted) {
          setState(() {
            _isTunnelHealthy = false;
          });
        }
        await _refreshConnection(silent: true);
      }
    } finally {
      _isHealthCheckRunning = false;
    }
  }

  @override
  void dispose() {
    _watchdogTimer?.cancel();
    _retryTimer?.cancel();
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
    final isConnected =
        _isTunnelHealthy && v2rayStatus.state.toLowerCase() == 'connected';
    final hasActiveSession = _shouldStayConnected;
    final buttonLabel = isConnected
        ? 'DISCONNECT'
        : hasActiveSession
        ? 'STOP'
        : 'CONNECT';
    final buttonAction = hasActiveSession ? _stop : _connect;
    final buttonColor = hasActiveSession
        ? Colors.redAccent
        : Colors.indigoAccent;

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
    if (_nextRetryDelay != null) {
      return 'Server unavailable. Retrying automatically';
    }
    if (_isLoading && _profile != null) {
      return 'Checking ${_profile!.ports.length} secure ports';
    }
    if (_shouldStayConnected) {
      return 'Checking tunnel connectivity';
    }
    return 'One tap protection with automatic recovery';
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
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 20,
          ),
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
      return _buildInfoCard(title: 'Profile error', subtitle: _profileError!);
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
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 20,
          ),
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
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 20,
          ),
        ],
      ),
      child: Column(
        children: [
          const Icon(Icons.info_outline, color: Colors.indigoAccent, size: 34),
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
    final canPress = _isCoreReady && !_isProfileLoading && _profile != null;

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
    required this.version,
    required this.host,
    required this.uuid,
    required this.publicKey,
    required this.shortId,
    required this.spiderX,
    required this.fingerprint,
    required this.flow,
    required this.ports,
    required this.serverNames,
    required this.healthCheckUrls,
    required this.healthCheckInterval,
    required this.maxConsecutiveHealthFailures,
  });

  final int version;
  final String host;
  final String uuid;
  final String publicKey;
  final String shortId;
  final String spiderX;
  final String fingerprint;
  final String flow;
  final List<int> ports;
  final List<String> serverNames;
  final List<String> healthCheckUrls;
  final Duration healthCheckInterval;
  final int maxConsecutiveHealthFailures;

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
    final host = _requiredString(json, 'host');
    final uuid = _requiredString(json, 'uuid');
    final publicKey = _requiredString(json, 'publicKey');
    final ports = _requiredList(
      json,
      'ports',
    ).map((value) => (value as num).toInt()).toList(growable: false);
    final serverNames = _requiredList(
      json,
      'serverNames',
    ).map((value) => value as String).toList(growable: false);
    final healthCheckUrls =
        (json['healthCheckUrls'] as List<dynamic>? ??
                const <dynamic>[
                  'http://connectivitycheck.gstatic.com/generate_204',
                  'https://cp.cloudflare.com/generate_204',
                ])
            .map((value) => value as String)
            .toList(growable: false);
    final healthCheckIntervalSeconds =
        (json['healthCheckIntervalSeconds'] as num?)?.toInt() ?? 15;
    final maxConsecutiveHealthFailures =
        (json['maxConsecutiveHealthFailures'] as num?)?.toInt() ?? 2;

    if (ports.any((port) => port < 1 || port > 65535)) {
      throw const FormatException('VPN profile contains an invalid port');
    }
    if (serverNames.any((name) => name.trim().isEmpty)) {
      throw const FormatException('VPN profile contains an empty server name');
    }
    if (healthCheckUrls.isEmpty ||
        healthCheckUrls.any((value) {
          final uri = Uri.tryParse(value);
          return uri == null ||
              !uri.hasAuthority ||
              (uri.scheme != 'http' && uri.scheme != 'https');
        })) {
      throw const FormatException('VPN profile contains an invalid health URL');
    }
    if (healthCheckIntervalSeconds < 5 || maxConsecutiveHealthFailures < 1) {
      throw const FormatException('VPN profile health settings are invalid');
    }

    return VpnProfile(
      version: (json['version'] as num?)?.toInt() ?? 1,
      host: host,
      uuid: uuid,
      publicKey: publicKey,
      shortId: json['shortId'] as String,
      spiderX: json['spiderX'] as String,
      fingerprint: json['fingerprint'] as String? ?? 'chrome',
      flow: json['flow'] as String? ?? 'xtls-rprx-vision',
      ports: ports,
      serverNames: serverNames,
      healthCheckUrls: healthCheckUrls,
      healthCheckInterval: Duration(seconds: healthCheckIntervalSeconds),
      maxConsecutiveHealthFailures: maxConsecutiveHealthFailures,
    );
  }

  static String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('VPN profile field "$key" is missing');
    }
    return value;
  }

  static List<dynamic> _requiredList(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! List<dynamic> || value.isEmpty) {
      throw FormatException('VPN profile field "$key" is missing');
    }
    return value;
  }
}

class VpnEndpoint {
  const VpnEndpoint({required this.port, required this.serverName});

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
