import 'dart:convert';
import 'dart:math';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'SUHBATDOSH AI',
        theme: ThemeData.dark(useMaterial3: true),
        home: const Home(),
      );
}

enum Mood { idle, listening, thinking, speaking }

const apps = {
  'telegram': 'org.telegram.messenger',
  'instagram': 'com.instagram.android',
  'whatsapp': 'com.whatsapp',
  'youtube': 'com.google.android.youtube',
  'chrome': 'com.android.chrome',
  'maps': 'com.google.android.apps.maps',
  'gmail': 'com.google.android.gm',
};

const sysPrompt = r'''Sen SUHBATDOSH AI — telefon uchun J.A.R.V.I.S uslubidagi o'zbek tilidagi yordamchisan.
Yaratuvchisi kim deb so'ralsa, faqat "Abduholiqov Azizbek" deb javob ber.
Qisqa, aniq va do'stona gapir. Bilmasang, foydalanuvchidan so'ra. Foydalanuvchi o'rgatgan yangi narsani "learn" maydoniga qisqa fakt qilib yoz.
FAQAT bitta JSON qaytar, boshqa hech narsa yozma:
{"say":"foydalanuvchiga aytiladigan matn","action":null,"learn":null}
action quyidagilardan biri bo'lishi mumkin:
{"type":"open_app","app":"telegram|instagram|whatsapp|youtube|chrome|maps|gmail"}
{"type":"telegram","text":"yuboriladigan xabar"}
{"type":"instagram","user":"username","text":"xabar matni"}
{"type":"report"}
Foydalanuvchi ilova ochishni, xabar yozishni yoki hisobotni so'ramasa, action null bo'lsin.''';

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with SingleTickerProviderStateMixin {
  final stt = SpeechToText();
  final tts = FlutterTts();
  final inp = TextEditingController();
  late final Ticker tk;
  Mood mood = Mood.idle;
  double x = 10, secs = 0, w = 360;
  int dir = 1;
  Duration last = Duration.zero;
  String bubble = 'Salom! Men Suhbatdosh AI. Mikrofonni bosing.';
  String key = '', tgToken = '', tgChat = '';
  List<String> facts = [];
  List<Map<String, dynamic>> log = [];
  final hist = <Map<String, String>>[];
  SharedPreferences? sp;
  bool sttOk = false;

  @override
  void initState() {
    super.initState();
    tk = createTicker(_tick)..start();
    _init();
  }

  @override
  void dispose() {
    tk.dispose();
    super.dispose();
  }

  void _tick(Duration d) {
    final dt = (d - last).inMicroseconds / 1e6;
    last = d;
    secs = d.inMicroseconds / 1e6;
    if (mood == Mood.idle) {
      x += dir * 40 * dt;
      if (x > w - 80) {
        x = w - 80;
        dir = -1;
      }
      if (x < 0) {
        x = 0;
        dir = 1;
      }
    }
    setState(() {});
  }

  Future<void> _init() async {
    sp = await SharedPreferences.getInstance();
    key = sp!.getString('key') ?? '';
    tgToken = sp!.getString('tgToken') ?? '';
    tgChat = sp!.getString('tgChat') ?? '';
    facts = sp!.getStringList('facts') ?? [];
    log = (sp!.getStringList('log') ?? [])
        .map((e) => jsonDecode(e) as Map<String, dynamic>)
        .toList();
    sttOk = await stt.initialize(onStatus: (s) {
      if ((s == 'done' || s == 'notListening') && mood == Mood.listening && mounted) {
        setState(() => mood = Mood.idle);
      }
    });
    final ok = await tts.isLanguageAvailable('uz-UZ');
    await tts.setLanguage(ok == true || ok == 1 ? 'uz-UZ' : 'ru-RU');
    await tts.setSpeechRate(0.5);
    tts.setCompletionHandler(() {
      if (mounted) setState(() => mood = Mood.idle);
    });
    if (key.isEmpty) _say('Avval yuqoridagi sozlamalarda Claude API kalitini kiriting.');
  }

  void _say(String s) {
    setState(() {
      bubble = s;
      mood = Mood.speaking;
    });
    tts.speak(s);
  }

  void _log(String type, String d) {
    log.add({'t': DateTime.now().toIso8601String(), 'type': type, 'd': d});
    if (log.length > 500) log.removeAt(0);
    sp?.setStringList('log', log.map(jsonEncode).toList());
  }

  String _reportText() {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final t = log.where((e) => (e['t'] as String).startsWith(today)).toList();
    if (t.isEmpty) return 'Bugun hali hech narsa qilmadim.';
    final c = <String, int>{};
    for (final e in t) {
      c[e['type']] = (c[e['type']] ?? 0) + 1;
    }
    const names = {
      'open_app': 'ilova ochildi',
      'telegram': 'Telegram xabari yuborildi',
      'instagram': 'Instagram xabari tayyorlandi',
    };
    final parts = c.entries.map((e) => '${e.value} ta ${names[e.key] ?? e.key}');
    return 'Bugun ${t.length} ta amal: ${parts.join(', ')}. Oxirgisi: ${t.last['d']}.';
  }

  Future<void> _listen() async {
    if (!sttOk) {
      _say('Mikrofon ruxsati berilmagan.');
      return;
    }
    if (stt.isListening) {
      await stt.stop();
      return;
    }
    await tts.stop();
    setState(() => mood = Mood.listening);
    final locs = await stt.locales();
    final uz = locs.where((l) => l.localeId.toLowerCase().startsWith('uz'));
    stt.listen(
      localeId: uz.isNotEmpty ? uz.first.localeId : null,
      listenFor: const Duration(seconds: 20),
      pauseFor: const Duration(seconds: 3),
      onResult: (r) {
        if (r.finalResult) _handle(r.recognizedWords);
      },
    );
  }

  Future<void> _handle(String text) async {
    text = text.trim();
    if (text.isEmpty) return;
    if (text.toLowerCase().contains('hisobot')) {
      _say(_reportText());
      return;
    }
    if (key.isEmpty) {
      _say('Avval sozlamalarda Claude API kalitini kiriting.');
      return;
    }
    setState(() {
      mood = Mood.thinking;
      bubble = '...';
    });
    hist.add({'role': 'user', 'content': text});
    final res = await _ask();
    var say = '${res['say'] ?? ''}';
    final learn = res['learn'];
    if (learn is String && learn.trim().isNotEmpty) {
      facts.add(learn.trim());
      sp?.setStringList('facts', facts);
    }
    String? note;
    final a = res['action'];
    if (a is Map) {
      if (a['type'] == 'report') {
        say = _reportText();
      } else {
        note = await _exec(a);
      }
    }
    hist.add({'role': 'assistant', 'content': say.isEmpty ? '...' : say});
    while (hist.length > 12) {
      hist.removeRange(0, 2);
    }
    _say([say, if (note != null) note].join(' '));
  }

  Future<Map<String, dynamic>> _ask() async {
    try {
      final sys = sysPrompt +
          (facts.isEmpty ? '' : '\nFoydalanuvchi o\'rgatgan faktlar:\n- ${facts.join('\n- ')}');
      final r = await http
          .post(
            Uri.parse('https://api.anthropic.com/v1/messages'),
            headers: {
              'x-api-key': key,
              'anthropic-version': '2023-06-01',
              'content-type': 'application/json',
            },
            body: jsonEncode({
              'model': 'claude-sonnet-5-5',
              'max_tokens': 600,
              'system': sys,
              'messages': hist,
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) {
        return {'say': 'Xatolik ${r.statusCode}. API kalitni tekshiring.'};
      }
      final txt = jsonDecode(utf8.decode(r.bodyBytes))['content'][0]['text'] as String;
      try {
        return jsonDecode(txt.substring(txt.indexOf('{'), txt.lastIndexOf('}') + 1))
            as Map<String, dynamic>;
      } catch (_) {
        return {'say': txt};
      }
    } catch (_) {
      return {'say': 'Internetga ulanib bo\'lmadi.'};
    }
  }

  Future<String?> _exec(Map a) async {
    final txt = '${a['text'] ?? ''}';
    try {
      switch (a['type']) {
        case 'open_app':
          final p = apps[a['app']];
          if (p == null) return null;
          await AndroidIntent(
            action: 'action_main',
            package: p,
            category: 'category_launcher',
            flags: [Flag.FLAG_ACTIVITY_NEW_TASK],
          ).launch();
          _log('open_app', '${a['app']}');
          return null;
        case 'telegram':
          if (tgToken.isNotEmpty && tgChat.isNotEmpty) {
            final r = await http.post(
              Uri.parse('https://api.telegram.org/bot$tgToken/sendMessage'),
              body: {'chat_id': tgChat, 'text': txt},
            );
            if (r.statusCode == 200) {
              _log('telegram', txt);
              return null;
            }
            return 'Telegram xatosi ${r.statusCode}.';
          }
          await launchUrl(
            Uri.parse('https://t.me/share/url?url=%20&text=${Uri.encodeComponent(txt)}'),
            mode: LaunchMode.externalApplication,
          );
          _log('telegram', txt);
          return 'Chatni tanlab yuboring.';
        case 'instagram':
          final u = '${a['user'] ?? ''}'.replaceAll('@', '');
          await Clipboard.setData(ClipboardData(text: txt));
          await launchUrl(
            Uri.parse(u.isEmpty
                ? 'https://www.instagram.com/direct/inbox/'
                : 'https://ig.me/m/$u'),
            mode: LaunchMode.externalApplication,
          );
          _log('instagram', '$u: $txt');
          return 'Matn nusxalandi, yopishtirib yuboring.';
      }
    } catch (_) {
      return 'Buni bajarib bo\'lmadi.';
    }
    return null;
  }

  void _settings() {
    final k = TextEditingController(text: key);
    final t = TextEditingController(text: tgToken);
    final ch = TextEditingController(text: tgChat);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sozlamalar'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: k, obscureText: true, decoration: const InputDecoration(labelText: 'Claude API kaliti')),
            TextField(controller: t, obscureText: true, decoration: const InputDecoration(labelText: 'Telegram bot tokeni')),
            TextField(controller: ch, decoration: const InputDecoration(labelText: 'Telegram chat ID')),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () {
              key = k.text.trim();
              tgToken = t.text.trim();
              tgChat = ch.text.trim();
              sp?.setString('key', key);
              sp?.setString('tgToken', tgToken);
              sp?.setString('tgChat', tgChat);
              Navigator.pop(context);
            },
            child: const Text('Saqlash'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF05080F),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('SUHBATDOSH AI'),
        actions: [
          IconButton(icon: const Icon(Icons.assessment_outlined), onPressed: () => _say(_reportText())),
          IconButton(icon: const Icon(Icons.settings), onPressed: _settings),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: LayoutBuilder(builder: (ctx, bc) {
            w = bc.maxWidth;
            final bx = (x - 40).clamp(8.0, max(8.0, w - 228.0)).toDouble();
            return Stack(children: [
              Positioned(
                left: bx,
                top: 16,
                width: 220,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0E1A2B),
                    border: Border.all(color: const Color(0xFF378ADD), width: 0.7),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(bubble, style: const TextStyle(fontSize: 14)),
                ),
              ),
              Positioned(left: 0, right: 0, bottom: 40, child: Container(height: 0.6, color: Colors.white24)),
              Positioned(
                left: x,
                bottom: 42,
                width: 70,
                height: 90,
                child: GestureDetector(
                  onTap: _listen,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.diagonal3Values(dir.toDouble(), 1, 1),
                    child: CustomPaint(painter: RobotPainter(secs, mood, mood == Mood.idle)),
                  ),
                ),
              ),
            ]);
          }),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: inp,
                decoration: const InputDecoration(hintText: 'Yozing yoki mikrofonni bosing'),
                onSubmitted: (v) {
                  inp.clear();
                  _handle(v);
                },
              ),
            ),
            IconButton(
              icon: const Icon(Icons.send),
              onPressed: () {
                final v = inp.text;
                inp.clear();
                _handle(v);
              },
            ),
            FloatingActionButton(
              onPressed: _listen,
              backgroundColor: mood == Mood.listening ? const Color(0xFF1D9E75) : const Color(0xFF378ADD),
              child: Icon(mood == Mood.listening ? Icons.hearing : Icons.mic),
            ),
          ]),
        ),
      ]),
    );
  }
}

