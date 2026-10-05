import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/log.dart';
import '../../design/motion.dart';
import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart';
import '../../models/brief.dart';
import '../../models/news_item.dart';
import '../../screens/calendar_screen.dart';
import '../../screens/finance_screen.dart';
import '../../screens/news_screen.dart';
import '../../screens/news_story_screen.dart';
import '../../screens/reminders_screen.dart';
import '../../services/app_feedback.dart';
import '../../services/auth_service.dart';
import '../../services/brief_service.dart';
import '../../services/call_history.dart';
import '../../services/missed_calls_service.dart';
import '../../widgets/neon_cards.dart';
import '../../widgets/whats_new_card.dart';
import '../assistant/state/assistant_engine.dart';
import '../briefing/brief_player.dart';
import '../meeting_prep/meeting_prep_sheet.dart';
import '../shopping/shopping_list_screen.dart';
import '../shopping/shopping_service.dart';
import 'home_extras.dart';
import 'weather_card.dart';
import 'weather_forecast.dart';
import 'home_feed.dart';
import 'home_memory.dart';

/// A button's background work failed: logged, and said in a toast (there is
/// no screen context down here).
void _said(String what, Object e) {
  AppLog.add('home', '$what -> $e');
  AppFeedback.show(what, tone: FeedbackTone.error);
}

/// What Home's buttons do. The real ones by default; tests hand in their
/// own, so a widget test never reaches the network, the dialer or the mic.
class HomeActions {
  const HomeActions();

  Future<bool> completeReminder(AgendaItem a) =>
      BriefService.instance.completeReminder(a);
  Future<bool> moveReminder(AgendaItem a, DateTime to) =>
      BriefService.instance.moveReminder(a, to);
  Future<bool> completePromise(PromiseItem p) =>
      BriefService.instance.completePromise(p);

  /// The owner's tap is the go-ahead: it dials straight away (the Missed
  /// calls card always worked this way).
  void callBack(CallEntry c) => unawaited(AssistantEngine.instance
      .callBackMissed(c)
      .catchError((Object e) => _said("Couldn't start the call.", e)));
  void dropCall(CallEntry c) => MissedCallsService.instance.remove(c);

  /// The assistant says them, which marks them read; the refresh then
  /// takes the card away.
  Future<void> hearMessages() async {
    await AssistantEngine.instance.announceIncomingMessages();
    await BriefService.instance.refresh(force: true);
  }

  /// A request handed to the assistant, answered out loud — sending,
  /// calling or paying still asks for a yes, as any spoken request does.
  void ask(String request) => unawaited(AssistantEngine.instance
      .askAssistant(request)
      .catchError((Object e) => _said("Couldn't ask that.", e)));
  void talk() => unawaited(AssistantEngine.instance
      .beginInlineConversation(name: AuthService.instance.user?.name)
      .catchError((Object e) => _said("Couldn't start the chat.", e)));
  void hide(HomeCard c) => unawaited(HomeMemory.instance.hide(c.id));
  void open(BuildContext context, Widget page) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => page));

  /// "Play my morning" (2026-09-30): the day read aloud, its strip in the
  /// root overlay. A second tap pauses or resumes.
  void playBrief(BuildContext context) {
    final p = BriefPlayer.instance;
    if (p.state == BriefPlayState.playing || p.state == BriefPlayState.paused) {
      p.toggle();
      return;
    }
    unawaited(p.play(overlay: Overlay.maybeOf(context, rootOverlay: true)));
  }

  /// The meeting card's Prepare (2026-09-30): Meeting Prep for exactly
  /// that event.
  Future<void> prepareMeeting(BuildContext context, AgendaItem item) =>
      showMeetingPrep(context, meetingId: item.eventId);

  /// Where the spoken brief is (the Play button follows it).
  BriefPlayer get brief => BriefPlayer.instance;
}

/// ─────────────────────────────────────────────────────────────────────────
///  HOME'S FEED (2026-09-29): the Now card, up to two Also cards, three
///  lines of the day with the way into the calendar, and quick actions —
///  under the greeting ([leading]) and over the mic. Which cards, and why:
///  home_feed.dart. Loading shows the shape of the feed; offline shows the
///  saved day and says how old it is; nothing to do says so, calmly.
/// ─────────────────────────────────────────────────────────────────────────
class HomeFeedView extends StatefulWidget {
  const HomeFeedView({
    super.key,
    required this.leading,
    required this.padding,
    this.actions = const HomeActions(),
    this.clock = DateTime.now,
  });

  /// Scrolls as the first item: the greeting, the date and the weather.
  final Widget leading;
  final EdgeInsets padding;
  final HomeActions actions;

  /// Test seam for "in 25 min".
  final DateTime Function() clock;

