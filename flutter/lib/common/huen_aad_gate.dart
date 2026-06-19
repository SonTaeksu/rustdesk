// HUEN: 스태프(상담원) 빌드 전용 M365(Entra ID) 로그인 게이트.
//
// 동작(airtight, Option 2):
//   - 스태프 exe에는 서버 키가 baked 되어 있지 않다(Rust load_custom_client 참고).
//   - 앱 시작 시 이 게이트가 먼저 뜬다.
//       1) 캐시된 refresh token 으로 조용히(silent) 재인증 시도 → 성공하면 UI 없이 통과.
//       2) 실패하면 "Microsoft 365 로그인" 화면 → device-code 플로우.
//   - 인증 성공 시 id_token 을 설정 엔드포인트(/authconfig/config)로 보내 서버 키를 받아
//     OVERWRITE(in-memory)로 주입한다. 디스크에 키를 남기지 않으므로, 재시작하면 다시 인증해야 한다.
//
// 빌드 시 주입(--dart-define):
//   RUSTDESK_TECHNICIAN   = 1
//   RUSTDESK_AAD_TENANT   = <tenant id>
//   RUSTDESK_AAD_CLIENT   = <client id>
//   RUSTDESK_AAD_CONFIG_URL = https://<your-server>/authconfig/config

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// 이 빌드가 상담원(스태프)용인가. (고객 빌드는 false → 게이트 없음)
/// bool.fromEnvironment 는 "true"만 인식하므로(="1"은 false) String 비교로 "1"/"true" 모두 허용.
const String _technicianDefine = String.fromEnvironment('RUSTDESK_TECHNICIAN');
const bool huenIsStaffBuild =
    _technicianDefine == '1' || _technicianDefine == 'true';

const String _aadTenant = String.fromEnvironment('RUSTDESK_AAD_TENANT');
const String _aadClient = String.fromEnvironment('RUSTDESK_AAD_CLIENT');
const String _aadConfigUrl = String.fromEnvironment('RUSTDESK_AAD_CONFIG_URL');

const String _rtCacheKey = 'huen-aad-rt'; // refresh token 로컬 캐시 키
const String _scope = 'openid profile offline_access';

const Color _huenGreen = Color(0xFF0a6734);
const Color _huenLime = Color(0xFF97c93c);

enum _Stage { checking, login, waiting, authed, error }

class HuenAadGate extends StatefulWidget {
  final Widget child;
  const HuenAadGate({Key? key, required this.child}) : super(key: key);

  @override
  State<HuenAadGate> createState() => _HuenAadGateState();
}

class _HuenAadGateState extends State<HuenAadGate> {
  _Stage _stage = _Stage.checking;
  String _message = '';
  String _userCode = '';
  String _verificationUri = '';

