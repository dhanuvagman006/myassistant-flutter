import 'package:flutter/material.dart';

import '../design/neon_tokens.dart';
import '../services/api_service.dart';

/// Full-screen avatar face gallery — real portraits in a scrollable grid,
/// tap to choose. The choice saves immediately (no separate Save step) and
/// applies from the next video-avatar session.
class AvatarFaceScreen extends StatefulWidget {
  final List<Map<String, dynamic>> faces;
  final String selectedId; // '' = default
  const AvatarFaceScreen(
      {super.key, required this.faces, required this.selectedId});

  @override
  State<AvatarFaceScreen> createState() => _AvatarFaceScreenState();
}

class _AvatarFaceScreenState extends State<AvatarFaceScreen> {
  late String _selected = widget.selectedId;
  bool _saving = false;
  // The tap that OPENED this screen can fall through the route transition
  // and land on a grid cell, silently picking a random face (observed on
  // device). Ignore anything in the first instants after build.
  final _openedAt = DateTime.now();

  Future<void> _pick(String id) async {
    if (_saving) return;
    if (DateTime.now().difference(_openedAt) <
        const Duration(milliseconds: 500)) {
      return;
    }
    setState(() {
      _saving = true;
      _selected = id;
    });
    final r = await ApiService.sendJson('/profile/assistant',
        method: 'PUT', body: {'avatar_id': id.isEmpty ? 'default' : id});
    if (!mounted) return;
    setState(() => _saving = false);
    if (r == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't save — try again.")),
      );
      return;
    }
    Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    final cells = <Widget>[
      _cell(
        id: '',
        name: 'Default',
        child: Container(
          color: Neon.surfaceHigh,
          child: Icon(Icons.auto_awesome_rounded,
              color: Neon.violet, size: 40),
        ),
      ),
      for (final f in widget.faces)
        _cell(
          id: (f['id'] as String?) ?? '',
          name: (f['name'] as String?) ?? 'Face',
          child: f['thumb'] is String
              ? Image.network(
                  f['thumb'] as String,
                  fit: BoxFit.cover,
                  // Grid thumbnails — don't decode full-size portraits.
                  cacheWidth: 300,
                  loadingBuilder: (c, w, p) => p == null
                      ? w
                      : Container(
                          color: Neon.surfaceHigh,
                          alignment: Alignment.center,
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Neon.cyan),
                          ),
                        ),
                  errorBuilder: (_, __, ___) => _initialBox(f['name']),
                )
              : _initialBox(f['name']),
        ),
    ];

    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Avatar face'),
      ),
      body: GridView.count(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        crossAxisCount: 3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
        children: cells,
      ),
    );
  }

  Widget _initialBox(dynamic name) => Container(
        color: Neon.surfaceHigh,
        alignment: Alignment.center,
        child: Text(
          (name is String && name.isNotEmpty) ? name[0].toUpperCase() : '?',
          style: TextStyle(
              color: Neon.cyan, fontSize: 30, fontWeight: FontWeight.w700),
        ),
      );

  Widget _cell({required String id, required String name, required Widget child}) {
    final selected = _selected == id;
    return GestureDetector(
      onTap: () => _pick(id),
      child: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: selected
                          ? Neon.cyan
                          : Neon.line,
                      width: selected ? 2.5 : 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: child,
                  ),
                ),
                if (selected)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                          color: Neon.cyan, shape: BoxShape.circle),
                      child: const Icon(Icons.check_rounded,
                          size: 14, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? Neon.cyan : Neon.textLo,
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
