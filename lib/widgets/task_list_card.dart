import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../services/api_service.dart';
import '../services/app_feedback.dart';
import '../services/auth_service.dart';
import 'chat_bubble.dart';

/// ─────────────────────────────────────────────────────────────────────
///  TEAM TASK LISTS (owner, 2026-10-04) — a native group-chat message.
///
///  The server owns the state (chat_task_lists / chat_task_items). A tap
///  sends the state the member wants (done or not), never "toggle", so two
///  people tapping at once each get what they asked for; the reply is the
///  whole list, which replaces what is shown. Other phones are told by a
///  silent push and refetch.
/// ─────────────────────────────────────────────────────────────────────
class TaskItem {
  final int id;
  final String text;
  final int? doneBy;
  final String doneByName;
  final int doneAt;
  const TaskItem(this.id, this.text, this.doneBy, this.doneByName, this.doneAt);

  bool get done => doneBy != null;

  factory TaskItem.fromJson(Map j) => TaskItem(
        (j['id'] as num?)?.toInt() ?? 0,
        (j['text'] ?? '').toString(),
        (j['doneBy'] as num?)?.toInt(),
        (j['doneByName'] ?? '').toString(),
        (j['doneAt'] as num?)?.toInt() ?? 0,
      );
}

class TaskList {
  final int id;
  final String title;
  final List<TaskItem> items;
  const TaskList(this.id, this.title, this.items);

  int get doneCount => items.where((i) => i.done).length;

  static TaskList? fromJson(Object? j) {
    if (j is! Map) return null;
    return TaskList(
      (j['id'] as num?)?.toInt() ?? 0,
      (j['title'] ?? '').toString(),
      [for (final i in (j['items'] as List? ?? const [])) if (i is Map) TaskItem.fromJson(i)],
    );
  }

  TaskList withItem(TaskItem t) =>
      TaskList(id, title, [for (final i in items) i.id == t.id ? t : i]);
}

/// Sets one task on the server; null when it failed (offline, removed).
Future<TaskList?> setTask(int groupId, int listId, int itemId, bool done) async {
  final r = await ApiService.postJson(
      '/chat/groups/$groupId/tasks/$listId/items/$itemId', {'done': done});
  return TaskList.fromJson(r?['tasks']);
}

/// One task row: the round checkbox (the completer's avatar when done) and
/// the words. Shared by the card in the chat and the full sheet.
class TaskRow extends StatelessWidget {
  const TaskRow({super.key, required this.item, required this.onTap, this.detail = false});
  final TaskItem item;
  final VoidCallback onTap;

