import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../features/assistant/widgets/action_cards.dart';
import '../models/client.dart';
import '../models/user_document.dart';
import '../services/api_service.dart';

/// PROFESSIONAL MODE — the case-file workspace.
///
/// A doctor, lawyer, CA… keeps one file per person: profile, dated case
/// notes and linked documents. Everything here is also reachable by
/// voice — "give me the details about patient Ramesh" speaks this exact
/// data and pops the documents on screen.
class ClientsScreen extends StatefulWidget {
  const ClientsScreen({super.key});

  @override
  State<ClientsScreen> createState() => _ClientsScreenState();
}

class _ClientsScreenState extends State<ClientsScreen> {
  List<Client>? _clients; // null = loading
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await ApiService.fetchClients();
      if (mounted) setState(() => _clients = rows);
    } catch (_) {
      if (mounted) {
        setState(() => _error = "Couldn't load your clients. Pull to retry.");
      }
    }
  }

  List<Client> get _filtered {
    final all = _clients ?? const [];
    if (_query.trim().isEmpty) return all;
    final q = _query.toLowerCase();
    return all
        .where((c) =>
            c.name.toLowerCase().contains(q) ||
            c.summary.toLowerCase().contains(q) ||
            c.tags.toLowerCase().contains(q))
        .toList();
  }

  Future<void> _addClient() async {
    final created = await showModalBottomSheet<Client>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Neon.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => const _EditClientSheet(),
    );
    if (created != null && mounted) {
      setState(() => _clients = [created, ...?_clients]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Neon.violet,
        onPressed: _addClient,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('Add'),
      ),
      body: AuroraBackdrop(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded,
                          color: Neon.textHi),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const Expanded(
                      child: Text(
                        'Clients & patients',
                        style: TextStyle(
                          color: Neon.textHi,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  style: const TextStyle(color: Neon.textHi),
                  decoration: InputDecoration(
                    hintText: 'Search by name, summary or tag',
                    hintStyle: const TextStyle(color: Neon.textDim),
                    prefixIcon:
                        const Icon(Icons.search_rounded, color: Neon.textDim),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.06),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_error != null) {
      return NeonErrorState(
          message: _error!,
          onRetry: () {
            setState(() {
              _error = null;
              _clients = null;
            });
            _load();
          });
    }
    if (_clients == null) return const Center(child: NeonLoader());
    final rows = _filtered;
    if (rows.isEmpty) {
      return NeonEmptyState(
        icon: Icons.folder_shared_rounded,
        title: _query.isEmpty ? 'No case files yet' : 'No matches',
        body: _query.isEmpty
            ? 'Add a patient or client, or just say:\n"note for patient Ramesh: first visit today"'
            : 'Nobody matches "$_query".',
      );
    }
    return RefreshIndicator(
      color: Neon.violet,
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
        itemCount: rows.length,
        itemBuilder: (_, i) => _clientTile(rows[i]),
      ),
    );
  }

  Widget _clientTile(Client c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ClientDetailScreen(clientId: c.id)));
          _load(); // notes/docs may have changed the ordering
        },
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: Neon.violet.withValues(alpha: 0.25),
              child: Text(
                c.name.isNotEmpty ? c.name[0].toUpperCase() : '?',
                style: const TextStyle(
                    color: Neon.textHi,
                    fontSize: 18,
                    fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Neon.textHi,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    c.summary.isNotEmpty ? c.summary : _kindLabel(c.kind),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Neon.textLo, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            NeonChip(label: _kindLabel(c.kind)),
          ],
        ),
      ),
    );
  }
}

String _kindLabel(String kind) {
  switch (kind) {
    case 'patient':
      return 'Patient';
    case 'student':
      return 'Student';
    case 'customer':
      return 'Customer';
    case 'client':
      return 'Client';
    default:
      return 'Contact';
  }
}

/* ====================================================================== */
/* Detail — the case file                                                  */
/* ====================================================================== */

class ClientDetailScreen extends StatefulWidget {
  final int clientId;
  const ClientDetailScreen({super.key, required this.clientId});

  @override
  State<ClientDetailScreen> createState() => _ClientDetailScreenState();
}

class _ClientDetailScreenState extends State<ClientDetailScreen> {
  Client? _client;
  List<ClientNote> _notes = const [];
  List<UserDocument> _documents = const [];
  String? _error;
  bool _busy = false;
  final _noteCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _noteCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final p = await ApiService.fetchClientProfile(widget.clientId);
      if (!mounted) return;
      setState(() {
        _client = p.client;
        _notes = p.notes;
        _documents = p.documents;
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't load this case file.");
    }
  }