  @override
  State<HomeFeedView> createState() => _HomeFeedViewState();
}

class _HomeFeedViewState extends State<HomeFeedView> {
  /// Cards whose button is waiting on the server.
  final _busy = <String>{};

  /// "In 25 min" stays true: the feed is worked out again every minute.
  Timer? _tick;

  HomeActions get _do => widget.actions;

  @override
  void initState() {
    super.initState();
    unawaited(HomeMemory.instance.load());
    unawaited(HomeNews.instance.load());
    unawaited(WeatherForecastService.instance.load());
    ShoppingService.instance.ensureLoaded();
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      // The saved headlines are refreshed in the background (News warms
      // them at launch and on return); pick them up.
      unawaited(HomeNews.instance.load());
      unawaited(WeatherForecastService.instance.refreshIfStale());
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final memory = HomeMemory.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([
        BriefService.instance,
        MissedCallsService.instance.pending,
        memory,
        HomeNews.instance,
        ShoppingService.instance,
        WeatherForecastService.instance,
        _do.brief,
      ]),
      builder: (context, _) {
        final svc = BriefService.instance;
        final now = widget.clock();
        final missed = MissedCallsService.instance.pending.value;
        final feed = HomeRanker.rank(
          brief: svc.brief,
          now: now,
          missed: missed,
          hidden: memory.hiddenAt(now),
          newUser: svc.loaded && memory.isNew(now),
        );
        // Not loaded and it failed: the error, unless missed calls still
        // make a feed worth showing (with a line saying the rest is not
        // there). Never "all clear" about a day that did not load.
        final state = svc.loaded
            ? 'loaded'
            : !svc.failed
                ? 'loading'
                : missed.isEmpty
                    ? 'failed'
                    : 'partial';
        // ALWAYS USEFUL: under what is personal, the context and discovery
        // cards that fit (home_extras.dart) — also when the day could not
        // load: the saved headlines and a tip need no connection.
        final personal = state == 'failed'
            ? 1 // the error card takes the Now card's place
            : (feed.now != null ? 1 : 0) + feed.also.length;
        final toBuy = [
          for (final i in ShoppingService.instance.items)
            if (!i.checked) i.name,
        ];
        // THE WEATHER CARD (2026-09-30): the week's sky in place of the
        // one-line rain row; it takes one of the context slots.
        final wx = state == 'loading' ? null : WeatherForecastService.instance.forecast;
        final extras = state == 'loading'
            ? const <HomeExtra>[]
            : HomeExtras.pick(
                room: math.max(
                    0,
                    HomeExtras.room(personal: personal, hasDay: feed.day.isNotEmpty) -
                        (wx != null ? 1 : 0)),
                now: now,
                weather: wx == null ? svc.brief.weatherNote : null,
                toBuy: toBuy.length,
                toBuyNames: toBuy.take(3).toList(),
                news: HomeNews.instance.itemsWith(svc.brief.headlines),
                newsOn: memory.newsOn.value,
                hidden: memory.hiddenAt(now),
              );
        return ListView(
          padding: widget.padding,
          children: [
            // Kept alive: scrolled away and back, it must not replay its
            // entrance.
            _KeepAlive(child: widget.leading),
            const SizedBox(height: 16),
            // PLAY MY MORNING (2026-09-30): the day, read aloud — the
            // brightest thing under the greeting.
            _playRow(now),
            const SizedBox(height: 20),
            StateSwitch(
              state: state,
              child: switch (state) {
                'failed' => NeonErrorState(
                    message: "Couldn't load your day",
                    onRetry: () => svc.refresh(force: true),
                  ),
                'loading' => const _Skeleton(),
                _ => _body(feed),
              },
            ),
            if (state == 'partial' || (state == 'loaded' && svc.stale))
              _status(svc),
            if (wx != null) ...[
              const SizedBox(height: 24),
              Reveal(
                delayMs: 120,
                child: WeatherCard(forecast: wx, clock: widget.clock),
              ),
            ],
            if (extras.isNotEmpty) ...[
              const SizedBox(height: 24),
              Reveal(
                delayMs: 140,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final e in extras)
                      KeyedSubtree(key: ValueKey(e.id), child: _extra(e, svc.brief)),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            // A chip that says what today's tip card says is dropped.
            Reveal(
              delayMs: 160,
              child: _asks([
                for (final a in feed.asks)
                  if (!extras.any((e) => e.tip != null && (e.tip!.ask == a.request || e.tip!.say == a.label)))
                    a,
              ]),
            ),
            const SizedBox(height: 8),
            Reveal(
              delayMs: 180,
              child: _toolShortcuts(),
            ),
            const SizedBox(height: 20),
            // Once per release: what just got better. Below the day, never
            // above what needs the user.
            const WhatsNewCard(),
          ],
        );
      },
    );
  }