  /// The sheet also says who and when, under the words.
  final bool detail;

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    final dur = reduced ? Duration.zero : Motion.short;
    final who = item.doneByName.split(' ').first;
    return Semantics(
      checked: item.done,
      label: item.text,
      hint: item.done ? 'Done by $who. Tap to reopen.' : 'Tap to mark done.',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AnimatedContainer(
              duration: dur,
              curve: Motion.easeMove,
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: item.done ? Neon.success.withValues(alpha: 0.18) : Colors.transparent,
                border: Border.all(
                    color: item.done ? Neon.success : Neon.textDim, width: item.done ? 2 : 1.6),
              ),
              child: AnimatedSwitcher(
                duration: dur,
                transitionBuilder: (c, a) => ScaleTransition(
                    scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack), child: c),
                child: item.done
                    ? ChatAvatar(key: ValueKey(item.doneBy), name: who, radius: 10)
                    : const SizedBox.shrink(key: ValueKey('open')),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AnimatedDefaultTextStyle(
                  duration: dur,
                  style: TextStyle(
                    color: item.done ? Neon.textLo : Neon.textHi,
                    fontSize: 14.5,
                    height: 1.3,
                    decoration: item.done ? TextDecoration.lineThrough : TextDecoration.none,
                    decorationColor: Neon.textLo,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(item.text),
                  ),
                ),
                if (detail && item.done)
                  Text(
                    'Done by $who${item.doneAt > 0 ? ' · ${ChatBubble.clock(item.doneAt)}' : ''}',
                    style: TextStyle(color: Neon.successInk, fontSize: NeonType.caption),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Ticks [item] optimistically, then takes the server's list. [show] is
/// called with the new list (or the old one again if it failed).
Future<void> tapTask(BuildContext context, int groupId, TaskList list, TaskItem item,
    void Function(TaskList) show) async {
  HapticFeedback.selectionClick();
  final me = AuthService.instance.user;
  final want = !item.done;
  show(list.withItem(TaskItem(item.id, item.text, want ? (me?.id ?? -1) : null,
      want ? (me?.name ?? 'You') : '', want ? DateTime.now().millisecondsSinceEpoch : 0)));
  final fresh = await setTask(groupId, list.id, item.id, want);
  if (fresh != null) {
    show(fresh);
  } else {
    show(list);
    if (context.mounted) {
      AppFeedback.show("Couldn't update that task. Please try again.",
          context: context, tone: FeedbackTone.error);
    }
  }
}

/// The list as it sits in the chat: title, progress, and up to [_inline]
/// tasks; the rest (and who did what, when) in the sheet.
class TaskListCard extends StatefulWidget {
  const TaskListCard({
    super.key,
    required this.groupId,
    required this.list,
    this.sender = '',
    this.at = 0,
    this.mine = false,
    this.onLongPress,
  });
  final int groupId;
  final bool mine;
  final TaskList list;
  final String sender;
  final int at;
  final VoidCallback? onLongPress;

  @override
  State<TaskListCard> createState() => _TaskListCardState();
}

class _TaskListCardState extends State<TaskListCard> {
  static const _inline = 5;
  late TaskList _list = widget.list;

  @override
  void didUpdateWidget(TaskListCard old) {
    super.didUpdateWidget(old);
    if (!identical(old.list, widget.list)) _list = widget.list;
  }

  void _show(TaskList l) {
    if (mounted) setState(() => _list = l);
  }

  Future<void> _open() async {
    final l = await showModalBottomSheet<TaskList>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => TaskListSheet(groupId: widget.groupId, list: _list),
    );
    if (l != null) _show(l);
  }

  @override
  Widget build(BuildContext context) {
    final l = _list;
    final total = l.items.length;
    final done = l.doneCount;
    final more = total - _inline;
    return Align(
      alignment: widget.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
        child: GestureDetector(
          onLongPress: widget.onLongPress,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            decoration: BoxDecoration(
              color: Neon.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Neon.lineBright),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                InkWell(
                  onTap: _open,
                  borderRadius: BorderRadius.circular(10),
                  child: Row(children: [
                    Icon(Icons.checklist_rounded, size: 18, color: Neon.cyanInk),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l.title.isNotEmpty ? l.title : 'Task list',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.spaceGrotesk(
                            color: Neon.textHi, fontWeight: FontWeight.w700, fontSize: 15),
                      ),
                    ),
                    Text('$done/$total',
                        style: TextStyle(
                            color: done == total ? Neon.successInk : Neon.textLo,
                            fontWeight: FontWeight.w700,
                            fontSize: NeonType.caption)),
                    Icon(Icons.chevron_right_rounded, size: 18, color: Neon.textDim),
                  ]),
                ),
                if (widget.sender.isNotEmpty)
                  Text('From ${widget.sender.split(' ').first}',
                      style: TextStyle(color: Neon.textLo, fontSize: NeonType.caption)),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: total == 0 ? 0 : done / total),
                    duration: Motion.reduced(context) ? Duration.zero : Motion.pageIn,
                    builder: (_, v, __) => LinearProgressIndicator(
                      value: v,
                      minHeight: 4,
                      backgroundColor: Neon.line,
                      color: Neon.success,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                for (final i in l.items.take(_inline))
                  TaskRow(item: i, onTap: () => tapTask(context, widget.groupId, l, i, _show)),
                Row(children: [
                  if (more > 0)
                    TextButton(
                      onPressed: _open,
                      style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          minimumSize: const Size(0, 32)),
                      child: Text('+$more more',
                          style: TextStyle(color: Neon.violet, fontWeight: FontWeight.w700)),
                    ),
                  const Spacer(),
                  if (widget.at > 0)
                    Text(ChatBubble.clock(widget.at),
                        style: TextStyle(color: Neon.textDim, fontSize: 11)),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// The whole list: every task, who did it and when. Refetched on open so
/// it is current; returns the latest list to the card when closed.
class TaskListSheet extends StatefulWidget {
  const TaskListSheet({super.key, required this.groupId, required this.list});
  final int groupId;
  final TaskList list;

  @override
  State<TaskListSheet> createState() => _TaskListSheetState();
}

class _TaskListSheetState extends State<TaskListSheet> {
  late TaskList _list = widget.list;

  @override
  void initState() {
    super.initState();
    ApiService.getJson('/chat/groups/${widget.groupId}/tasks/${widget.list.id}').then((r) {
      final l = TaskList.fromJson(r?['tasks']);
      if (l != null && mounted) setState(() => _list = l);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = _list;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (did, _) {
        if (!did) Navigator.of(context).pop(_list);
      },
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            children: [
              Text(l.title.isNotEmpty ? l.title : 'Task list',
                  style: GoogleFonts.spaceGrotesk(
                      color: Neon.textHi, fontWeight: FontWeight.w700, fontSize: 20)),
              const SizedBox(height: 2),
              Text('${l.doneCount} of ${l.items.length} done · anyone in the group can tick or reopen',
                  style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote)),
              const SizedBox(height: 12),
              for (final i in l.items)
                TaskRow(
                  item: i,
                  detail: true,
                  onTap: () => tapTask(context, widget.groupId, l, i,
                      (n) => mounted ? setState(() => _list = n) : null),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// New list: an optional title and one task per line. Returns true when
/// it was shared.
class NewTaskListSheet extends StatefulWidget {
  const NewTaskListSheet({super.key, required this.groupId});
  final int groupId;

  @override
  State<NewTaskListSheet> createState() => _NewTaskListSheetState();
}

class _NewTaskListSheetState extends State<NewTaskListSheet> {
  final _title = TextEditingController();
  final _tasks = [TextEditingController()];
  final _focus = [FocusNode()];
  bool _sending = false;

  @override
  void dispose() {
    _title.dispose();
    for (final c in _tasks) {
      c.dispose();
    }
    for (final f in _focus) {
      f.dispose();
    }
    super.dispose();
  }

  void _add() {
    if (_tasks.length >= 30) return;
    setState(() {
      _tasks.add(TextEditingController());
      _focus.add(FocusNode());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.last.requestFocus());
  }

  void _remove(int i) {
    if (_tasks.length == 1) {
      _tasks.first.clear();
      return;
    }
    setState(() {
      _tasks.removeAt(i).dispose();
      _focus.removeAt(i).dispose();
    });
  }

  Future<void> _share() async {
    final items = [for (final c in _tasks) if (c.text.trim().isNotEmpty) c.text.trim()];
    if (items.isEmpty || _sending) return;
    setState(() => _sending = true);
    HapticFeedback.lightImpact();
    final r = await ApiService.postJson(
        '/chat/groups/${widget.groupId}/tasks', {'title': _title.text.trim(), 'items': items});
    if (!mounted) return;
    if (r == null) {
      setState(() => _sending = false);
      AppFeedback.show("Couldn't share the list. Please try again.",
          context: context, tone: FeedbackTone.error);
      return;
    }
    Navigator.of(context).pop(true);
  }

  InputDecoration _bare(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Neon.textDim),
        filled: false,
        isDense: true,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
      );

  @override
  Widget build(BuildContext context) {
    final ready = _tasks.any((c) => c.text.trim().isNotEmpty);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            children: [
              Text('New task list',
                  style: GoogleFonts.spaceGrotesk(
                      color: Neon.textHi, fontWeight: FontWeight.w700, fontSize: 20)),
              TextField(
                controller: _title,
                textCapitalization: TextCapitalization.sentences,
                style: TextStyle(color: Neon.textHi, fontSize: 16, fontWeight: FontWeight.w600),
                decoration: _bare('Title (optional)'),
              ),
              Divider(height: 1, color: Neon.line),
              for (var i = 0; i < _tasks.length; i++)
                Row(children: [
                  Icon(Icons.radio_button_unchecked_rounded, size: 20, color: Neon.textDim),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _tasks[i],
                      focusNode: _focus[i],
                      autofocus: i == 0,
                      maxLength: 200,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => i == _tasks.length - 1 ? _add() : _focus[i + 1].requestFocus(),
                      style: TextStyle(color: Neon.textHi, fontSize: 15),
                      decoration: _bare('Task ${i + 1}').copyWith(counterText: ''),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove task',
                    onPressed: () => _remove(i),
                    icon: Icon(Icons.close_rounded, size: 18, color: Neon.textDim),
                  ),
                ]),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _tasks.length >= 30 ? null : _add,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add task'),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: ready && !_sending ? _share : null,
                style: FilledButton.styleFrom(
                  backgroundColor: Neon.accentFill,
                  foregroundColor: Neon.onAccent,
                  minimumSize: const Size.fromHeight(48),
                  shape: const StadiumBorder(),
                ),
                child: Text(_sending ? 'Sharing…' : 'Share with the group'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