  String get _tokenUrl =>
      'https://login.microsoftonline.com/$_aadTenant/oauth2/v2.0/token';
  String get _deviceCodeUrl =>
      'https://login.microsoftonline.com/$_aadTenant/oauth2/v2.0/devicecode';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    debugPrint('HUEN_AAD init staff=$huenIsStaffBuild url=$_aadConfigUrl');
    // 빌드 설정 누락 시 fail-closed (게이트를 우회시키지 않는다)
    if (_aadTenant.isEmpty || _aadClient.isEmpty || _aadConfigUrl.isEmpty) {
      _fail('AAD 설정이 빌드에 없습니다.\n--dart-define=RUSTDESK_AAD_TENANT/CLIENT/CONFIG_URL 필요');
      return;
    }
    setState(() => _stage = _Stage.checking);
    final rt = bind.mainGetLocalOption(key: _rtCacheKey);
    if (rt.isNotEmpty && await _silent(rt)) return;
    if (mounted) setState(() => _stage = _Stage.login);
  }

  /// 캐시된 refresh token 으로 조용히 재인증. 성공 시 true.
  Future<bool> _silent(String rt) async {
    try {
      final res = await http.post(Uri.parse(_tokenUrl), body: {
        'grant_type': 'refresh_token',
        'client_id': _aadClient,
        'refresh_token': rt,
        'scope': _scope,
      });
      if (res.statusCode != 200) return false;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final idToken = j['id_token'] as String?;
      final newRt = j['refresh_token'] as String?;
      if (idToken == null) return false;
      if (newRt != null && newRt.isNotEmpty) {
        await bind.mainSetLocalOption(key: _rtCacheKey, value: newRt);
      }
      if (await _applyConfig(idToken) == null) {
        if (mounted) setState(() => _stage = _Stage.authed);
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// id_token 을 설정 엔드포인트로 보내 서버 키를 받아 in-memory 주입.
  /// 성공 시 null, 실패 시 사유 문자열(화면 표시용) 반환.
  Future<String?> _applyConfig(String idToken) async {
    try {
      final res = await http.get(Uri.parse(_aadConfigUrl),
          headers: {'Authorization': 'Bearer $idToken'});
      debugPrint('HUEN_AAD applyConfig status=${res.statusCode}');
      if (res.statusCode != 200) {
        return 'config HTTP ${res.statusCode}\n$_aadConfigUrl\n${res.body}';
      }
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final key = j['key'] as String?;
      if (key == null || key.isEmpty) return 'config 응답에 key 없음:\n${res.body}';
      // 디스크 저장 없이 OVERWRITE(in-memory)로 주입 → toml에 키가 안 남음
      await bind.mainSetOverrideOption(key: 'key', value: key);
      debugPrint('HUEN_AAD applyConfig OK (key injected)');
      return null;
    } catch (e) {
      debugPrint('HUEN_AAD applyConfig EXCEPTION $e');
      return 'config 호출 예외:\n$_aadConfigUrl\n$e';
    }
  }

  Future<void> _login() async {
    setState(() {
      _stage = _Stage.waiting;
      _message = '로그인 코드 요청 중...';
      _userCode = '';
      _verificationUri = '';
    });
    try {
      final res = await http.post(Uri.parse(_deviceCodeUrl),
          body: {'client_id': _aadClient, 'scope': _scope});
      if (res.statusCode != 200) {
        _fail('로그인 시작 실패: ${res.body}');
        return;
      }
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final deviceCode = j['device_code'] as String;
      final interval = (j['interval'] as int?) ?? 5;
      if (!mounted) return;
      setState(() {
        _userCode = (j['user_code'] as String?) ?? '';
        _verificationUri =
            (j['verification_uri'] as String?) ?? 'https://login.microsoft.com/device';
        _message = (j['message'] as String?) ?? '';
        _stage = _Stage.waiting;
      });
      _openVerifyPage();
      await _poll(deviceCode, interval);
    } catch (e) {
      _fail('오류: $e');
    }
  }

  void _openVerifyPage() {
    if (_verificationUri.isEmpty) return;
    try {
      launchUrl(Uri.parse(_verificationUri), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _poll(String deviceCode, int interval) async {
    int netErrors = 0; // 연속 네트워크/DNS 오류 카운트
    while (mounted) {
      await Future.delayed(Duration(seconds: interval));
      if (!mounted) return;
      http.Response? res;
      try {
        res = await http.post(Uri.parse(_tokenUrl), body: {
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'client_id': _aadClient,
          'device_code': deviceCode,
        });
        netErrors = 0;
      } catch (e) {
        // 폴링 중 일시적 DNS/네트워크 끊김(사설DNS DoT 등)은 무시하고 재시도
        netErrors++;
        debugPrint('HUEN_AAD poll net error #$netErrors: $e');
        if (netErrors >= 12) {
          _fail('네트워크/DNS 오류로 로그인 확인 실패:\n$e\n\n폰의 사설 DNS(Private DNS)나 네트워크 연결을 확인하세요.');
          return;
        }
        continue;
      }
      final r = res!; // catch는 항상 continue/return → 여기선 non-null
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode == 200) {
        debugPrint('HUEN_AAD poll: got token 200');
        final idToken = j['id_token'] as String?;
        final rt = j['refresh_token'] as String?;
        if (idToken == null) {
          _fail('토큰 응답에 id_token 없음');
          return;
        }
        if (rt != null && rt.isNotEmpty) {
          await bind.mainSetLocalOption(key: _rtCacheKey, value: rt);
        }
        final cfgErr = await _applyConfig(idToken);
        if (cfgErr == null) {
          if (mounted) setState(() => _stage = _Stage.authed);
        } else {
          _fail(cfgErr);
        }
        return;
      }
      final err = (j['error'] as String?) ?? '';
      if (err == 'authorization_pending') continue;
      if (err == 'slow_down') {
        interval += 5;
        continue;
      }
      _fail('로그인 실패: ${j['error_description'] ?? err}');
      return;
    }
  }

  void _fail(String msg) {
    if (mounted) setState(() {
      _stage = _Stage.error;
      _message = msg;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_stage == _Stage.authed) return widget.child;
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(32),
                // HUEN: 게이트는 흰 배경 → 기본 글자색을 진하게 강제(안 그러면 다크테마에서 흰글씨=안보임)
                child: DefaultTextStyle.merge(
                  style: const TextStyle(color: Colors.black87),
                  child: _body(),
                ),
              ),
            ),
          ),
          // HUEN 진단: 이 푸터가 보이면 = 게이트 화면이 떠 있는 것.
          //   빨간 ! 인데 이 푸터가 없다 = RustDesk 자체 연결 UI(게이트는 이미 통과).
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: Text(
              'HUEN gate · staff=$huenIsStaffBuild · $_stage\n$_aadConfigUrl',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10, color: Colors.black38),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    switch (_stage) {
      case _Stage.checking:
        return const Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(color: _huenGreen),
          SizedBox(height: 16),
          Text('확인 중...', style: TextStyle(color: Colors.black54)),
        ]);
      case _Stage.login:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('HUEN 원격지원',
              style: TextStyle(
                  fontSize: 24, fontWeight: FontWeight.bold, color: _huenGreen)),
          const SizedBox(height: 8),
          const Text('직원 인증이 필요합니다',
              style: TextStyle(fontSize: 14, color: Colors.black54)),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                  backgroundColor: _huenGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: _login,
              icon: const Icon(Icons.login),
              label: const Text('Microsoft 365로 로그인'),
            ),
          ),
        ]);
      case _Stage.waiting:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(color: _huenLime),
          const SizedBox(height: 20),
          if (_userCode.isNotEmpty) ...[
            const Text('아래 코드를 브라우저에 입력하세요',
                style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 8),
            SelectableText(_userCode,
                style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 3,
                    color: _huenGreen)),
            const SizedBox(height: 16),
          ],
          Text(_message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.black54)),
          if (_verificationUri.isNotEmpty) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _openVerifyPage,
              icon: const Icon(Icons.open_in_browser, color: _huenGreen),
              label: const Text('로그인 페이지 다시 열기',
                  style: TextStyle(color: _huenGreen)),
            ),
          ],
        ]);
      case _Stage.error:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 44),
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: SingleChildScrollView(
              child: SelectableText(_message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: Colors.black87)),
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: _huenGreen, foregroundColor: Colors.white),
            onPressed: _init,
            child: const Text('다시 시도'),
          ),
        ]);
      default:
        return const CircularProgressIndicator(color: _huenGreen);
    }
  }
}