  Future<void> _addNote() async {
    final text = _noteCtl.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final note = await ApiService.addClientNote(widget.clientId, text);
      _noteCtl.clear();
      setState(() => _notes = [note, ..._notes]);
    } catch (_) {
      _toast("Couldn't save the note. Check your connection.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _attachDocument() async {
    final source = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Neon.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded, color: Neon.cyan),
              title: const Text('Take a photo',
                  style: TextStyle(color: Neon.textHi)),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded, color: Neon.cyan),
              title: const Text('Pick from gallery',
                  style: TextStyle(color: Neon.textHi)),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf_rounded, color: Neon.pink),
              title:
                  const Text('Pick a PDF', style: TextStyle(color: Neon.textHi)),
              onTap: () => Navigator.pop(context, 'pdf'),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    List<int>? bytes;
    String filename = 'document';
    String mime = 'image/jpeg';
    try {
      if (source == 'pdf') {
        final picked = await FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: ['pdf'],
            withData: true);
        final f = (picked != null && picked.files.isNotEmpty)
            ? picked.files.first
            : null;
        if (f?.bytes == null) return;
        bytes = f!.bytes!;
        filename = f.name;
        mime = 'application/pdf';
      } else {
        final shot = await ImagePicker().pickImage(
          source: source == 'camera' ? ImageSource.camera : ImageSource.gallery,
          maxWidth: 1920,
          maxHeight: 1920,
          imageQuality: 82,
        );
        if (shot == null) return;
        bytes = await shot.readAsBytes();
        filename = 'case_${DateTime.now().millisecondsSinceEpoch}.jpg';
      }
    } catch (_) {
      _toast("Couldn't open that. Check the app's permissions.");
      return;
    }

    setState(() => _busy = true);
    try {
      await ApiService.uploadDocument(
        bytes: bytes,
        filename: filename,
        mimeType: mime,
        note: 'Filed under ${_client?.name ?? "this case"}',
        clientId: widget.clientId,
      );
      await _load(); // pull the fresh linked list (analysis lands later)
      _toast('Saved to the case file.');
    } catch (_) {
      _toast("Upload failed. Please try again.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit() async {
    if (_client == null) return;
    final updated = await showModalBottomSheet<Client>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Neon.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _EditClientSheet(existing: _client),
    );
    if (updated != null && mounted) setState(() => _client = updated);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Neon.surface,
        title: const Text('Delete this case file?',
            style: TextStyle(color: Neon.textHi)),
        content: const Text(
          'The card and its notes are removed. Saved documents are KEPT '
          'in your documents — only the link to this person is removed.',
          style: TextStyle(color: Neon.textLo),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child:
                  const Text('Delete', style: TextStyle(color: Neon.error))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ApiService.deleteClient(widget.clientId);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      _toast("Couldn't delete. Please try again.");
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  String _day(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.day}/${d.month}/${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final c = _client;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AuroraBackdrop(
        child: SafeArea(
          child: c == null
              ? (_error != null
                  ? NeonErrorState(message: _error!, onRetry: _load)
                  : const Center(child: NeonLoader()))
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back_rounded,
                                color: Neon.textHi),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                          Expanded(
                            child: Text(
                              c.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Neon.textHi,
                                  fontSize: 19,
                                  fontWeight: FontWeight.w700),
                            ),
                          ),
                          IconButton(
                              icon: const Icon(Icons.edit_rounded,
                                  color: Neon.textLo, size: 20),
                              onPressed: _edit),
                          IconButton(
                              icon: const Icon(Icons.delete_outline_rounded,
                                  color: Neon.textLo, size: 20),
                              onPressed: _delete),
                        ],
                      ),
                    ),
                    Expanded(
                      child: RefreshIndicator(
                        color: Neon.violet,
                        onRefresh: _load,
                        child: ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                          children: [
                            _profileCard(c),
                            const SizedBox(height: 4),
                            SectionHeader('Documents',
                                trailing: GhostButton(
                                    label: 'Attach',
                                    onPressed: _busy ? null : _attachDocument)),
                            if (_documents.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 6),
                                child: Text(
                                  'Nothing filed yet. Attach reports, '
                                  'prescriptions, contracts…',
                                  style: TextStyle(
                                      color: Neon.textDim, fontSize: 13),
                                ),
                              )
                            else
                              for (final d in _documents)
                                DocumentCard(document: d),
                            SectionHeader('Case notes'),
                            _noteComposer(),
                            if (_notes.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 6),
                                child: Text(
                                  'No notes yet. You can also add one by '
                                  'voice: "note for patient <name>: …"',
                                  style: TextStyle(
                                      color: Neon.textDim, fontSize: 13),
                                ),
                              )
                            else
                              for (final n in _notes) _noteTile(n),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _profileCard(Client c) {
    final rows = <(IconData, String)>[
      if (c.summary.isNotEmpty) (Icons.info_outline_rounded, c.summary),
      if (c.phone.isNotEmpty) (Icons.call_rounded, c.phone),
      if (c.email.isNotEmpty) (Icons.mail_outline_rounded, c.email),
      if (c.tags.isNotEmpty) (Icons.sell_outlined, c.tags),
    ];
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              NeonChip(label: _kindLabel(c.kind)),
              const Spacer(),
              Text('Since ${_day(c.createdAt)}',
                  style:
                      const TextStyle(color: Neon.textDim, fontSize: 12)),
            ],
          ),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('No details yet — tap the pencil to add.',
                  style: TextStyle(color: Neon.textDim, fontSize: 13)),
            )
          else
            for (final (icon, text) in rows)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 16, color: Neon.textLo),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(text,
                            style: const TextStyle(
                                color: Neon.textHi, fontSize: 13.5))),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _noteComposer() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _noteCtl,
              style: const TextStyle(color: Neon.textHi, fontSize: 14),
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'Add a dated note…',
                hintStyle: const TextStyle(color: Neon.textDim),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.06),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: _busy ? null : _addNote,
            icon: const Icon(Icons.send_rounded, color: Neon.violet),
          ),
        ],
      ),
    );
  }

  Widget _noteTile(ClientNote n) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(_day(n.createdAt),
                    style:
                        const TextStyle(color: Neon.textDim, fontSize: 11.5)),
                const Spacer(),
                GestureDetector(
                  onTap: () async {
                    try {
                      await ApiService.deleteClientNote(widget.clientId, n.id);
                      setState(() =>
                          _notes = _notes.where((x) => x.id != n.id).toList());
                    } catch (_) {
                      _toast("Couldn't delete the note.");
                    }
                  },
                  child: const Icon(Icons.close_rounded,
                      size: 15, color: Neon.textDim),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(n.text,
                style: const TextStyle(
                    color: Neon.textHi, fontSize: 13.5, height: 1.35)),
          ],
        ),
      ),
    );
  }
}