  // ── play my morning ──────────────────────────────────────────────────

  /// The Play button: "Play my morning" before noon, "Play my day" after;
  /// while it plays, the same button pauses and resumes it.
  Widget _playRow(DateTime now) {
    final p = _do.brief;
    final morning = now.hour < 12;
    final (label, icon, hint) = switch (p.state) {
      BriefPlayState.loading => (
          morning ? 'Getting your morning…' : 'Getting your day…',
          Icons.play_arrow_rounded,
          'This takes a few seconds',
        ),
      BriefPlayState.playing => ('Pause', Icons.pause_rounded, 'Playing now'),
      BriefPlayState.paused => ('Resume', Icons.play_arrow_rounded, 'Paused'),
      _ => (
          morning ? 'Play my morning' : 'Play my day',
          Icons.play_arrow_rounded,
          'Hear your day in about a minute',
        ),
    };
    return Row(
      children: [
        // A glass pill with the brand's disc: the colour in one small
        // place (2026-09-30, premium pass — no halo of its own).
        GlassButton(
          label: label,
          icon: icon,
          busy: p.state == BriefPlayState.loading,
          onPressed: () => _do.playBrief(context),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ExcludeSemantics(
            child: Text(
              hint,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Neon.textDim, fontSize: NeonType.footnote, height: 1.3),
            ),
          ),
        ),
      ],
    );
  }

  // ── the feed ─────────────────────────────────────────────────────────

  Widget _body(HomeFeed feed) {
    final now = feed.now;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // A new Now card replaces the last one: it fades and rises in.
        Reveal(
          delayMs: 40,
          child: StateSwitch(
            state: now?.id ?? 'clear',
            child: now == null
                ? _AllClear(later: feed.day.isNotEmpty)
                : _nowCard(now),
          ),
        ),
        // Rows leaving or arriving: the space opens and closes, it does
        // not jump.
        AnimatedSize(
          duration: Motion.short,
          curve: Motion.easeMove,
          alignment: Alignment.topCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (feed.also.isNotEmpty) const SizedBox(height: 12),
              for (final c in feed.also)
                KeyedSubtree(key: ValueKey(c.id), child: _alsoRow(c)),
            ],
          ),
        ),
        if (feed.day.isNotEmpty) ...[
          const SizedBox(height: 24),
          Reveal(delayMs: 100, child: _day(feed)),
        ],
      ],
    );
  }

  Widget _nowCard(HomeCard c) {
    final (primary, secondary) = _buttons(c);
    final busy = _busy.contains(c.id);
    final open = _pageFor(c);
    return Semantics(
      container: true,
      label: _spoken(c),
      child: _Tap(
        onTap: open == null ? null : () => _do.open(context, open),
        // The one lit card on Home: its kind's light, softly.
        child: GlassCard(
          glow: _look(c.kind).$2,
          padding: const EdgeInsets.fromLTRB(Neon.s5, Neon.s5, Neon.s5, Neon.s3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _tile(c.kind, 36),
                        const SizedBox(width: Neon.s3),
                        Text(_kindName(c.kind),
                            style: NeonType.eyebrow.copyWith(color: Neon.textLo)),
                        const Spacer(),
                        Flexible(flex: 3, child: _pill(c.reason)),
                      ],
                    ),
                    const SizedBox(height: Neon.s4),
                    Text(
                      c.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: NeonType.glassTitle.copyWith(color: Neon.textHi),
                    ),
                    if (c.detail != null) ...[
                      const SizedBox(height: Neon.s1),
                      Text(
                        c.detail!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Neon.textLo,
                            fontSize: NeonType.body,
                            height: 1.3),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: Neon.s3),
              Wrap(
                spacing: Neon.s2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (primary != null) _primary(c.id, primary, busy),
                  if (secondary != null) _secondary(c.id, secondary, busy),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _alsoRow(HomeCard c) {
    final (primary, secondary) = _buttons(c);
    final act = primary ?? secondary;
    final busy = _busy.contains(c.id);
    final open = _pageFor(c);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        container: true,
        label: _spoken(c),
        child: _Tap(
          onTap: open == null ? null : () => _do.open(context, open),
          child: GlassCard(
            minHeight: 68,
            padding: const EdgeInsets.fromLTRB(Neon.s3, Neon.s2 + 2, Neon.s1, Neon.s2 + 2),
            child: Row(
              children: [
                ExcludeSemantics(child: _tile(c.kind, 40)),
                const SizedBox(width: Neon.s3),
                Expanded(
                  child: ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NeonType.manrope(NeonType.body, FontWeight.w600)
                              .copyWith(color: Neon.textHi),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [c.reason, if (c.detail != null) c.detail!].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Neon.textLo, fontSize: NeonType.footnote,
                              fontFeatures: NeonType.figures),
                        ),
                      ],
                    ),
                  ),
                ),
                if (act != null) _compact(c.id, act, busy, tone: _toneOf(c.kind)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _day(HomeFeed feed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Padding(
                  padding: const EdgeInsets.only(left: Neon.s1),
                  child: Text(feed.dayLabel,
                      style: NeonType.eyebrow.copyWith(color: Neon.textLo)),
                ),
              ),
            ),
            // The month moved to its own page (Hub → Calendar): the word
            // flies into that page's title, as a Hub row's does.
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Neon.violet,
                minimumSize: const Size(48, 48),
              ),
              onPressed: () => _do.open(context, const CalendarScreen()),
              child: Hero(
                tag: titleHeroTag('Calendar'),
                flightShuttleBuilder: titleFlight,
                child: Text('Calendar',
                    style: NeonType.manrope(NeonType.footnote, FontWeight.w700)
                        .copyWith(color: Neon.violet)),
              ),
            ),
          ],
        ),
        // A grouped glass list: time, title, the kind; hairlines between.
        GlassGroup(
          indent: Neon.s4,
          children: [for (final l in feed.day) _line(l)],
        ),
      ],
    );
  }

  Widget _line(HomeLine l) {
    final page = l.item.kind == 'reminder'
        ? const RemindersScreen()
        : const CalendarScreen();
    return Semantics(
      button: true,
      label: '${l.time}, ${l.item.title}',
      excludeSemantics: true,
      child: InkWell(
        onTap: () => _do.open(context, page),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Neon.s4),
            child: Row(
              children: [
                SizedBox(
                  width: 76,
                  child: Text(
                    l.time,
                    style: NeonType.manrope(NeonType.body, FontWeight.w600).copyWith(
                      color: Neon.textLo,
                      fontFeatures: NeonType.figures,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    l.item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NeonType.manrope(NeonType.callout, FontWeight.w600)
                        .copyWith(color: Neon.textHi),
                  ),
                ),
                const SizedBox(width: Neon.s3),
                Icon(
                  l.item.kind == 'reminder'
                      ? Icons.notifications_none_rounded
                      : Icons.event_outlined,
                  size: 18,
                  color: Neon.textDim,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The quick actions: requests handed to the assistant. 48 dp to the
  /// finger, 34 to the eye; not clipped at the page edge (a sliced chip
  /// read as a fault, not as "scroll for more").
  Widget _asks(List<HomeAsk> asks) {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        clipBehavior: Clip.none,
        scrollDirection: Axis.horizontal,
        itemCount: asks.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) => PressScale(
          child: NeonPill(
            label: asks[i].label,
            icon: Icons.graphic_eq_rounded,
            tone: i.isEven ? NeonTone.tip : NeonTone.discovery,
            inkOverride: Neon.textHi,
            quiet: true,
            onPressed: () {
              HapticFeedback.selectionClick();
              _do.ask(asks[i].request);
            },
          ),
        ),
      ),
    );
  }

  /// Direct routes to common tools. Unlike the suggestion chips above,
  /// these open the feature immediately and never send a model request.
  Widget _toolShortcuts() {
    final shortcuts = <(String, IconData, NeonTone, Widget)>[
      ('Calendar', Icons.calendar_month_rounded, NeonTone.info,
          const CalendarScreen()),
      ('Reminders', Icons.notifications_active_rounded, NeonTone.action,
          const RemindersScreen()),
      ('Shopping', Icons.shopping_basket_rounded, NeonTone.discovery,
          const ShoppingListScreen()),
      ('Finance', Icons.account_balance_wallet_rounded, NeonTone.tip,
          const FinanceScreen()),
      ('News', Icons.newspaper_rounded, NeonTone.info, const NewsScreen()),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(
            'Open a tool',
            style: NeonType.eyebrow.copyWith(color: Neon.textLo),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final shortcut in shortcuts)
              NeonPill(
                label: shortcut.$1,
                icon: shortcut.$2,
                tone: shortcut.$3,
                inkOverride: Neon.textHi,
                quiet: true,
                onPressed: () => _do.open(context, shortcut.$4),
              ),
          ],
        ),
      ],
    );
  }

  Widget _status(BriefService svc) {
    final at = svc.updatedAt;
    final text = !svc.loaded
        ? "Couldn't load your day."
        : at == null
            ? 'Offline · showing your last saved day'
            : 'Offline · updated ${CallHistory.clock(at)}';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(Icons.cloud_off_rounded, size: 16, color: Neon.textLo),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote)),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Neon.violet,
              minimumSize: const Size(48, 48),
            ),
            onPressed: () => svc.refresh(force: true),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }

  // ── always useful: context and discovery ─────────────────────────────

  Widget _extra(HomeExtra e, TodayBrief b) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: switch (e.kind) {
          HomeExtraKind.weather => _weather(e.weather!, b),
          HomeExtraKind.shopping => _shopping(e),
          HomeExtraKind.news => _news(e.news),
          HomeExtraKind.tip => _tip(e),
        },
      );

  /// A context row: the Also card's shape, with what it is as the second
  /// line.
  Widget _contextRow({
    required String id,
    required NeonTone tone,
    required IconData icon,
    required Color tint,
    required String title,
    required String subtitle,
    _Act? act,
    VoidCallback? onTap,
  }) {
    final busy = _busy.contains(id);
    return Semantics(
      container: true,
      label: '$subtitle: $title',
      child: _Tap(
        onTap: onTap,
        child: GlassCard(
          minHeight: 68,
          padding: const EdgeInsets.fromLTRB(Neon.s3, Neon.s2 + 2, Neon.s1, Neon.s2 + 2),
          child: Row(
            children: [
              ExcludeSemantics(child: _iconTile(icon, tint, 40)),
              const SizedBox(width: Neon.s3),
              Expanded(
                child: ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: NeonType.manrope(NeonType.body, FontWeight.w600)
                              .copyWith(color: Neon.textHi)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Neon.textLo, fontSize: NeonType.footnote)),
                    ],
                  ),
                ),
              ),
              if (act != null) _compact(id, act, busy, tone: tone) else const SizedBox(width: Neon.s3),
            ],
          ),
        ),
      ),
    );
  }

  Widget _weather(WeatherNote w, TodayBrief b) {
    final (icon, tint) = switch (w.kind) {
      'rain' => (Icons.umbrella_rounded, Neon.accentC),
      'heat' => (Icons.thermostat_rounded, Neon.accentD),
      _ => (Icons.wb_sunny_rounded, Neon.accentD),
    };
    final from = w.from;
    return _contextRow(
      id: 'weather',
      tone: NeonTone.info,
      icon: icon,
      tint: tint,
      title: w.text,
      subtitle: 'Weather',
      // Rain on its way is worth a reminder; heat and sun are just told.
      act: w.kind == 'rain' && from != null
          ? _Act('Remind me', Icons.alarm_add_rounded, () async {
              _do.ask('Remind me to take an umbrella half an hour before '
                  '${_hour(from)} today.');
              return true;
            })
          : null,
    );
  }

  Widget _shopping(HomeExtra e) => _contextRow(
        id: 'shopping',
        tone: NeonTone.action,
        icon: Icons.shopping_basket_rounded,
        tint: Neon.accentE,
        title: e.toBuy == 1 ? '1 thing to buy' : '${e.toBuy} things to buy',
        subtitle: 'Shopping list · ${e.toBuyNames.join(', ')}',
        onTap: () => _do.open(context, const ShoppingListScreen()),
        act: _Act('Open', Icons.chevron_right_rounded, () async {
          _do.open(context, const ShoppingListScreen());
          return true;
        }),
      );

  /// Two headlines, marked as the news they are — not the assistant's own
  /// words — with where they come from. A tap reads the story; the ✕
  /// takes news off Home (You → Home puts it back).
  Widget _news(List<NewsItem> items) {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(Neon.s4, Neon.s1, Neon.s1, Neon.s1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.newspaper_rounded, size: 16, color: Neon.textLo),
              const SizedBox(width: 8),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text('In the news',
                      style: NeonType.eyebrow.copyWith(color: Neon.textLo)),
                ),
              ),
              IconButton(
                tooltip: 'Hide news on Home',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _hideNews,
                icon: Icon(Icons.close_rounded, size: 18, color: Neon.textLo),
              ),
            ],
          ),
          for (final n in items)
            Semantics(
              button: true,
              label: '${n.title}. From ${n.source}',
              excludeSemantics: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(Neon.rSm),
                onTap: () => _do.open(context, NewsStoryScreen(item: n)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 6, 10, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(n.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: NeonType.manrope(NeonType.body, FontWeight.w600)
                              .copyWith(color: Neon.textHi, height: 1.3)),
                      const SizedBox(height: 2),
                      Text(
                        [if (n.source.isNotEmpty) n.source, if (n.age.isNotEmpty) n.age]
                            .join(' · '),
                        style: TextStyle(
                            color: Neon.textLo, fontSize: NeonType.footnote),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Neon.violet,
                minimumSize: const Size(48, 48),
                textStyle: NeonType.manrope(NeonType.footnote, FontWeight.w700),
              ),
              onPressed: () => _do.open(context, const NewsScreen()),
              child: const Text('More news'),
            ),
          ),
        ],
      ),
    );
  }

  void _hideNews() {
    HapticFeedback.selectionClick();
    unawaited(HomeMemory.instance.setNewsOn(false));
    unawaited(AppFeedback.showUndo(context, 'News hidden from Home',
        onUndo: () => unawaited(HomeMemory.instance.setNewsOn(true))));
  }

  /// One real thing to try: a question runs with a tap; an action opens
  /// the mic for the user's own words.
  Widget _tip(HomeExtra e) {
    final t = e.tip!;
    final busy = _busy.contains(e.id);
    final ask = t.ask;
    final primary = ask != null
        ? _Act('Try it', Icons.graphic_eq_rounded, () async {
            _do.ask(ask);
            return true;
          })
        : _Act('Talk to me', Icons.mic_rounded, () async {
            _do.talk();
            return true;
          });
    final later = _Act('Not now', null, () async {
      unawaited(HomeMemory.instance.hide(e.id));
      return true;
    });
    return Semantics(
      container: true,
      label: 'Try asking: ${t.say}. ${t.why}',
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(Neon.s4, Neon.s4, Neon.s2, Neon.s1 + 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.auto_awesome_rounded, size: 16, color: Neon.violet),
                      const SizedBox(width: 8),
                      Text('Try asking',
                          style: NeonType.eyebrow.copyWith(color: Neon.textLo)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('“${t.say}”',
                      style: NeonType.manrope(NeonType.rowTitle, FontWeight.w600)
                          .copyWith(color: Neon.textHi)),
                  const SizedBox(height: 2),
                  Text(t.why,
                      style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote)),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _compact(e.id, primary, busy, tone: NeonTone.tip),
                _secondary(e.id, later, busy),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// "5 pm" from "17:00".
  static String _hour(String hhmm) {
    final n = (int.tryParse(hhmm.split(':').first) ?? 0) % 24;
    return '${n % 12 == 0 ? 12 : n % 12} ${n < 12 ? 'am' : 'pm'}';
  }

  /// A quiet tonal tile (premium pass): the kind in its colour, softly.
  static Widget _iconTile(IconData icon, Color tint, double size) =>
      GlassTile(icon, tint, size: size);

  // ── buttons ──────────────────────────────────────────────────────────

  (_Act?, _Act?) _buttons(HomeCard c) {
    final notNow = _Act('Not now', null, () async {
      _do.hide(c);
      return true;
    });
    switch (c.kind) {
      case HomeCardKind.meeting:
        // PREPARE (2026-09-30): Meeting Prep for this event — who is in
        // it, last time, promises, talking points — instead of a spoken
        // question.
        return (
          _Act('Prepare', Icons.groups_rounded, () async {
            unawaited(_do
                .prepareMeeting(context, c.item!)
                .catchError((Object e) => _said("Couldn't open that.", e)));
            return true;
          }),
          notNow,
        );
      case HomeCardKind.reminder:
        // Without an id there is nothing on the server to change.
        if (c.item?.id == null) return (null, notNow);
        return (
          _Act('Done', Icons.check_rounded, () => _done(c)),
          _Act('Later', Icons.schedule_rounded, () => _later(c)),
        );
      case HomeCardKind.promise:
        return (_Act('Done', Icons.check_rounded, () => _done(c)), notNow);
      case HomeCardKind.missedCall:
        final call = c.call!;
        return (
          call.dialable.isEmpty
              ? null
              : _Act('Call back', Icons.call_rounded, () async {
                  _do.callBack(call);
                  return true;
                }),
          _Act('Not now', null, () async {
            _do.dropCall(call);
            return true;
          }),
        );
      case HomeCardKind.message:
        return (
          _Act('Hear it', Icons.volume_up_rounded, () async {
            await _do.hearMessages();
            return true;
          }),
          notNow,
        );
      case HomeCardKind.birthday:
        final who = c.person ?? c.title;
        return (
          _Act('Send wishes', Icons.celebration_rounded, () async {
            _do.ask('Help me wish $who: it is ${c.title} '
                '${c.reason.toLowerCase()}. Draft a warm message and ask me '
                'before sending it.');
            return true;
          }),
          notNow,
        );
      case HomeCardKind.payment:
        return (
          _Act('Open Finance', Icons.account_balance_wallet_rounded, () async {
            _do.open(context, const FinanceScreen());
            return true;
          }),
          notNow,
        );
      case HomeCardKind.getStarted:
        return (
          _Act('Talk to me', Icons.mic_rounded, () async {
            _do.talk();
            return true;
          }),
          notNow,
        );
    }
  }

  Future<bool> _done(HomeCard c) async {
    final ok = c.promise != null
        ? await _do.completePromise(c.promise!)
        : await _do.completeReminder(c.item!);
    if (!ok) _failed("Couldn't mark it done.", () => _run(c.id, () => _done(c)));
    return ok;
  }

  /// An hour after it was due (or from now, if that has passed), on the
  /// next five minutes.
  Future<bool> _later(HomeCard c) async {
    final now = widget.clock();
    final from = c.at != null && c.at!.isAfter(now) ? c.at! : now;
    final raw = from.add(const Duration(hours: 1));
    final to = DateTime(raw.year, raw.month, raw.day, raw.hour,
        (raw.minute / 5).ceil() * 5);
    final ok = await _do.moveReminder(c.item!, to);
    if (!mounted) return ok;
    if (ok) {
      AppFeedback.show('Moved to ${CallHistory.clock(to)}',
          context: context, tone: FeedbackTone.success);
    } else {
      _failed("Couldn't move it.", () => _run(c.id, () => _later(c)));
    }
    return ok;
  }

  void _failed(String what, VoidCallback retry) {
    if (!mounted) return;
    AppFeedback.showRetry('$what Check your connection.',
        context: context, onRetry: retry);
  }

  /// Runs a button. Only one request per card at a time; the button shows
  /// it is working until the server answers.
  Future<void> _run(String id, Future<bool> Function() act) async {
    if (_busy.contains(id)) return;
    // The touch is answered now (owner, 2026-09-30: "buttons are laggy"):
    // the tick and the card's change come first, the server after.
    HapticFeedback.lightImpact();
    setState(() => _busy.add(id));
    try {
      await act();
    } catch (e) {
      AppLog.add('home', 'button on $id failed: $e');
      _failed("That didn't work.", () => _run(id, act));
    }
    if (!mounted) return;
    setState(() => _busy.remove(id));
  }

  Widget _primary(String id, _Act a, bool busy) => FilledButton.icon(
        onPressed: busy ? null : () => _run(id, a.run),
        icon: busy
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Neon.onAccent),
              )
            : Icon(a.icon ?? Icons.arrow_forward_rounded, size: 18),
        label: Text(a.label),
        style: FilledButton.styleFrom(
          backgroundColor: Neon.accentFill,
          foregroundColor: Neon.onAccent,
          disabledBackgroundColor: Neon.accentFill.withValues(alpha: 0.6),
          disabledForegroundColor: Neon.onAccent,
          minimumSize: const Size(48, 48),
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Neon.rTile)),
          textStyle: NeonType.manrope(NeonType.body, FontWeight.w700),
        ),
      );

  Widget _secondary(String id, _Act a, bool busy) => TextButton(
        onPressed: busy ? null : () => _run(id, a.run),
        style: TextButton.styleFrom(
          foregroundColor: Neon.textHi,
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          textStyle: NeonType.manrope(NeonType.body, FontWeight.w600),
        ),
        child: Text(a.label),
      );

  Widget _compact(String id, _Act a, bool busy, {NeonTone tone = NeonTone.brand}) =>
      Padding(
        padding: const EdgeInsets.only(right: 6),
        child: NeonPill(
          label: a.label,
          icon: a.icon,
          tone: tone,
          busy: busy,
          quiet: true,
          onPressed: () => _run(id, a.run),
        ),
      );

  /// What a card's light says it is (NeonTone): information in blue,
  /// something to act on in magenta, something to discover in purple.
  static NeonTone _toneOf(HomeCardKind k) => switch (k) {
        HomeCardKind.meeting => NeonTone.info,
        HomeCardKind.reminder || HomeCardKind.promise || HomeCardKind.birthday => NeonTone.action,
        HomeCardKind.missedCall => NeonTone.danger,
        HomeCardKind.message => NeonTone.discovery,
        HomeCardKind.payment => NeonTone.warning,
        HomeCardKind.getStarted => NeonTone.tip,
      };

  // ── looks and words ──────────────────────────────────────────────────

  Widget? _pageFor(HomeCard c) => switch (c.kind) {
        HomeCardKind.reminder => const RemindersScreen(),
        HomeCardKind.meeting ||
        HomeCardKind.promise ||
        HomeCardKind.birthday =>
          const CalendarScreen(),
        HomeCardKind.payment => const FinanceScreen(),
        _ => null,
      };

  static String _spoken(HomeCard c) =>
      '${_kindName(c.kind)}: ${c.title}. ${c.reason}'
      '${c.detail == null ? '' : '. ${c.detail}'}';

  static String _kindName(HomeCardKind k) => switch (k) {
        HomeCardKind.meeting => 'Meeting',
        HomeCardKind.reminder => 'Reminder',
        HomeCardKind.promise => 'Promise',
        HomeCardKind.missedCall => 'Missed call',
        HomeCardKind.message => 'Message',
        HomeCardKind.birthday => 'Birthday',
        HomeCardKind.payment => 'Bill',
        HomeCardKind.getStarted => 'Get started',
      };

  static (IconData, Color) _look(HomeCardKind k) => switch (k) {
        HomeCardKind.meeting => (Icons.groups_rounded, Neon.accentA),
        HomeCardKind.reminder =>
          (Icons.notifications_active_rounded, Neon.accentA),
        HomeCardKind.promise => (Icons.handshake_rounded, Neon.accentB),
        HomeCardKind.missedCall => (Icons.phone_missed_rounded, Neon.accentB),
        HomeCardKind.message => (Icons.mark_email_unread_rounded, Neon.accentC),
        HomeCardKind.birthday => (Icons.cake_rounded, Neon.accentB),
        HomeCardKind.payment => (Icons.receipt_long_rounded, Neon.accentD),
        HomeCardKind.getStarted => (Icons.graphic_eq_rounded, Neon.accentA),
      };

  static Widget _tile(HomeCardKind k, double size) {
    final (icon, tint) = _look(k);
    return GlassTile(icon, tint, size: size);
  }

  /// When it is ("In 25 min"): a small glass chip, figures aligned.
  static Widget _pill(String text) => Align(
        alignment: Alignment.centerRight,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Neon.textHi.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(Neon.rPill),
            border: Border.all(color: Neon.hairline),
          ),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: NeonType.manrope(NeonType.caption, FontWeight.w700)
                .copyWith(color: Neon.textHi, fontFeatures: NeonType.figures),
          ),
        ),
      );
}

