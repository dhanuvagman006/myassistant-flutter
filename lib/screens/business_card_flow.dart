import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/neon_tokens.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';

/// BUSINESS CARD SCANNER. Owner's pick, 2026-09-23.
///
/// One photo of a visiting card: the server reads it, saves the person
/// (with phone, email, company) and keeps the photo in their documents.
/// Then, on screen, the three things you do after meeting someone — put
/// them in your phone's contacts, say hello on WhatsApp, or call.
class BusinessCardFlow {
  BusinessCardFlow._();

  /// Camera → server → result sheet. Returns the saved person, or null if
  /// the user cancelled or the card could not be read (already explained).
  static Future<Map<String, dynamic>?> scan(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    XFile? shot;
    try {
      shot = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 1800,
        maxHeight: 1800,
        imageQuality: 85,
      );
    } catch (_) {
      messenger?.showSnackBar(
          const SnackBar(content: Text("Couldn't open the camera.")));
      return null;
    }
    if (shot == null) return null;
    if (!context.mounted) return null;

    // Reading takes a few seconds — say so.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ReadingDialog(),
    );
    Map<String, dynamic>? person;
    String? error;
    try {
      final req = http.MultipartRequest(
          'POST', Uri.parse('${ApiService.baseUrl}/clients/scan-card'));
      req.headers.addAll(ApiService.authHeaders..remove('Content-Type'));
      req.files.add(http.MultipartFile.fromBytes(
        'file',
        await shot.readAsBytes(),
        filename: 'card.jpg',
        contentType: MediaType('image', 'jpeg'),
      ));
      final r = await http.Response.fromStream(
          await req.send().timeout(const Duration(seconds: 60)));
      final body = jsonDecode(r.body) as Map;
      if (r.statusCode == 200) {
        person = (body['person'] as Map).cast<String, dynamic>();
      } else {
        error = (body['error'] ?? "Couldn't read that card.").toString();
      }
    } catch (_) {
      error = "Couldn't read that card — check your connection.";
    }
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (person == null) {
      messenger?.showSnackBar(SnackBar(content: Text(error!)));
      return null;
    }
    if (context.mounted) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Neon.surface,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (_) => CardResultSheet(person: person!),
      );
    }
    return person;
  }
}

class _ReadingDialog extends StatelessWidget {
  const _ReadingDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Neon.surface,
      content: Row(children: [
        SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: Neon.violet)),
        const SizedBox(width: 16),
        Expanded(
          child: Text('Reading the card…',
              style: TextStyle(color: Neon.textHi, fontSize: 15)),
        ),
      ]),
    );
  }
}

/// What was read off the card, and what to do next.
class CardResultSheet extends StatelessWidget {
  const CardResultSheet({super.key, required this.person});
  final Map<String, dynamic> person;

  List<String> _list(String k) =>
      ((person[k] as List?) ?? const []).map((e) => e.toString()).toList();

  String get _name => (person['name'] ?? '').toString();
  String get _phone => _list('phones').isEmpty ? '' : _list('phones').first;
  String get _email => _list('emails').isEmpty ? '' : _list('emails').first;

  /// The phone's own "new contact" screen, filled in — the user taps Save.
  Future<void> _addToContacts(BuildContext context) async {
    bool ok = false;
    try {
      ok = await const MethodChannel('hari/intent').invokeMethod<bool>(
            'insertContact',
            {
              'name': _name,
              'phone': _phone,
              'email': _email,
              'company': (person['company'] ?? '').toString(),
              'title': (person['title'] ?? '').toString(),
            },
          ) ??
          false;
    } catch (_) {}
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Couldn't open your contacts app.")));
    }
  }

  Future<void> _hello(BuildContext context) async {
    final me = (AuthService.instance.user?.name ?? '').trim().split(' ').first;
    final first = _name.split(' ').first;
    final text = 'Hi $first, it was great meeting you today.'
        '${me.isEmpty ? '' : ' — $me'}';
    var d = _phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (d.length == 10) d = '91$d';
    final uri = Uri.parse(d.isEmpty
        ? 'whatsapp://send?text=${Uri.encodeComponent(text)}'
        : 'whatsapp://send?phone=$d&text=${Uri.encodeComponent(text)}');
    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("WhatsApp isn't installed.")));
    }
  }

  Future<void> _call() async {
    if (_phone.isEmpty) return;
    try {
      await launchUrl(Uri.parse('tel:$_phone'));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final line2 = [person['title'], person['company']]
        .where((v) => (v ?? '').toString().isNotEmpty)
        .join(' · ');
    Widget field(IconData icon, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            Icon(icon, size: 16, color: Neon.textDim),
            const SizedBox(width: 10),
            Expanded(
                child: Text(text,
                    style: TextStyle(color: Neon.textLo, fontSize: 13.5))),
          ]),
        );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.check_circle_rounded, color: Neon.success, size: 20),
              const SizedBox(width: 8),
              Text('Saved to your people',
                  style: TextStyle(
                      color: Neon.success,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 12),
            Text(_name,
                style: TextStyle(
                    color: Neon.textHi,
                    fontSize: 22,
                    fontWeight: FontWeight.w700)),
            if (line2.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(line2, style: TextStyle(color: Neon.textLo, fontSize: 14)),
            ],
            const SizedBox(height: 14),
            for (final p in _list('phones')) field(Icons.phone_rounded, p),
            for (final e in _list('emails')) field(Icons.mail_rounded, e),
            if ((person['website'] ?? '').toString().isNotEmpty)
              field(Icons.language_rounded, person['website'].toString()),
            if ((person['address'] ?? '').toString().isNotEmpty)
              field(Icons.place_rounded, person['address'].toString()),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _addToContacts(context),
                icon: const Icon(Icons.person_add_alt_1_rounded),
                label: const Text('Add to phone contacts'),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _hello(context),
                  icon: const Icon(Icons.chat_rounded, color: Color(0xFF25D366)),
                  label: const Text('Say hello'),
                ),
              ),
              if (_phone.isNotEmpty) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _call,
                    icon: Icon(Icons.call_rounded, color: Neon.cyan),
                    label: const Text('Call'),
                  ),
                ),
              ],
            ]),
          ],
        ),
      ),
    );
  }
}
