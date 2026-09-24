package com.myassistant.myassistant

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Color
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.TextUtils
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.widget.LinearLayout
import android.widget.TextView

/**
 * THE ASSISTANT'S HANDS — uses the phone the way the owner would: opens
 * any app, moves between apps, reads the screen, taps, types, scrolls,
 * swipes, and uses Home / Back / notifications / quick settings — only
 * while a task the owner asked for is running.
 *
 * WHAT IT DOES WHEN NO TASK IS RUNNING: nothing. Events only move a
 * timestamp (so a step can tell when the screen has settled); no screen is
 * read and nothing leaves the phone until the Dart side calls begin().
 *
 * THE LINES IT NEVER CROSSES, checked here on the device whatever the
 * server says (the server's guard.js checks the same things first):
 *   • tapping anything that pays, places/confirms a paid order or moves
 *     money
 *   • typing into password, PIN, OTP, card, bank or ID fields
 *   • tapping Send in a messaging app
 *   • deleting or erasing anything
 *   • security settings (screen lock, accessibility, device admin, unknown
 *     apps, developer options, accounts, reset)
 *   • acting in payment apps, the package installer or permission pop-ups
 * A refused step comes back as {blocked: kind} and the run hands the phone
 * to the owner.
 */
class HariAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: HariAccessibilityService? = null

        private const val TAG = "hari/auto"
        private const val MAX_NODES = 300

        // Mirrors src/automation/guard.js on the server. Kept deliberately
        // conservative: a false stop costs the owner one tap, a false go
        // could cost money.
        private val PAY = Regex(
            "^\\s*(?:₹|rs\\.?|inr)?\\s*[\\d,.]*\\s*(?:pay\\b|buy\\b|proceed to pay|proceed to buy|" +
                "make (?:a |the )?payment|place (?:your |the )?order|confirm (?:and|&) pay|" +
                "confirm (?:the |your )?(?:order|payment|purchase|booking|ride|pickup|trip)|" +
                "complete (?:the |your )?(?:payment|purchase|order|booking)|buy now|" +
                "checkout (?:and|&) pay|slide to pay|swipe to pay|" +
                "pay (?:now|securely|using|via|with|₹|rs|inr)|continue to pay|" +
                "book (?:now|ride|cab|tickets? now)|request (?:ride|cab|uber|ola)|" +
                "confirm (?:uber|ola|rapido)\\b)",
            RegexOption.IGNORE_CASE
        )
        private val MONEY = Regex(
            "\\b(?:send money|transfer (?:money|funds|now)|withdraw|add money|pay to|" +
                "request money|scan (?:and|&) pay|collect request|upi pin)\\b",
            RegexOption.IGNORE_CASE
        )
        private val CREDENTIAL = Regex(
            "(?:pass(?:word|code|phrase)|\\bm?pin\\b(?!\\s*-?\\s*code)|\\bupi\\s*pin\\b|\\botp\\b|" +
                "one[\\s-]?time|verification code|\\bcvv\\b|\\bcvc\\b|card\\s*(?:number|no\\b)|" +
                "expiry|valid\\s*(?:thru|till)|\\bupi\\s*id\\b|\\bvpa\\b|net\\s*banking|" +
                "account\\s*(?:number|no\\b)|\\bifsc\\b|aadhaa?r|\\bpan\\b|security\\s*(?:code|question)|secret)",
            RegexOption.IGNORE_CASE
        )
        /** A button that is only a price — a paid app's "₹99.00". */
        private val PRICE_ONLY = Regex("^\\s*(?:₹|rs\\.?|inr|\\$|€|£)\\s*[\\d,.]+\\s*$", RegexOption.IGNORE_CASE)
        private val CARD_NUMBER = Regex("\\b(?:\\d[ -]?){13,19}\\b")
        private val SEND = Regex("^\\s*(?:send|send message|reply|post|share)\\s*$", RegexOption.IGNORE_CASE)
        private val MESSAGING = setOf(
            "com.whatsapp", "com.whatsapp.w4b", "org.telegram.messenger",
            "com.google.android.apps.messaging", "com.samsung.android.messaging",
            "com.google.android.gm", "com.instagram.android", "com.facebook.orca",
        )
        /** Money apps: never acted in, never opened by the assistant. */
        private val MONEY_APPS = setOf(
            "com.google.android.apps.nbu.paisa.user", "com.phonepe.app", "net.one97.paytm",
            "in.org.npci.upiapp", "com.dreamplug.androidapp", "com.mobikwik_new",
            "com.freecharge.android", "com.sbi.upi", "com.sbi.SBIFreedomPlus",
            "com.csam.icici.bank.imobile", "com.snapwork.hdfc", "com.axis.mobile",
            "com.msf.kbank.mobile",
        )
        /** Permission pop-ups: granting access is the owner's decision. */
        private val PERMISSION_APPS = setOf(
            "com.android.permissioncontroller", "com.google.android.permissioncontroller",
        )
        private val INSTALLERS = setOf(
            "com.android.packageinstaller", "com.google.android.packageinstaller",
        )
        /** Never acted in, even if a run asks. */
        val NEVER = MONEY_APPS + PERMISSION_APPS + INSTALLERS
        private val SETTINGS_APPS = setOf(
            "com.android.settings", "com.samsung.android.settings",
            // Settings search runs in its own package — same rules.
            "com.android.settings.intelligence", "com.google.android.settings.intelligence",
            "com.samsung.android.biometrics.app.setting", "com.samsung.android.lool",
        )
        /** Declarations, "I agree", terms, accepting cookies: consent is theirs. */
        private val CONSENT = Regex(
            "\\b(?:i (?:hereby )?(?:agree|declare|accept|certify|confirm|consent|undertake)|" +
                "agree (?:and|&) continue|agree to (?:the |all )?terms|" +
                "accept (?:all|cookies|all cookies|the terms|terms)|terms (?:and|&) conditions|" +
                "self[- ]declaration|declaration)\\b",
            RegexOption.IGNORE_CASE
        )
        /** Deleting is final — the owner's own tap. */
        private val DESTRUCTIVE = Regex(
            "^\\s*(?:delete|delete all|delete permanently|delete for everyone|erase|erase all|" +
                "clear (?:data|storage|all data|cache and data)|format|wipe|factory (?:data )?reset|" +
                "reset (?:phone|device|all|settings)|empty (?:trash|bin)|uninstall|remove account)\\b",
            RegexOption.IGNORE_CASE
        )
        /** Settings that guard the phone itself. Checked only in Settings. */
        private val SECURITY_SETTING = Regex(
            "(?:accessibility|device admin|admin apps|install unknown|unknown apps|unknown sources|" +
                "developer options|usb debugging|wireless debugging|screen lock|lock screen|" +
                "biometric|fingerprint|face recognition|password|passkey|security|privacy|" +
                "play protect|encryption|credential|\\baccounts?\\b|backup|\\breset\\b|factory|" +
                "special (?:app )?access|app permissions|permission manager|default apps|" +
                "sim (?:card )?lock|find my (?:mobile|device)|secure folder)",
            RegexOption.IGNORE_CASE
        )
    }

    private val main = Handler(Looper.getMainLooper())

    /** Last time another app's screen changed (uptime ms). */
    @Volatile
    private var lastChangeAt = 0L

    /** The owner pressed Stop on the pill. */
    @Volatile
    var stopRequested = false
        private set

    // Written on the UI thread (begin/end), read on the bridge's worker.
    @Volatile
    private var allowed: Set<String> = emptySet()
    @Volatile
    private var running = false
    /** Whole-phone runs: any app except NEVER (and never this app). */
    @Volatile
    private var anyApp = false

    /** Elements of the last snapshot, by the id the planner saw. */
    @Volatile
    private var byId: List<AccessibilityNodeInfo> = emptyList()

    private var pill: View? = null
    private var pillText: TextView? = null
    private var pillStop: TextView? = null
    private var pillParams: WindowManager.LayoutParams? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.i(TAG, "connected")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Only the clock moves. Our own pill does not count as the screen
        // changing, or a step would wait on its own status text.
        if (event?.packageName?.toString() != packageName) {
            lastChangeAt = SystemClock.uptimeMillis()
        }
    }

    override fun onInterrupt() {}

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        hidePill()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        hidePill()
        super.onDestroy()
    }

    /* ---------------------------------------------------------------- *
     * RUN LIFECYCLE
     * ---------------------------------------------------------------- */

    fun begin(allowedPkgs: List<String>, status: String, any: Boolean = false) {
        allowed = allowedPkgs.filter { it.isNotBlank() && it !in NEVER }.toSet()
        anyApp = any
        stopRequested = false
        running = true
        showPill(status)
    }

    /** May the run read and act in [pkg]? Never this app itself. */
    fun isAllowed(pkg: String): Boolean =
        pkg.isNotEmpty() && pkg != packageName && pkg !in NEVER && (anyApp || pkg in allowed)

    /** Why a package is off limits, for the hand-over message. */
    fun blockKind(pkg: String): String = when {
        pkg == packageName -> "returned"
        pkg in MONEY_APPS -> "payment"
        pkg in PERMISSION_APPS -> "permission"
        pkg in INSTALLERS -> "blocked_app"
        else -> "left_app"
    }

    fun allow(pkg: String) {
        if (pkg.isNotBlank() && pkg !in NEVER) allowed = allowed + pkg
    }

    /**
     * The run is over. With [finalText] the bar stays a few seconds to say
     * how it ended ("in your cart — ready to pay"); the owner is usually
     * still in the other app, where the assistant never speaks aloud.
     */
    fun end(finalText: String = "") {
        running = false
        anyApp = false
        allowed = emptySet()
        byId = emptyList()
        if (finalText.isBlank()) { hidePill(); return }
        main.post {
            pillText?.apply { text = finalText; maxLines = 3; maxWidth = dp(270) }
            pillStop?.apply {
                text = "OK"
                setTextColor(Color.parseColor("#B9F6CA"))
                setOnClickListener { hidePill() }
            }
        }
        main.postDelayed({ if (!running) hidePill() }, 9000)
    }

    fun foreground(): String = rootInActiveWindow?.packageName?.toString() ?: ""

    /* ---------------------------------------------------------------- *
     * READING THE SCREEN
     * ---------------------------------------------------------------- */

    fun snapshot(): Map<String, Any?> {
        val root = rootInActiveWindow
        val pkg = root?.packageName?.toString() ?: ""
        val out = ArrayList<Map<String, Any?>>()
        val keep = ArrayList<AccessibilityNodeInfo>()
        // Nothing is read outside a run, or from an app the run may not
        // touch — the package name alone is enough to hand over.
        val ok = running && isAllowed(pkg)
        if (root != null && ok) {
            val dm = resources.displayMetrics
            val screenArea = dm.widthPixels.toLong() * dm.heightPixels.toLong()
            walk(root, false, -1, out, keep, screenArea)
        }
        byId = keep
        return mapOf(
            "pkg" to pkg,
            "allowed" to ok,
            "block" to if (ok) "" else blockKind(pkg),
            "keyboard" to keyboardOpen(),
            "stop" to stopRequested,
            "nodes" to out,
        )
    }

    private fun keyboardOpen(): Boolean = try {
        windows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
    } catch (_: Throwable) { false }

    private fun walk(
        n: AccessibilityNodeInfo,
        insideCard: Boolean,
        clickUp: Int,
        out: ArrayList<Map<String, Any?>>,
        keep: ArrayList<AccessibilityNodeInfo>,
        screenArea: Long,
    ) {
        if (out.size >= MAX_NODES) return
        if (!n.isVisibleToUser) return
        val r = Rect()
        n.getBoundsInScreen(r)
        if (r.width() <= 0 || r.height() <= 0) return

        val text = n.text?.toString()?.trim().orEmpty()
        val desc = n.contentDescription?.toString()?.trim().orEmpty()
        val hint = if (Build.VERSION.SDK_INT >= 26) n.hintText?.toString()?.trim().orEmpty() else ""
        val interactive = n.isClickable || n.isEditable || n.isScrollable || n.isCheckable
        // A tappable card collects its children's words into one label, so
        // "Paradise Biryani 4.4 · 30 mins" is ONE thing to tap. Not for
        // containers covering most of the screen — they would swallow it.
        val area = r.width().toLong() * r.height().toLong()
        val isCard = n.isClickable && !n.isEditable && area < screenArea * 2 / 5

        // Plain text inside a card is already in the card's label.
        val skip = !interactive && insideCard
        var myId = -1
        if (!skip && (interactive || text.isNotEmpty() || desc.isNotEmpty() || hint.isNotEmpty())) {
            var label = ""
            if (isCard && text.isEmpty() && desc.isEmpty()) {
                val sb = StringBuilder()
                collectText(n, sb, 0)
                label = sb.toString().trim()
            } else if (n.isEditable) {
                label = n.labeledBy?.text?.toString()?.trim().orEmpty()
            }
            val cls = n.className?.toString()?.substringAfterLast('.') ?: ""
            val rid = n.viewIdResourceName?.substringAfterLast('/') ?: ""
            myId = keep.size
            out.add(
                mapOf(
                    "id" to myId,
                    // What a tap here would really press: the nearest
                    // tappable element above it. The server judges both.
                    "up" to if (n.isClickable) -1 else clickUp,
                    "cls" to cls,
                    "text" to if (n.isPassword) "" else text.take(200),
                    "desc" to desc.take(200),
                    "hint" to hint.take(120),
                    "rid" to rid.take(80),
                    "label" to label.take(240),
                    "click" to if (n.isClickable) 1 else 0,
                    "edit" to if (n.isEditable) 1 else 0,
                    "scroll" to if (n.isScrollable) 1 else 0,
                    "check" to if (n.isCheckable) 1 else 0,
                    "checked" to if (n.isChecked) 1 else 0,
                    "sel" to if (n.isSelected) 1 else 0,
                    "pwd" to if (n.isPassword) 1 else 0,
                    "en" to if (n.isEnabled) 1 else 0,
                )
            )
            keep.add(n)
        }
        for (i in 0 until n.childCount) {
            val c = n.getChild(i) ?: continue
            val up = if (n.isClickable && myId >= 0) myId else clickUp
            walk(c, insideCard || isCard, up, out, keep, screenArea)
            if (out.size >= MAX_NODES) return
        }
    }

    private fun collectText(n: AccessibilityNodeInfo, sb: StringBuilder, depth: Int) {
        if (depth > 8 || sb.length > 240) return
        val t = (n.text ?: n.contentDescription)?.toString()?.trim()
        if (!t.isNullOrEmpty() && !n.isPassword) {
            if (sb.isNotEmpty()) sb.append(" · ")
            sb.append(t)
        }
        for (i in 0 until n.childCount) {
            val c = n.getChild(i) ?: continue
            collectText(c, sb, depth + 1)
        }
    }

    /* ---------------------------------------------------------------- *
     * ACTING
     * ---------------------------------------------------------------- */

    private fun fail(error: String) = mapOf("ok" to false, "error" to error)
    private fun blocked(kind: String) = mapOf("ok" to false, "error" to "blocked", "blocked" to kind)

    private fun ownLabel(n: AccessibilityNodeInfo): String =
        (n.text?.toString()?.trim().takeUnless { it.isNullOrEmpty() }
            ?: n.contentDescription?.toString()?.trim()).orEmpty()

    /** The words a tap would be judged by: its own, or a short card label. */
    private fun tapWords(n: AccessibilityNodeInfo): List<String> {
        val own = ownLabel(n)
        val sb = StringBuilder()
        collectText(n, sb, 0)
        val merged = sb.toString().trim()
        return listOfNotNull(
            own.takeIf { it.isNotEmpty() },
            merged.takeIf { it.isNotEmpty() && it.length <= 40 },
        )
    }

    private fun fieldWords(n: AccessibilityNodeInfo): String {
        val hint = if (Build.VERSION.SDK_INT >= 26) n.hintText?.toString().orEmpty() else ""
        return listOf(
            hint,
            n.viewIdResourceName?.substringAfterLast('/').orEmpty(),
            n.contentDescription?.toString().orEmpty(),
            n.labeledBy?.text?.toString().orEmpty(),
        ).joinToString(" ")
    }

    fun act(a: Map<String, Any?>): Map<String, Any?> {
        if (stopRequested) return mapOf("ok" to false, "error" to "stopped", "stop" to true)
        if (!running) return fail("not_running")
        val fg = foreground()
        val type = a["type"] as? String ?: return fail("no_type")
        // Moving around the phone (Home, Back, opening an app, the shade)
        // is fine from anywhere; touching a screen needs it to be allowed.
        val global = type in setOf("home", "back", "recents", "notifications",
            "quick_settings", "open_app", "wait", "screenshot")
        if (!global && !isAllowed(fg)) return fail("not_allowed:$fg")

        val id = (a["id"] as? Number)?.toInt()
        val node = id?.let { byId.getOrNull(it) }

        return when (type) {
            "tap" -> {
                val n = node ?: return fail("no_such_element")
                var target: AccessibilityNodeInfo? = n
                while (target != null && !target.isClickable) target = target.parent
                // Judged on what the click would ACTUALLY press: "₹312"
                // is harmless text, its parent "Proceed to Pay" is not.
                for (judged in listOfNotNull(n, target)) {
                    val words = tapWords(judged)
                    val merged = StringBuilder().also { collectText(judged, it, 0) }.toString()
                    if (words.any { PAY.containsMatchIn(it) || PRICE_ONLY.matches(it) } ||
                        PAY.containsMatchIn(merged)) {
                        return blocked("payment")
                    }
                    if (words.any { MONEY.containsMatchIn(it) }) return blocked("money")
                    if (fg in MESSAGING && words.any { SEND.matches(it) }) return blocked("message_send")
                    if (words.any { DESTRUCTIVE.containsMatchIn(it) }) return blocked("destructive")
                    if (CONSENT.containsMatchIn(ownLabel(judged)) ||
                        (judged.isCheckable && CONSENT.containsMatchIn(merged))) return blocked("consent")
                    if (fg in SETTINGS_APPS && (words + merged).any { SECURITY_SETTING.containsMatchIn(it) }) {
                        return blocked("security")
                    }
                }
                val ok = target?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true
                if (ok) mapOf("ok" to true, "how" to "click") else {
                    val r = Rect(); n.getBoundsInScreen(r)
                    if (tapAt(r.exactCenterX(), r.exactCenterY())) mapOf("ok" to true, "how" to "gesture")
                    else fail("tap_failed")
                }
            }
            "type" -> {
                val n = node ?: return fail("no_such_element")
                val text = (a["text"] as? String).orEmpty()
                if (n.isPassword || CREDENTIAL.containsMatchIn(fieldWords(n)) ||
                    CARD_NUMBER.containsMatchIn(text)) return blocked("credential")
                if (!n.isEditable) return fail("not_a_field")
                n.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
                val args = Bundle().apply {
                    putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
                }
                val set = n.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                n.refresh()
                // Verified, not assumed: the field must now hold the text.
                val now = n.text?.toString().orEmpty()
                val verified = set && (now == text || now.contains(text) || text.isEmpty())
                var submitted = false
                if (verified && a["submit"] == true && Build.VERSION.SDK_INT >= 30) {
                    submitted = n.performAction(
                        AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
                }
                if (!verified) fail("text_not_set")
                else mapOf("ok" to true, "verified" to true, "submitted" to submitted)
            }
            "scroll" -> {
                val forward = (a["direction"] as? String) != "up"
                var target: AccessibilityNodeInfo? = node
                while (target != null && !target.isScrollable) target = target.parent
                if (target == null) target = byId.firstOrNull { it.isScrollable }
                val action = if (forward) AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                if (target?.performAction(action) == true) mapOf("ok" to true, "how" to "scroll")
                else if (swipe(forward)) mapOf("ok" to true, "how" to "gesture")
                else fail("scroll_failed")
            }
            "long_press" -> {
                val n = node ?: return fail("no_such_element")
                var target: AccessibilityNodeInfo? = n
                while (target != null && !target.isLongClickable && !target.isClickable) target = target.parent
                val words = tapWords(target ?: n)
                if (words.any { PAY.containsMatchIn(it) || MONEY.containsMatchIn(it) }) return blocked("payment")
                if (words.any { DESTRUCTIVE.containsMatchIn(it) }) return blocked("destructive")
                if (target?.performAction(AccessibilityNodeInfo.ACTION_LONG_CLICK) == true) {
                    mapOf("ok" to true, "how" to "long_click")
                } else {
                    val r = Rect(); n.getBoundsInScreen(r)
                    if (pressAt(r.exactCenterX(), r.exactCenterY())) mapOf("ok" to true, "how" to "gesture")
                    else fail("long_press_failed")
                }
            }
            "swipe" -> if (swipeDir((a["direction"] as? String) ?: "up")) mapOf("ok" to true) else fail("swipe_failed")
            "open_app" -> {
                val name = (a["name"] as? String).orEmpty()
                val hit = matchLauncherApp(packageManager, name) ?: return fail("app_not_found")
                if (hit.first in MONEY_APPS) return blocked("payment")
                if (hit.first in NEVER || hit.first == packageName) return blocked("blocked_app")
                val launch = packageManager.getLaunchIntentForPackage(hit.first) ?: return fail("app_not_found")
                try {
                    startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    mapOf("ok" to true, "opened" to hit.second)
                } catch (e: Throwable) { fail("launch_failed") }
            }
            "home" -> if (performGlobalAction(GLOBAL_ACTION_HOME)) mapOf("ok" to true) else fail("home_failed")
            "back" -> if (performGlobalAction(GLOBAL_ACTION_BACK)) mapOf("ok" to true) else fail("back_failed")
            "recents" -> if (performGlobalAction(GLOBAL_ACTION_RECENTS)) mapOf("ok" to true) else fail("recents_failed")
            "notifications" -> if (performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)) mapOf("ok" to true) else fail("shade_failed")
            "quick_settings" -> if (performGlobalAction(GLOBAL_ACTION_QUICK_SETTINGS)) mapOf("ok" to true) else fail("shade_failed")
            "screenshot" -> if (Build.VERSION.SDK_INT >= 28 && performGlobalAction(GLOBAL_ACTION_TAKE_SCREENSHOT)) {
                mapOf("ok" to true)
            } else fail("screenshot_failed")
            "wait" -> mapOf("ok" to true)
            else -> fail("unknown_action")
        }
    }

    /** Waits until the screen has been quiet for [quietMs], at most [maxMs]. */
    fun settle(quietMs: Long, maxMs: Long, done: () -> Unit) {
        val start = SystemClock.uptimeMillis()
        val tick = object : Runnable {
            override fun run() {
                val now = SystemClock.uptimeMillis()
                val quiet = now - lastChangeAt >= quietMs
                if ((quiet && now - start >= 250) || now - start >= maxMs) done()
                else main.postDelayed(this, 80)
            }
        }
        main.postDelayed(tick, 120)
    }

    /* ---------------------------------------------------------------- *
     * "INSTALL SWIGGY" — press Install, wait, open it
     * ---------------------------------------------------------------- */

    /**
     * Finishes what openStore started: on the Play Store page for the app
     * the owner named, presses Install, waits for the download and opens
     * the app. Only in the Play Store, only a FREE app (a price or "Buy"
     * stops it), and when the Store opened on a search instead of the
     * app's own page, only a result whose name matches. Returns false when
     * it cannot start (another task running).
     */
    @Volatile
    private var installing = false

    private fun norm(s: String) = s.lowercase().replace(Regex("[^a-z0-9]"), "")

    private fun visibleNodes(root: AccessibilityNodeInfo): List<AccessibilityNodeInfo> {
        val out = ArrayList<AccessibilityNodeInfo>()
        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.add(root)
        while (stack.isNotEmpty() && out.size < 500) {
            val n = stack.removeLast()
            if (!n.isVisibleToUser) continue
            out.add(n)
            for (i in n.childCount - 1 downTo 0) n.getChild(i)?.let { stack.add(it) }
        }
        return out
    }

    private fun clickUp(n: AccessibilityNodeInfo): Boolean {
        var t: AccessibilityNodeInfo? = n
        while (t != null && !t.isClickable) t = t.parent
        return t?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true
    }

    fun autoInstall(pkg: String, name: String): Boolean {
        if (installing || running) return false
        installing = true
        stopRequested = false
        val store = "com.android.vending"
        val label = name.trim().ifEmpty { pkg }
        val want = norm(name)
        val started = SystemClock.uptimeMillis()
        var pressedAt = 0L
        var presses = 0
        var openedListing = pkg.isNotEmpty()
        showPill("Installing $label…")

        fun done(text: String) {
            installing = false
            end(text)
        }

        fun openApp(launch: Intent) {
            try {
                startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                done("$label is installed — opened it for you.")
            } catch (e: Throwable) {
                done("$label is installed — tap its icon to open it.")
            }
        }

        val tick = object : Runnable {
            override fun run() {
                if (!installing) return
                val now = SystemClock.uptimeMillis()
                if (stopRequested) {
                    done(if (presses > 0) "Stopped. The download may still finish on its own." else "Stopped.")
                    return
                }
                // Arrived — open it (InstallWatch saw the package land).
                InstallWatch.takeReady(this@HariAccessibilityService)?.let { openApp(it); return }
                if (pkg.isNotEmpty() && presses > 0) {
                    packageManager.getLaunchIntentForPackage(pkg)?.let { openApp(it); return }
                }

                val root = rootInActiveWindow
                if (root?.packageName?.toString() == store) {
                    val nodes = visibleNodes(root)
                    val said = { n: AccessibilityNodeInfo ->
                        (n.text?.toString()?.trim().takeUnless { it.isNullOrEmpty() }
                            ?: n.contentDescription?.toString()?.trim()).orEmpty()
                    }
                    val install = nodes.firstOrNull { said(it).equals("install", ignoreCase = true) }
                    val open = nodes.firstOrNull { said(it).equals("open", ignoreCase = true) }
                    // A price instead of Install: buying is the owner's step.
                    if (presses == 0 && install == null &&
                        nodes.any { PRICE_ONLY.matches(said(it)) || said(it).startsWith("Buy", true) }) {
                        done("$label is a paid app — buying it is your step, so I've left it open for you.")
                        return
                    }
                    if (nodes.any { said(it).matches(Regex("(?i)^sign in$")) }) {
                        done("The app store wants you to sign in first — then say install $label again.")
                        return
                    }
                    // "Complete account setup" and similar: skip, never add
                    // a payment method.
                    nodes.firstOrNull { said(it).equals("skip", ignoreCase = true) }?.let {
                        clickUp(it)
                        main.postDelayed(this, 900)
                        return
                    }
                    if (!openedListing) {
                        // Search results: open the app whose name matches,
                        // never the top ad's Install button.
                        val title = nodes.firstOrNull {
                            val t = it.text?.toString().orEmpty()
                            want.length >= 3 && t.isNotEmpty() && norm(t).startsWith(want)
                        }
                        if (title != null && clickUp(title)) {
                            openedListing = true
                            status("Opening $label's page…")
                        }
                    } else if (install != null && install.isEnabled) {
                        if (presses == 0 || now - pressedAt > 7000) {
                            if (presses >= 2) {
                                done("The download didn't start — tap Install yourself.")
                                return
                            }
                            if (clickUp(install)) {
                                presses++
                                pressedAt = now
                                status("Downloading $label…")
                            }
                        }
                    } else if (install == null && presses > 0) {
                        // Downloading: show Play Store's own progress.
                        nodes.map { said(it) }.firstOrNull { Regex("\\d+\\s*%").containsMatchIn(it) }
                            ?.let { status("Downloading $label… ${Regex("\\d+\\s*%").find(it)!!.value}") }
                    } else if (open != null && presses == 0) {
                        // Already on the phone.
                        clickUp(open)
                        done("$label was already installed — opened it.")
                        return
                    }
                }

                val waited = now - started
                if (presses == 0 && waited > 30_000) {
                    done("I couldn't find the Install button — please tap it yourself.")
                    return
                }
                if (waited > 12 * 60_000) {
                    done("$label is still downloading — it'll be on your home screen when done.")
                    return
                }
                main.postDelayed(this, if (presses == 0) 700 else 1500)
            }
        }
        main.postDelayed(tick, 1200)
        return true
    }

    /* ---------------------------------------------------------------- *
     * GESTURES — only when a plain click was refused
     * ---------------------------------------------------------------- */

    private fun tapAt(x: Float, y: Float): Boolean {
        if (Build.VERSION.SDK_INT < 24) return false
        val path = Path().apply { moveTo(x, y) }
        return dispatch(GestureDescription.StrokeDescription(path, 0, 60))
    }

    private fun pressAt(x: Float, y: Float): Boolean {
        if (Build.VERSION.SDK_INT < 24) return false
        val path = Path().apply { moveTo(x, y) }
        return dispatch(GestureDescription.StrokeDescription(path, 0, 700))
    }

    /** A finger across the screen: "left" moves content left (next page). */
    private fun swipeDir(direction: String): Boolean {
        if (Build.VERSION.SDK_INT < 24) return false
        val dm = resources.displayMetrics
        val w = dm.widthPixels.toFloat()
        val h = dm.heightPixels.toFloat()
        val path = Path().apply {
            when (direction) {
                "left" -> { moveTo(w * 0.85f, h * 0.5f); lineTo(w * 0.15f, h * 0.5f) }
                "right" -> { moveTo(w * 0.15f, h * 0.5f); lineTo(w * 0.85f, h * 0.5f) }
                "down" -> { moveTo(w * 0.5f, h * 0.30f); lineTo(w * 0.5f, h * 0.72f) }
                else -> { moveTo(w * 0.5f, h * 0.72f); lineTo(w * 0.5f, h * 0.30f) }
            }
        }
        return dispatch(GestureDescription.StrokeDescription(path, 0, 300))
    }

    private fun swipe(forward: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < 24) return false
        val dm = resources.displayMetrics
        val x = dm.widthPixels / 2f
        val top = dm.heightPixels * 0.30f
        val bottom = dm.heightPixels * 0.72f
        val path = Path().apply {
            if (forward) { moveTo(x, bottom); lineTo(x, top) } else { moveTo(x, top); lineTo(x, bottom) }
        }
        return dispatch(GestureDescription.StrokeDescription(path, 0, 320))
    }

    private fun dispatch(stroke: GestureDescription.StrokeDescription): Boolean {
        if (Build.VERSION.SDK_INT < 24) return false
        // The pill must not catch our own finger.
        setPillTouchable(false)
        val ok = dispatchGesture(
            GestureDescription.Builder().addStroke(stroke).build(),
            object : GestureResultCallback() {
                override fun onCompleted(g: GestureDescription?) { setPillTouchable(true) }
                override fun onCancelled(g: GestureDescription?) { setPillTouchable(true) }
            },
            null
        )
        if (!ok) setPillTouchable(true)
        return ok
    }

    /* ---------------------------------------------------------------- *
     * THE PILL — "working on it… Stop", drawn over the other app
     * ---------------------------------------------------------------- */

    private fun dp(v: Int): Int = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    fun status(text: String) {
        main.post { pillText?.text = text }
    }

    private fun showPill(text: String) {
        main.post {
            try {
                if (pill == null) {
                    val wm = getSystemService(WINDOW_SERVICE) as WindowManager
                    val row = LinearLayout(this).apply {
                        orientation = LinearLayout.HORIZONTAL
                        gravity = Gravity.CENTER_VERTICAL
                        setPadding(dp(14), dp(8), dp(8), dp(8))
                        background = GradientDrawable().apply {
                            cornerRadius = dp(22).toFloat()
                            setColor(Color.parseColor("#EE1B1440"))
                            setStroke(dp(1), Color.parseColor("#667C6CF6"))
                        }
                        elevation = dp(6).toFloat()
                    }
                    val dot = View(this).apply {
                        background = GradientDrawable().apply {
                            shape = GradientDrawable.OVAL
                            setColor(Color.parseColor("#8B7CFF"))
                        }
                    }
                    row.addView(dot, LinearLayout.LayoutParams(dp(8), dp(8)).apply { rightMargin = dp(8) })
                    val label = TextView(this).apply {
                        setTextColor(Color.WHITE)
                        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                        maxLines = 1
                        ellipsize = TextUtils.TruncateAt.END
                        maxWidth = dp(230)
                    }
                    row.addView(label)
                    val stop = TextView(this).apply {
                        this.text = "Stop"
                        setTextColor(Color.parseColor("#FFB4A9"))
                        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                        setTypeface(typeface, android.graphics.Typeface.BOLD)
                        setPadding(dp(12), dp(4), dp(8), dp(4))
                        contentDescription = "Stop the assistant"
                        setOnClickListener {
                            stopRequested = true
                            label.text = "Stopping…"
                        }
                    }
                    row.addView(stop)
                    val lp = WindowManager.LayoutParams(
                        WindowManager.LayoutParams.WRAP_CONTENT,
                        WindowManager.LayoutParams.WRAP_CONTENT,
                        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                        PixelFormat.TRANSLUCENT
                    ).apply {
                        gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                        y = dp(34)
                    }
                    wm.addView(row, lp)
                    pill = row
                    pillText = label
                    pillStop = stop
                    pillParams = lp
                }
                // A new run over a finished bar: back to the working look.
                pillText?.apply { this.text = text; maxLines = 1; maxWidth = dp(230) }
                pillStop?.apply {
                    this.text = "Stop"
                    setTextColor(Color.parseColor("#FFB4A9"))
                    setOnClickListener {
                        stopRequested = true
                        pillText?.text = "Stopping…"
                    }
                }
            } catch (e: Throwable) {
                // No pill is not a reason to fail the task; Stop is also
                // reachable by returning to the app.
                Log.w(TAG, "pill failed: ${e.javaClass.simpleName}")
            }
        }
    }

    private fun setPillTouchable(touchable: Boolean) {
        main.post {
            val v = pill ?: return@post
            val lp = pillParams ?: return@post
            lp.flags = if (touchable) lp.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
            else lp.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
            try {
                (getSystemService(WINDOW_SERVICE) as WindowManager).updateViewLayout(v, lp)
            } catch (_: Throwable) {}
        }
    }

    private fun hidePill() {
        main.post {
            val v = pill ?: return@post
            try {
                (getSystemService(WINDOW_SERVICE) as WindowManager).removeView(v)
            } catch (_: Throwable) {}
            pill = null
            pillText = null
            pillStop = null
            pillParams = null
        }
    }
}