/* ====================================================================== */
/* Add / edit sheet                                                        */
/* ====================================================================== */

class _EditClientSheet extends StatefulWidget {
  final Client? existing;
  const _EditClientSheet({this.existing});

  @override
  State<_EditClientSheet> createState() => _EditClientSheetState();
}

class _EditClientSheetState extends State<_EditClientSheet> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _summary =
      TextEditingController(text: widget.existing?.summary ?? '');
  late final _phone = TextEditingController(text: widget.existing?.phone ?? '');
  late final _email = TextEditingController(text: widget.existing?.email ?? '');
  late String _kind = widget.existing?.kind ?? 'patient';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _summary.dispose();
    _phone.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'A name is required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final Client result;
      if (widget.existing == null) {
        result = await ApiService.createClient(
          name: name,
          kind: _kind,
          summary: _summary.text.trim(),
          phone: _phone.text.trim(),
          email: _email.text.trim(),
        );
      } else {
        result = await ApiService.updateClient(widget.existing!.id, {
          'name': name,
          'kind': _kind,
          'summary': _summary.text.trim(),
          'phone': _phone.text.trim(),
          'email': _email.text.trim(),
        });
      }
      if (mounted) Navigator.of(context).pop(result);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = "Couldn't save. Check your connection.";
        });
      }
    }
  }

  InputDecoration _dec(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Neon.textDim),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.06),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.existing == null ? 'New case file' : 'Edit case file',
            style: const TextStyle(
                color: Neon.textHi, fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          TextField(
              controller: _name,
              style: const TextStyle(color: Neon.textHi),
              decoration: _dec('Full name *')),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              for (final k in const [
                'patient',
                'client',
                'student',
                'customer',
                'other'
              ])
                ChoiceChip(
                  label: Text(_kindLabel(k)),
                  selected: _kind == k,
                  selectedColor: Neon.violet.withValues(alpha: 0.35),
                  onSelected: (_) => setState(() => _kind = k),
                ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
              controller: _summary,
              style: const TextStyle(color: Neon.textHi),
              decoration:
                  _dec('One-line summary (e.g. "42M, type-2 diabetic")')),
          const SizedBox(height: 10),
          TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              style: const TextStyle(color: Neon.textHi),
              decoration: _dec('Phone')),
          const SizedBox(height: 10),
          TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              style: const TextStyle(color: Neon.textHi),
              decoration: _dec('Email')),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(color: Neon.error, fontSize: 13)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: GradientButton(
              label: _saving ? 'Saving…' : 'Save',
              onPressed: _saving ? null : _save,
            ),
          ),
        ],
      ),
    );
  }
}
