import 'package:flutter/material.dart';
import 'package:v2ray_myanmar/v2ray_myanmar.dart';
import 'package:http/http.dart' as http;
import 'package:google_fonts/google_fonts.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
  late V2rayMyanmar v2ray;
  V2RayStatus v2rayStatus = V2RayStatus();

  bool _isCoreReady = false;
  bool _isLoading = false;
  bool _isHomeOnline = false;

  int _totalDown = 0;
  int _totalUp = 0;

  // --- CONFIGURATION ---
  final String apiServer = "http://46.247.42.87:8080/get-ip";
  final String vpsIp = "46.247.42.87";
  final String vpsUuid = "2d27e4fc-3ba2-4dea-b95b-9d735fc48036";
  final String vpsPbk = "oVhFUmPi8A4iQBfVyeloF56lY89o5Zeu8aLuy_aV_Ww";
  final String homeUuid = "6dda34ec-5578-47be-94c7-77ce37a73834";
  final String homePbk = "LeKJmGS_WPQ1d9kU5yUB7ai1W99HTSjRw_yowGO48U4";

  @override
  void initState() {
    super.initState();
    _initEngine();
  }

  Future<void> _initEngine() async {
    v2ray = V2rayMyanmar(
      onStatusChanged: (status) {
        if (mounted) {
          setState(() {
            v2rayStatus = status;
            if (status.state.toLowerCase() == "connected") {
              _totalDown += status.downloadSpeed;
              _totalUp += status.uploadSpeed;
            }
          });
        }
      },
    );

    await v2ray.initializeV2Ray();
    setState(() => _isCoreReady = true);
    _checkHome();
  }

  Future<void> _checkHome() async {
    try {
      final res = await http
          .get(Uri.parse(apiServer))
          .timeout(const Duration(seconds: 5));
      final ip = jsonDecode(res.body)['home_ip'];
      final socket = await Socket.connect(
        ip,
        443,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
      setState(() => _isHomeOnline = true);
    } catch (_) {
      if (mounted) setState(() => _isHomeOnline = false);
    }
  }

  Future<void> _connect(String type) async {
    if (!_isCoreReady) return;
    if (!(await v2ray.requestPermission())) return;

    setState(() => _isLoading = true);

    try {
      String ip = vpsIp, uuid = vpsUuid, pbk = vpsPbk, sid = "61", spx = "%2F";

      if (type == "HOME") {
        final res = await http.get(Uri.parse(apiServer));
        ip = jsonDecode(res.body)['home_ip'];
        uuid = homeUuid;
        pbk = homePbk;
        sid = "12345678";
        spx = "";
      }

      final String configLink =
          "vless://$uuid@$ip:443?type=tcp&security=reality&pbk=$pbk&fp=chrome&sni=google.com&sid=$sid&spx=$spx&flow=xtls-rprx-vision#$type";

      final v2rayUrl = await V2rayMyanmar.parseFromURL(configLink);
      await v2ray.startV2Ray(
        remark: type,
        config: v2rayUrl.getFullConfiguration(),
      );
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Ошибка: $e")));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _stop() async {
    await v2ray.stopV2Ray();
    setState(() {
      _totalDown = 0;
      _totalUp = 0;
    });
  }

  String _fmt(int bytes) {
    if (bytes <= 0) return "0 B";
    const units = ["B", "KB", "MB", "GB"];
    int i = (log(bytes) / log(1024)).floor();
    return "${(bytes / pow(1024, i)).toStringAsFixed(1)} ${units[i]}";
  }

  @override
  Widget build(BuildContext context) {
    bool isConnected = v2rayStatus.state.toLowerCase() == "connected";

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
                "Core Status: ${v2rayStatus.state}",
                style: TextStyle(fontSize: 10, color: Colors.grey[400]),
              ),
              const Spacer(),
              if (isConnected) _buildStatsPanel() else _buildServerList(),
              const SizedBox(height: 30),
              if (isConnected)
                _buildActionBtn("ПРЕРВАТЬ СОЕДИНЕНИЕ", Colors.redAccent, _stop),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            "Family VPN Pro",
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
          ),
          IconButton.filledTonal(
            onPressed: _checkHome,
            icon: const Icon(Icons.refresh_rounded),
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
          BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 20),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _stat(
                Icons.arrow_downward,
                "SPEED",
                "${_fmt(v2rayStatus.downloadSpeed)}/s",
              ),
              _stat(
                Icons.arrow_upward,
                "SPEED",
                "${_fmt(v2rayStatus.uploadSpeed)}/s",
              ),
            ],
          ),
          const Divider(height: 40),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _stat(Icons.cloud_download, "TOTAL DOWN", _fmt(_totalDown)),
              _stat(Icons.cloud_upload, "TOTAL UP", _fmt(_totalUp)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(IconData i, String l, String v) {
    return Column(
      children: [
        Icon(i, size: 22, color: Colors.indigoAccent),
        const SizedBox(height: 4),
        Text(
          v,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
        ),
        Text(
          l,
          style: const TextStyle(
            fontSize: 10,
            color: Colors.grey,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildServerList() {
    return Column(
      children: [
        _serverCard(
          "Домашний ПК (Астана)",
          Icons.laptop_windows_rounded,
          _isHomeOnline,
          () => _connect("HOME"),
        ),
        const SizedBox(height: 12),
        _serverCard(
          "Облачный Сервер (VPS)",
          Icons.cloud_queue_rounded,
          true,
          () => _connect("VPS"),
        ),
      ],
    );
  }

  Widget _serverCard(String n, IconData i, bool on, VoidCallback t) {
    return Card(
      elevation: 0,
      color: on ? Colors.white : Colors.grey[100],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: on ? Colors.indigoAccent.withOpacity(0.1) : Colors.transparent,
        ),
      ),
      child: ListTile(
        onTap: (on && !_isLoading) ? t : null,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
        leading: Icon(i, color: on ? Colors.indigoAccent : Colors.grey),
        title: Text(
          n,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: on ? Colors.black87 : Colors.grey,
          ),
        ),
        subtitle: Text(
          on ? "Доступен для подключения" : "Оффлайн (проверьте роутер)",
          style: const TextStyle(fontSize: 11),
        ),
        trailing: on
            ? const Icon(Icons.chevron_right_rounded)
            : const Icon(Icons.lock_outline_rounded, size: 18),
      ),
    );
  }

  Widget _buildActionBtn(String l, Color c, VoidCallback t) {
    return SizedBox(
      width: double.infinity,
      height: 65,
      child: ElevatedButton(
        onPressed: t,
        style: ElevatedButton.styleFrom(
          backgroundColor: c,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
        child: Text(
          l,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
      ),
    );
  }
}