/// A button: what it says, its icon, and what it does (true when done).
class _Act {
  _Act(this.label, this.icon, this.run);
  final String label;
  final IconData? icon;
  final Future<bool> Function() run;
}

/// A card that opens its page when tapped (the buttons on it win their
/// own taps). Dips a little under the finger, like every tappable surface.
class _Tap extends StatelessWidget {
  const _Tap({required this.onTap, required this.child});
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (onTap == null) return child;
    return Semantics(
      onTapHint: 'open',
      child: PressScale(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: child,
        ),
      ),
    );
  }
}

/// Nothing needs the user: says so, briefly — what is useful instead
/// follows it (home_extras.dart).
class _AllClear extends StatelessWidget {
  const _AllClear({required this.later});

  /// Something is still on today's list, just not now.
  final bool later;

  @override
  Widget build(BuildContext context) {
    final ink = NeonTone.success.ink;
    // CALM, NOT LOUD (2026-09-30, premium pass): glass with a faint green
    // light in its corner and a small ring — done and well, felt rather
    // than announced. No neon rim, no halo, no second icon.
    return GlassCard(
      wash: ink,
      padding: const EdgeInsets.fromLTRB(Neon.s5, Neon.s5, Neon.s5, Neon.s5),
      child: Row(
        children: [
          ExcludeSemantics(
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ink.withValues(alpha: 0.10),
                border: Border.all(color: ink.withValues(alpha: 0.32)),
              ),
              child: Icon(Icons.check_rounded, size: 22, color: ink),
            ),
          ),
          const SizedBox(width: Neon.s4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("You're all clear",
                    style: NeonType.glassTitle.copyWith(color: Neon.textHi)),
                const SizedBox(height: 2),
                Text(
                  later ? 'Nothing needs you right now.' : 'Nothing needs you today.',
                  style: TextStyle(color: Neon.textLo, fontSize: NeonType.body, height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The shape of the feed — the Now card and three lines — breathing gently
/// while the first brief loads. Still under reduced motion.
class _Skeleton extends StatefulWidget {
  const _Skeleton();

  @override
  State<_Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<_Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900));
  late final Animation<double> _breath =
      Tween(begin: 0.45, end: 1.0).animate(_pulse);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      _pulse
        ..stop()
        ..value = 1.0;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Widget _bar(double widthFactor, double height) => FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: widthFactor,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: Neon.textDim.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading your day',
      child: RepaintBoundary(
        child: FadeTransition(
          opacity: _breath,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Neon.surface,
                  borderRadius: BorderRadius.circular(Neon.rCard),
                  border: Border.all(color: Neon.hairline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _bar(0.3, 14),
                    const SizedBox(height: 14),
                    _bar(0.8, 16),
                    const SizedBox(height: 8),
                    _bar(0.5, 12),
                    const SizedBox(height: 16),
                    _bar(0.35, 36),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _bar(0.25, 14),
              for (final w in const [0.7, 0.55, 0.6]) ...[
                const SizedBox(height: 16),
                _bar(w, 12),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});
  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
