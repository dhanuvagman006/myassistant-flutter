import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import '../design/apple_kit.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart'
    show NeonEmptyState, NeonErrorState, NeonLoader, NeonPill, NeonScaffold;
import '../features/assistant/widgets/action_cards.dart'
    show shareDocumentFile;
import '../models/client.dart';
import '../models/user_document.dart';
import '../services/api_service.dart';
import 'business_card_flow.dart';
import '../services/document_events.dart';
import '../widgets/document_tile.dart';
import '../services/app_feedback.dart';
import '../design/motion.dart';
import '../widgets/neon_cards.dart';

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
        setState(() => _error = "Couldn't load your clients");
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
    // The theme's sheet (2026-09-30): lit rim, night scrim, handle.
    final created = await showAppSheet<Client>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _EditClientSheet(),
    );
    if (created != null && mounted) {
      setState(() => _clients = [created, ...?_clients]);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Under the night sky, with the theme's lit FAB (2026-09-30).
    return NeonScaffold(
      appBar: appleAppBar(context, 'Clients & patients', actions: [
        IconButton(
          tooltip: 'Scan a business card',
          icon: const Icon(Icons.contact_mail_rounded),
          onPressed: () async {
            await BusinessCardFlow.scan(context);
          },
        ),
      ]),
      // One "Add" on an empty screen: the empty state's (2026-09-30).
      floatingActionButton: (_clients?.isEmpty ?? true)
          ? null
          : FloatingActionButton.extended(
              onPressed: _addClient,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('Add'),
            ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: AppleSearchField(
                hint: 'Search by name, summary or tag',
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(child: StateSwitch.of(_body())),
          ],
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
    if (_clients == null) return const NeonLoader.page();
    final rows = _filtered;
    if (rows.isEmpty) {
      return NeonEmptyState(
        icon: Icons.folder_shared_rounded,
        title: _query.isEmpty ? 'No clients or patients yet' : 'No matches',
        body: _query.isEmpty
            ? 'Add a patient or client to keep their documents and notes '
                'in one place, separate from your own documents.'
            : 'Nobody matches "$_query".',
        actionLabel: _query.isEmpty ? 'New case file' : null,
        actionIcon: Icons.person_add_alt_1_rounded,
        onAction: _query.isEmpty ? _addClient : null,
      );
    }
    return RefreshIndicator(
      color: Neon.violet,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          GroupedCard(
            dividerInset: 60,
            children: [for (final c in rows) _clientRow(c)],
          ),
        ],
      ),
    );
  }

  Widget _clientRow(Client c) {
    return AppleRow(
      // A lit initial (2026-09-30): the brand's glass and rim.
      leading: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: NeonTone.brand.fill,
          border: Border.all(color: Neon.violet.withValues(alpha: 0.6)),
        ),
        child: Text(
          c.name.isNotEmpty ? c.name[0].toUpperCase() : '?',
          style: NeonType.manrope(NeonType.body, FontWeight.w700)
              .copyWith(color: NeonTone.brand.ink),
        ),
      ),
      title: c.name,
      subtitle: c.summary.isNotEmpty ? c.summary : _kindLabel(c.kind),
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ClientDetailScreen(clientId: c.id)));
        _load(); // notes/docs may have changed the ordering
      },
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
  Map<String, dynamic>? _recall; // next pending recall, from the server
  double _balance = 0; // outstanding dues (positive = they owe)
  String? _error;
  bool _busy = false;
  bool _uploading = false;
  final _noteCtl = TextEditingController();
  int _seenVersion = DocumentEvents.version.value;

  @override
  void initState() {
    super.initState();
    // Reload when a document is filed here from elsewhere — e.g. the
    // assistant's "save this in Manish's section" while this file is open.
    DocumentEvents.version.addListener(_onDocumentsChanged);
    _load();
  }

  @override
  void dispose() {
    DocumentEvents.version.removeListener(_onDocumentsChanged);
    _noteCtl.dispose();
    super.dispose();
  }

  void _onDocumentsChanged() {
    if (DocumentEvents.version.value == _seenVersion) return;
    _seenVersion = DocumentEvents.version.value;
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await ApiService.fetchClientProfile(widget.clientId);
      if (!mounted) return;
      setState(() {
        _client = p.client;
        _notes = p.notes;
        _documents = p.documents;
        _recall = p.recall;
        _balance = p.balance;
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't load this case file");
    }
  }

  Future<void> _addNote() async {
    final text = _noteCtl.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final note = await ApiService.addClientNote(widget.clientId, text);
      if (!mounted) return; // user backed out while the request ran
      _noteCtl.clear();
      setState(() => _notes = [note, ..._notes]);
    } catch (_) {
      _toast("Couldn't save the note. Check your connection.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _attachDocument() async {
    // The theme's sheet, and the app's grouped rows in it (2026-09-30).
    final source = await showAppSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: GroupedCard(
            dividerInset: 60,
            children: [
              AppleRow(
                leading: IconTile(Icons.photo_camera_rounded, AppleColors.blue),
                title: 'Take a photo',
                onTap: () => Navigator.pop(ctx, 'camera'),
              ),
              AppleRow(
                leading:
                    IconTile(Icons.photo_library_rounded, AppleColors.blue),
                title: 'Pick from gallery',
                onTap: () => Navigator.pop(ctx, 'gallery'),
              ),
              AppleRow(
                leading:
                    IconTile(Icons.picture_as_pdf_rounded, AppleColors.red),
                title: 'Pick a PDF',
                onTap: () => Navigator.pop(ctx, 'pdf'),
              ),
            ],
          ),
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
            // Not PDFs only: a case file is as likely to be a Word draft,
            // a fee sheet or a deck, and the server reads all of them.
            allowedExtensions: const [
              'pdf', 'docx', 'xlsx', 'pptx', 'csv', 'txt', 'rtf'
            ],
            withData: true);
        final f = (picked != null && picked.files.isNotEmpty)
            ? picked.files.first
            : null;
        if (f?.bytes == null) return;
        bytes = f!.bytes!;
        filename = f.name;
        mime = mimeForFilename(f.name);
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

    setState(() {
      _busy = true;
      _uploading = true;
    });
    try {
      final result = await ApiService.uploadDocumentDetailed(
        bytes: bytes,
        filename: filename,
        mimeType: mime,
        note: 'Filed under ${_client?.name ?? "this case"}',
        clientId: widget.clientId,
      );
      _seenVersion = DocumentEvents.version.value; // our own bump
      // The server tells us where it filed it. Anything but THIS case file
      // is a failure from the user's point of view — say so.
      if (result.filedUnderClient && result.clientId == widget.clientId) {
        await _load(); // pull the fresh linked list (analysis lands later)
        _toast('Saved to ${_client?.name ?? "this"}\'s file.');
      } else {
        await _load();
        _toast("The document was saved but not to this file. Please check My documents.");
      }
    } on DocumentUploadException catch (e) {
      _toast(e.message.isNotEmpty
          ? "Couldn't upload that: ${e.message}"
          : "Couldn't upload that. Nothing was saved.");
    } catch (_) {
      _toast("Couldn't upload that — check your connection and try again.");
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _uploading = false;
        });
      }
    }
  }

  /// Deletes a document from this case file — and from the account.
  Future<bool> _deleteDocument(UserDocument d) async {
    final ok = await confirmDeleteDocument(context, d,
        where: "${_client?.name ?? 'this'}'s file");
    if (!ok || !mounted) return false;
    try {
      await ApiService.deleteDocument(d.id);
      _seenVersion = DocumentEvents.version.value;
      if (!mounted) return true;
      setState(() => _documents =
          _documents.where((x) => x.id != d.id).toList(growable: false));
      return true;
    } catch (_) {
      _toast("Couldn't delete. Check your connection and try again.");
      return false;
    }
  }

  void _openDocument(UserDocument d) =>
      openDocument(context, d, within: _documents, onDelete: _deleteDocument);

  Future<void> _shareDocument(UserDocument d) async {
    try {
      await shareDocumentFile(d);
    } catch (_) {
      _toast("Couldn't prepare that to share.");
    }
  }

  Future<void> _edit() async {
    if (_client == null) return;
    final updated = await showAppSheet<Client>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _EditClientSheet(existing: _client),
    );
    if (updated != null && mounted) setState(() => _client = updated);
  }

  Future<void> _delete() async {
    final n = _documents.length;
    final docsLine = n == 0
        ? ''
        : n == 1
            ? ' and the 1 document filed in it'
            : ' and the $n documents filed in it';
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete ${_client?.name ?? 'this case file'}?',
            style: TextStyle(color: Neon.textHi)),
        content: Text(
          'This permanently removes the case file, its notes$docsLine. '
          'This cannot be undone.',
          style: TextStyle(color: Neon.textLo, height: 1.4),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Delete',
                  style: TextStyle(color: Neon.errorInk))),
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
    AppFeedback.show(msg, context: context);
  }

  String _day(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.day}/${d.month}/${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final c = _client;
    // Under the night sky (2026-09-30); the bar's buttons are named.
    return NeonScaffold(
      appBar: appleAppBar(
        context,
        c?.name ?? 'Case file',
        actions: [
          IconButton(
              tooltip: 'Edit',
              icon: Icon(Icons.edit_rounded, color: Neon.textLo, size: 20),
              onPressed: c == null ? null : _edit),
          IconButton(
              tooltip: 'Delete',
              icon: Icon(Icons.delete_outline_rounded,
                  color: Neon.textLo, size: 20),
              onPressed: c == null ? null : _delete),
        ],
      ),
      body: SafeArea(
        child: c == null
            ? (_error != null
                ? NeonErrorState(
                    message: _error!,
                    onRetry: () {
                      setState(() => _error = null);
                      _load();
                    })
                : const NeonLoader.page())
            : RefreshIndicator(
                color: Neon.violet,
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  children: [
                    const GroupLabel('Details'),
                    _detailsGroup(c),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: GroupLabel(_documents.isEmpty
                              ? 'Documents'
                              : 'Documents (${_documents.length})'),
                        ),
                        TextButton.icon(
                          onPressed: _busy ? null : _attachDocument,
                          icon: Icon(Icons.add_rounded,
                              size: 16, color: Neon.violet),
                          label: Text('Attach',
                              style: TextStyle(
                                  color: Neon.violet,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    if (_uploading)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          children: [
                            const NeonLoader.inline(
                                size: 14, semanticLabel: 'Uploading'),
                            const SizedBox(width: 10),
                            Text('Uploading…',
                                style: TextStyle(
                                    color: Neon.textLo,
                                    fontSize: NeonType.footnote)),
                          ],
                        ),
                      ),
                    if (_documents.isEmpty && !_uploading)
                      _emptyRow(
                        Icons.description_outlined,
                        'No documents yet',
                        'Attach reports, prescriptions or scans. '
                            'They stay in ${c.name}\'s file only.',
                        tone: NeonTone.info,
                        actionLabel: 'Attach',
                        onAction: _busy ? null : _attachDocument,
                      )
                    else
                      for (final d in _documents)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: DocumentListTile(
                            document: d,
                            onOpen: () => _openDocument(d),
                            onShare: () => _shareDocument(d),
                            onDelete: () => _deleteDocument(d),
                          ),
                        ),
                    const SizedBox(height: 24),
                    const GroupLabel('Case notes'),
                    _noteComposer(),
                    if (_notes.isEmpty)
                      _emptyRow(
                        Icons.sticky_note_2_outlined,
                        'No notes yet',
                        tone: NeonTone.tip,
                        'Dated notes you add here are read back '
                            'when you ask about ${c.name}.',
                      )
                    else
                      GroupedCard(
                        children: [for (final n in _notes) _noteRow(n)],
                      ),
                  ],
                ),
              ),
      ),
    );
  }

  /// A SECTION'S EMPTY STATE, COMPACT (2026-09-30): the page-level
  /// NeonEmptyState's lit tile and words on the raised card, sized for a
  /// section of a page rather than the whole of it — with the section's
  /// next step as a lit pill where there is one.
  Widget _emptyRow(IconData icon, String title, String body,
      {NeonTone tone = NeonTone.brand,
      String? actionLabel,
      VoidCallback? onAction}) {
    return RimCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ToneTile(icon, tone, size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: NeonType.manrope(NeonType.body, FontWeight.w600)
                        .copyWith(color: Neon.textHi)),
                const SizedBox(height: 2),
                Text(body,
                    style: TextStyle(
                        color: Neon.textLo,
                        fontSize: NeonType.footnote,
                        height: 1.35)),
                if (actionLabel != null) ...[
                  const SizedBox(height: 6),
                  NeonPill(
                    label: actionLabel,
                    icon: Icons.add_rounded,
                    tone: tone,
                    onPressed: onAction,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _recallLine() {
    final r = _recall;
    if (r == null) return '';
    final due = (r['dueAt'] as num?)?.toInt() ?? 0;
    if (due <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(due);
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final note = (r['note'] ?? '').toString();
    return 'Next recall: ${d.day} ${months[d.month - 1]} ${d.year}'
        '${note.isNotEmpty ? ' — $note' : ''}';
  }

  String _balanceLine() {
    if (_balance > 0) return 'Owes ₹${_fmtAmt(_balance)}';
    if (_balance < 0) return 'In credit ₹${_fmtAmt(-_balance)}';
    return '';
  }

  static String _fmtAmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  Widget _detailsGroup(Client c) {
    final recallLine = _recallLine();
    final balanceLine = _balanceLine();
    final rows = <Widget>[
      AppleRow(
        title: _kindLabel(c.kind),
        subtitle: 'Since ${_day(c.createdAt)}',
      ),
      if (recallLine.isNotEmpty)
        AppleRow(
          leading:
              IconTile(Icons.event_repeat_rounded, AppleColors.orange),
          title: recallLine,
        ),
      if (balanceLine.isNotEmpty)
        AppleRow(
          leading:
              IconTile(Icons.currency_rupee_rounded, AppleColors.green),
          title: balanceLine,
        ),
      if (c.summary.isNotEmpty)
        AppleRow(
          leading: IconTile(Icons.info_outline_rounded, AppleColors.gray),
          title: c.summary,
          titleMaxLines: 6,
        ),
      if (c.phone.isNotEmpty)
        AppleRow(
          leading: IconTile(Icons.call_rounded, AppleColors.gray),
          title: c.phone,
        ),
      if (c.email.isNotEmpty)
        AppleRow(
          leading: IconTile(Icons.mail_outline_rounded, AppleColors.gray),
          title: c.email,
        ),
      if (c.tags.isNotEmpty)
        AppleRow(
          leading: IconTile(Icons.sell_outlined, AppleColors.gray),
          title: c.tags,
          titleMaxLines: 3,
        ),
    ];
    if (rows.length == 1) {
      rows.add(AppleRow(
        title: 'No details yet — tap the pencil to add.',
        titleColor: Neon.textDim,
        titleMaxLines: 2,
      ));
    }
    return GroupedCard(dividerInset: 60, children: rows);
  }

  Widget _noteComposer() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _noteCtl,
              style: TextStyle(color: Neon.textHi, fontSize: 14),
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'Add a dated note…',
                hintStyle: TextStyle(color: Neon.textDim),
                filled: true,
                fillColor: Neon.surfaceHigh,
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
            tooltip: 'Add note',
            onPressed: _busy ? null : _addNote,
            icon: Icon(Icons.send_rounded, color: Neon.violet),
          ),
        ],
      ),
    );
  }

  Widget _noteRow(ClientNote n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 4, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(_day(n.createdAt),
                  style: TextStyle(
                      color: Neon.textDim, fontSize: NeonType.caption)),
              const Spacer(),
              // 48 dp to the finger and named (2026-09-30): it was a bare
              // 15 dp cross.
              IconButton(
                tooltip: 'Delete note',
                visualDensity: VisualDensity.compact,
                onPressed: () async {
                  try {
                    await ApiService.deleteClientNote(widget.clientId, n.id);
                    if (!mounted) return;
                    setState(() =>
                        _notes = _notes.where((x) => x.id != n.id).toList());
                  } catch (_) {
                    _toast("Couldn't delete the note.");
                  }
                },
                icon:
                    Icon(Icons.close_rounded, size: 16, color: Neon.textDim),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(n.text,
              style: TextStyle(
                  color: Neon.textHi, fontSize: 14, height: 1.35)),
        ],
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
        labelStyle: TextStyle(color: Neon.textDim),
        filled: true,
        fillColor: Neon.surfaceHigh,
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
            style: NeonType.cardTitle.copyWith(color: Neon.textHi),
          ),
          const SizedBox(height: 14),
          TextField(
              controller: _name,
              style: TextStyle(color: Neon.textHi),
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
              ])
                // The theme's chip (2026-09-30).
                ChoiceChip(
                  label: Text(_kindLabel(k)),
                  selected: _kind == k,
                  onSelected: (_) => setState(() => _kind = k),
                ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
              controller: _summary,
              style: TextStyle(color: Neon.textHi),
              decoration:
                  _dec('One-line summary (e.g. "42M, type-2 diabetic")')),
          const SizedBox(height: 10),
          TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              style: TextStyle(color: Neon.textHi),
              decoration: _dec('Phone')),
          const SizedBox(height: 10),
          TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              style: TextStyle(color: Neon.textHi),
              decoration: _dec('Email')),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: TextStyle(
                    color: Neon.errorInk, fontSize: NeonType.footnote)),
          ],
          const SizedBox(height: 16),
          ApplePrimaryButton(
            label: _saving ? 'Saving…' : 'Save',
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
    );
  }
}