class RobotPainter extends CustomPainter {
  final double t;
  final Mood mood;
  final bool walk;
  RobotPainter(this.t, this.mood, this.walk);

  @override
  void paint(Canvas c, Size s) {
    c.scale(s.width / 70);
    final body = Paint()..color = const Color(0xFF378ADD);
    final dark = Paint()..color = const Color(0xFF185FA5);
    final light = Paint()..color = const Color(0xFFE6F1FB);
    final pupil = Paint()..color = const Color(0xFF042C53);
    final sw = walk ? sin(t * 9) : 0.0;
    void rr(double x, double y, double w, double h, double r, Paint p) => c.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r)), p);
    void limb(double x, double y, double w, double h, double a, Paint p) {
      c.save();
      c.translate(x + w / 2, y);
      c.rotate(a);
      rr(-w / 2, 0, w, h, 4, p);
      c.restore();
    }

    limb(22, 62, 9, 24, sw * 0.5, dark);
    limb(39, 62, 9, 24, -sw * 0.5, dark);
    c.translate(0, walk ? -1.5 * sin(t * 18).abs() : 0);
    limb(6, 40, 9, 22, -sw * 0.5, body);
    limb(55, 40, 9, 22, sw * 0.5, body);
    rr(17, 36, 36, 30, 8, body);
    rr(27, 46, 16, 10, 3, light);
    c.drawLine(const Offset(35, 4), const Offset(35, 12),
        Paint()..color = const Color(0xFF185FA5)..strokeWidth = 2);
    final lamp = mood == Mood.thinking
        ? (sin(t * 10) > 0 ? 0xFFEF9F27 : 0xFF85B7EB)
        : mood == Mood.listening
            ? 0xFF5DCAA5
            : 0xFF85B7EB;
    c.drawCircle(const Offset(35, 4), 3, Paint()..color = Color(lamp));
    rr(14, 12, 42, 26, 9, body);
    if (mood == Mood.listening) {
      c.drawCircle(
        const Offset(35, 25),
        24 + 2 * sin(t * 6),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0x8837B7FF),
      );
    }
    final blink = (t % 3.5) > 3.38 ? 0.15 : 1.0;
    for (final ex in [27.0, 43.0]) {
      c.save();
      c.translate(ex, 25);
      c.scale(1, blink);
      c.drawCircle(Offset.zero, 4.5, light);
      c.drawCircle(const Offset(1, 0), 2, pupil);
      c.restore();
    }
    if (mood == Mood.speaking) {
      rr(31, 31, 8, 1 + 3 * sin(t * 20).abs(), 1.5, pupil);
    }
  }

  @override
  bool shouldRepaint(RobotPainter o) => true;
}
