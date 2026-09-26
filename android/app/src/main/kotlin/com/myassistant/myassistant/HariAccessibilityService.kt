package com.myassistant.myassistant

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.accessibilityservice.InputMethod
import android.app.KeyguardManager
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.os.SystemClock
import android.provider.Settings
import android.util.Base64
import android.text.TextUtils
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.view.inputmethod.InputMethodManager
import android.widget.LinearLayout
import android.widget.TextView
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

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
 * FASTER, SURER STEPS (2026-09-24 — the owner: "make this dumb assistant
 * much smartest and faster"; an Instagram follow took 10-17 s a step):
 *   • a step waits for ITS action's effect (an event after the action),
 *     not for the whole phone to fall silent — the clock, the keyboard and
 *     our own bar no longer count as the screen changing (settle)
 *   • the first look waits for the app to be drawn, not a fixed 6 s
 *     (waitForApp)
 *   • the element list and the picture are taken at the same time
 *   • an element that moved or was reused for another row since the look
 *     is found again, or the step says so (stale_element) — never a tap on
 *     the row next to it
 *   • a search box that ignores typed-in text gets the text pasted, the
 *     way a finger would (Instagram's search showed no results)
 *   • the bar sits at the bottom, clear of apps' search bars at the top
 *
 * THE LINES IT NEVER CROSSES, checked here on the device whatever the
 * server says (the server's guard.js checks the same things first):
 *   • tapping anything that pays, places/confirms a paid order or moves
 *     money
 *   • typing into password, PIN, OTP, card, bank or ID fields — including
 *     the unlabeled one-digit boxes of an OTP screen
 *   • tapping Send (in any app), posting (also a post's or a reply's last
 *     "Share" / "Reply" while it is being written), or pressing the
 *     keyboard's Enter where Enter could send (chats, the notification
 *     shade, any field that is not a search)
 *   • typing in the notification shade (its inline Reply sends)
 *   • deleting or erasing anything, disabling or force-stopping an app
 *   • security settings (screen lock, accessibility, device admin, unknown
 *     apps, developer options, accounts, reset)
 *   • pressing Install / Update in the app store unless the owner asked for
 *     an install (and, when the server names the app, another app's button)
 *   • acting in payment apps, any package installer or permission pop-ups
 *     (a permission pop-up is the owner's turn: the run waits for Continue)
 * A refused step comes back as {blocked: kind}. The run carries on (the
 * server picks another step); a second refusal hands the phone over.
 *
 * A run the Dart task loop stops calling in to (the app was swiped away)
 * ends itself after a minute, so the bar never holds the screen on for
 * good.
 */
class HariAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: HariAccessibilityService? = null

        private const val TAG = "hari/auto"
        private const val MAX_NODES = 300
        /** At most this many short buttons per look get their row's words read (rowWords). */
        private const val ROW_WORDS_CAP = 60
        /** A run whose task loop has not called in this long is orphaned. */
        private const val DART_SILENT_MS = 60_000L
        private const val DEAD_MAN_TICK_MS = 5_000L
        /**
         * Stop pressed and no word from the task loop since, this long:
         * the loop is gone, and the bar ends the run itself. A live loop
         * answers within one settle or app wait (5 s at most).
         */
        private const val STOP_FALLBACK_MS = 8_000L

        // Mirrors src/automation/guard.js on the server. Kept deliberately
        // conservative: a false stop costs the owner one tap, a false go
        // could cost money.
        //
        // FALSE STOPS TAKEN OUT (2026-09-24). Ordinary runs were ending with
        // "it's ready for payment" or "that's a security setting" on things
        // that are neither: a "BUY 1 GET 1" offer card, "Buy again", a price
        // label with nothing tappable around it, "Clear all filters",
        // Instagram's Reply and Share while no compose box is open (they
        // only open one), and Settings rows whose small print says
        // "backup" or "security" (System, Apps, Device care). Those pass
        // now. What must stop still stops: "Proceed to Pay" (also after
        // the bar's price: "₹312 · TOTAL · Proceed to Pay"), "Buy now",
        // "Buy more storage", a price button in any app, the store's
        // "Subscribe", "Share" on a post being written, "Delete", the
        // Security and Lock screen rows, password fields.
        /**
         * What a checkout bar shows BEFORE its pay words: the price, the
         * item count, "TOTAL", the bill link. A bar's texts are joined with
         * " · " (collectText), so Swiggy's bar reads "₹312 · TOTAL ·
         * Proceed to Pay" — and the pay words were missed because they were
         * not first. A card that starts with its NAME is still judged from
         * its first word, so "Paradise · Pay with HDFC, get 10% off" (an
         * offer banner) stays tappable.
         */
        private const val BAR_LEAD =
            "(?:(?:₹|rs\\.?|inr)\\s*[\\d,.]+(?:\\s*(?:total|items?|plus taxes|\\+\\s*taxes))?|" +
                "\\d+\\s*items?(?:\\s*added)?|(?:grand |bill |item |sub ?)?total(?:\\s*(?:₹|rs\\.?|inr)?\\s*[\\d,.]+)?|" +
                "to pay(?:\\s*(?:₹|rs\\.?|inr)?\\s*[\\d,.]+)?|amount payable|" +
                "(?:incl\\.?|including|plus|\\+)\\s*(?:of\\s*)?(?:all\\s*)?taxes|" +
                "view (?:detailed |full )?bill|(?:view )?price details)"
        private val PAY = Regex(
            "^\\s*(?:$BAR_LEAD\\s*[·•|]\\s*)*" +
                "(?:₹|rs\\.?|inr)?\\s*[\\d,.]*\\s*(?:pay\\b|" +
                // "Buy more storage" is a purchase, not an offer card.
                "buy(?! (?:\\d+ get|again|it again|\\d+ at))\\b|" +
                // A trial and a one-tap buy start a charge too.
                "(?:1|one)[- ]tap buy|start (?:your |a |the )?(?:free )?trial|" +
                "subscribe (?:for|at) (?:₹|rs|inr|\\$|\\d)|proceed to pay|proceed to buy|" +
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
        /**
         * A button that is only a price — a paid app's "₹99.00", a game's
         * in-app "₹89.00": tapping it buys, in any app. Judged on what the
         * tap really presses (judgeTap): a price that is only text on a
         * menu row — nothing tappable around it, or inside a dish card
         * that says more than the price — is not a buy button. In the app
         * stores every price counts.
         */
        private val PRICE_ONLY = Regex("^\\s*(?:₹|rs\\.?|inr|\\$|€|£)\\s*[\\d,.]+\\s*$", RegexOption.IGNORE_CASE)
        /**
         * The app store's billing sheet (in-app purchases and
         * subscriptions of every app are drawn there): these charge. Store
         * only — elsewhere "Subscribe" follows a channel for free. (The
         * server's STORE_PAY.)
         */
        private val STORE_PAY = Regex(
            "^\\s*(?:subscribe|(?:1|one)[- ]tap buy|buy with\\b|purchase(?! history)|confirm purchase|" +
                "start (?:your |a )?(?:free )?trial)\\b",
            RegexOption.IGNORE_CASE
        )
        private val CARD_NUMBER = Regex("\\b(?:\\d[ -]?){13,19}\\b")
        /**
         * SEND, IN ANY APP. The chat-app list alone let a "Send" through in
         * every app not on it — a newer messenger, the share sheet, and the
         * notification shade's inline reply.
         */
        private val SEND_BUTTON = Regex("^\\s*(?:send|send message|send now|send reply)\\s*$", RegexOption.IGNORE_CASE)
        /** In a chat app a little more counts as sending. */
        private val SEND = Regex("^\\s*(?:send|send message|share now)\\s*$", RegexOption.IGNORE_CASE)
        /**
         * "Share" and "Reply" under a post in the feed only OPEN a box. On
         * a COMPOSE screen the same words are the last tap: Instagram's new
         * post, reel or story goes out with "Share" ("Your story" for a
         * story), and X posts a reply with "Reply". (The server's
         * COMPOSE_SUBMIT / COMPOSE_FIELD / COMPOSE_TEXT.)
         */
        private val COMPOSE_SUBMIT = Regex(
            "^\\s*(?:share|reply|your story|share to (?:your )?story|close friends)\\s*$",
            RegexOption.IGNORE_CASE
        )
        /** A box for a caption, a reply or a comment. */
        private val COMPOSE_FIELD = Regex(
            "caption|reply|comment|what'?s happening|what'?s on your mind|what do you want to talk about|" +
                "start a post|post your|add a (?:note|thought)|tweet|thread|write (?:a|something|your)",
            RegexOption.IGNORE_CASE
        )
        /** A compose screen's heading. (Not "Your story" alone: the feed's story tray says that too.) */
        private val COMPOSE_TEXT = Regex(
            "^\\s*(?:new (?:post|reel|story|thread|tweet)|write a caption|add a caption|post your reply|" +
                "replying to\\b|close friends\\s*$)",
            RegexOption.IGNORE_CASE
        )
        private val SEARCH_FIELD = Regex("search", RegexOption.IGNORE_CASE)
        /** Social apps: what they publish is public (the server's SOCIAL_PKGS). */
        private val SOCIAL_APPS = setOf(
            "com.instagram.android", "com.twitter.android", "com.facebook.katana", "com.linkedin.android",
            "com.snapchat.android",
        )
        /** Posting in public, in any app (the server's PUBLISH_ACTION). */
        private val PUBLISH = Regex("^\\s*(?:post|publish|tweet|share now|go live|upload)\\s*$", RegexOption.IGNORE_CASE)
        /** "Clear all filters" narrows a list; it deletes nothing. */
        private val SAFE_CLEAR = Regex("^\\s*(?:clear|reset) (?:all )?filters?\\s*$", RegexOption.IGNORE_CASE)
        /**
         * An OTP screen. Its one-digit boxes usually carry no label at all,
         * so the field alone can't tell — the words on the screen do.
         * "Get OTP" / "Send OTP" on a sign-in sheet are not this; "Enter
         * OTP", "code sent to +91…" are. (The server's OTP_SCREEN.)
         */
        private const val OTP_ALTS =
            "otp|one[- ]time (?:password|passcode|pin|code)|verification code|\\d[- ]digit code"
        private val OTP_SCREEN = Regex(
            "\\b(?:enter|verify|type|resend|re-send|didn'?t (?:get|receive))\\b.{0,20}\\b(?:$OTP_ALTS)" +
                "|\\b(?:$OTP_ALTS|code)\\b.{0,20}\\b(?:sent to|has been sent|we sent|we've sent|sent on)\\b" +
                "|\\bsent (?:you )?(?:an? )?(?:otp|code|verification code)\\b" +
                "|^\\s*(?:$OTP_ALTS)\\s*$",
            RegexOption.IGNORE_CASE
        )
        private val OTP_DIGITS = Regex("^\\s*\\d{4,8}\\s*$")
        /**
         * Fields where the keyboard's Enter only searches. Anywhere else
         * (a chat box, a comment, the shade's reply) Enter can SEND, so it
         * is left for the owner's own tap on the screen's button.
         */
        private val SUBMITTABLE = Regex(
            "search|find|query|where to|destination|drop|pick ?up|location|pin ?code|url|address bar|" +
                "web address|go to|\\bq\\b",
            RegexOption.IGNORE_CASE
        )
        /** Installing is the owner's word: the store's Install / Update. */
        private val INSTALL_BUTTON = Regex(
            "^\\s*(?:install|update|update all|get|enable|install on (?:this|more) devices?)\\s*$",
            RegexOption.IGNORE_CASE
        )
        /** A result card's "Ad" / "Sponsored" part: someone else's app. */
        private val AD_PART = Regex("^(?:ad|ads|sponsored|promoted|suggested for you)$", RegexOption.IGNORE_CASE)
        /** The parts of a card's merged label ("Instagram · Meta · 4.3"). */
        private val PARTS = Regex("\\s*[·•|]\\s*")
        /** Settings' "Disable" for an app: as final as uninstalling it. */
        private val DISABLE_APP = Regex("^\\s*disable(?: app)?\\s*$", RegexOption.IGNORE_CASE)
        /** The app stores: a price or "Subscribe" there buys (the server's STORE_PKGS). */
        private val STORES = setOf("com.android.vending", "com.sec.android.app.samsungapps")
        /** The notification shade and lock screen: typing there replies. */
        private const val SYSTEMUI = "com.android.systemui"
        // The two lists below are the server's MESSAGING_PKGS and
        // PAYMENT_PKGS (src/automation/guard.js), entry for entry. The phone
        // was missing six chat apps and two money apps; change both sides
        // together.
        private val MESSAGING = setOf(
            "com.whatsapp", "com.whatsapp.w4b", "org.telegram.messenger",
            "com.google.android.apps.messaging", "com.samsung.android.messaging",
            "com.google.android.gm", "com.instagram.android", "com.facebook.orca",
            "com.snapchat.android", "com.linkedin.android", "com.twitter.android",
            "com.facebook.katana", "com.microsoft.teams", "com.Slack",
        )
        /** Money apps: never acted in, never opened by the assistant. */
        private val MONEY_APPS = setOf(
            "com.google.android.apps.nbu.paisa.user", "com.phonepe.app", "net.one97.paytm",
            "in.org.npci.upiapp", "com.dreamplug.androidapp", "in.amazon.mShop.android.shopping.pay",
            "com.mobikwik_new", "com.freecharge.android", "com.whatsapp.payments",
            "com.sbi.upi", "com.sbi.SBIFreedomPlus", "com.csam.icici.bank.imobile",
            "com.snapwork.hdfc", "com.axis.mobile", "com.msf.kbank.mobile",
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

        /**
         * NEVER, plus every phone maker's own installer and permission
         * screen (Xiaomi's com.miui.packageinstaller and the like — the
         * server's isSystemPkg): the install, uninstall and allow
         * confirmations are the owner's tap, whoever draws them.
         */
        fun never(pkg: String): Boolean = pkg in NEVER || pkg.endsWith(".packageinstaller") || permissionPkg(pkg)

        /** A permission pop-up, whoever draws it (the server's isPermissionPkg). */
        fun permissionPkg(pkg: String): Boolean = pkg in PERMISSION_APPS || pkg.endsWith(".permissioncontroller")
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
                "reset (?:phone|device|all|settings)|empty (?:trash|bin)|uninstall|remove account|" +
                // Recent apps: closing everything is the owner's call (a
                // run once did it to "restart" an app — and closed us).
                "close all|clear all(?! filters)|end all|force stop)\\b",
            RegexOption.IGNORE_CASE
        )
        /**
         * Settings that guard the phone itself. Checked only in Settings,
         * and only against a row's TITLE ("Security and privacy", "Lock
         * screen") — never its small print, which lists "backup" under
         * System and "security" under Device care.
         */
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

    /**
     * Last time a window came or went in front (TYPE_WINDOW_STATE_CHANGED:
     * a new page, a dialog, a sheet). Content that keeps ticking (a
     * carousel, a video's clock) with no new window for a while is a page
     * that has arrived — "stable" in settle.
     */
    @Volatile
    private var lastStateAt = 0L

    /** When the last action was done (uptime ms): settle waits for its effect. */
    @Volatile
    private var actedAt = 0L

    /**
     * The keyboard's own packages. Its suggestion strip redraws on every
     * letter; that is not the app's screen changing (2026-09-24: a step
     * after typing always hit its cap).
     */
    @Volatile
    private var imePkgs: Set<String> = emptySet()

    /**
     * The status bar's clock and icons tick all the time — not a change,
     * except while the run is in the shade itself (notifications, quick
     * settings), where SystemUI IS the screen.
     */
    @Volatile
    private var watchSystemUi = false

    /**
     * TYPING THAT APPS REACT TO. While text is being set in a field, the
     * field's app and when; [reactedAt] is the app's first answer after it
     * (its list redrawn, a new window, a scroll) — not the field's own
     * text changing.
     */
    @Volatile
    private var typingPkg = ""
    @Volatile
    private var typedAt = 0L
    @Volatile
    private var reactedAt = 0L

    /** A gesture is in flight: the bar's window is not moved meanwhile. */
    @Volatile
    private var gestureBusy = false

    /** The owner pressed Stop on the pill. */
    @Volatile
    var stopRequested = false
        private set

    // Written on the UI thread (begin/end), read on the bridge's worker.
    @Volatile
    private var allowed: Set<String> = emptySet()
    @Volatile
    var running = false
        private set
    /** Whole-phone runs: any app except NEVER (and never this app). */
    @Volatile
    private var anyApp = false
    /**
     * The owner's words asked to install or download an app (the server's
     * may_install). Only then may a run press Install / Update in the app
     * store.
     */
    @Volatile
    private var mayInstall = false
    /**
     * The app the owner asked to install, reduced to a-z0-9 (the
     * directive's install_app). When the server names it, only that
     * app's Install / Update is pressed — on its result card or its own
     * page, never an ad's. Empty: may_install alone decides, as before.
     */
    @Volatile
    private var installWant = ""

    /**
     * When the Dart task loop last called in (uptime ms). Every channel
     * call counts — a step's look, act and settle, and the Stop check it
     * makes four times a second while the server thinks.
     */
    @Volatile
    private var lastHeardAt = 0L

    /** Elements of the last snapshot, by the id the planner saw. */
    @Volatile
    private var byId: List<AccessibilityNodeInfo> = emptyList()

    /**
     * What each element looked like at the look, by the same id: its words,
     * view id, class and box. A list row can be reused for another dish
     * between the look and the tap (2-8 s later, while images load); the
     * tap checks the element is still the one the planner saw.
     */
    private class Fp(val key: String, val rid: String, val cls: String, val box: Rect, val row: String)

    @Volatile
    private var fps: List<Fp> = emptyList()

    /**
     * How the last look's picture came out: ok | black | failed |
     * rate_limited | unsupported | none. A tap on a point of the picture
     * (tap_xy) needs a real picture — without one it is a tap in the dark,
     * and dark (secure) screens are exactly the sign-in and payment sheets.
     */
    @Volatile
    var lastShot = "none"
        private set

    /** The owner's turn (sign-in, OTP…): "" while waiting, "continue" after. */
    @Volatile
    private var ownerReply = ""

    private var pill: View? = null
    private var pillText: TextView? = null
    private var pillStop: TextView? = null
    /** A second button, shown only on the owner's turn: Stop beside Continue. */
    private var pillExtra: TextView? = null
    private var pillParams: WindowManager.LayoutParams? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        LauncherLabels.watch(applicationContext)
        imePkgs = readImePkgs()
        Log.i(TAG, "connected")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        // The keyboard came or went: the bar moves above it (or back down).
        if (event.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED) {
            if (pill != null) {
                main.removeCallbacks(placePill)
                main.postDelayed(placePill, 80)
            }
            // The window list carries no app name: it moves when our own
            // bar resizes for its next line ("tapping ADD") — just as the
            // step starts — and when the keyboard comes or goes. An app's
            // own new page, dialog or pop-up says so itself (a window
            // state change from its package), so these are not counted.
            return
        }
        // Only the clock moves. What does not count as the screen changing:
        // our own bar (a step would wait on its own status text), the
        // keyboard's suggestion strip, and the status bar's clock and icons.
        val pkg = event.packageName?.toString()
        if (pkg == packageName) return
        if (pkg != null && pkg in imePkgs) return
        if (pkg == SYSTEMUI && !watchSystemUi) return
        val now = SystemClock.uptimeMillis()
        lastChangeAt = now
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) lastStateAt = now
        if (pkg != null && pkg == typingPkg && now >= typedAt && reacts(event)) reactedAt = now
    }

    /**
     * The app answering typed text: a new window, a scroll, or part of its
     * screen redrawn (a suggestion list). The field's own text changing is
     * a TEXT-only change and does not count — that is Android, not the app.
     */
    private fun reacts(e: AccessibilityEvent): Boolean = when (e.eventType) {
        AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, AccessibilityEvent.TYPE_VIEW_SCROLLED -> true
        AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED -> {
            val t = e.contentChangeTypes
            t == AccessibilityEvent.CONTENT_CHANGE_TYPE_UNDEFINED ||
                (t and AccessibilityEvent.CONTENT_CHANGE_TYPE_SUBTREE) != 0
        }
        else -> false
    }

    /** The phone's keyboards: the chosen one and every enabled one. */
    private fun readImePkgs(): Set<String> {
        val out = HashSet<String>()
        try {
            Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
                ?.substringBefore('/')?.trim()?.takeIf { it.isNotEmpty() }?.let { out.add(it) }
        } catch (_: Throwable) {}
        try {
            (getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager)
                ?.enabledInputMethodList?.forEach { out.add(it.packageName) }
        } catch (_: Throwable) {}
        out.remove(packageName)
        return out
    }

    override fun onInterrupt() {}

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        hidePill()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        main.removeCallbacks(deadMan)
        main.removeCallbacks(placePill)
        hidePill()
        super.onDestroy()
    }

    /* ---------------------------------------------------------------- *
     * RUN LIFECYCLE
     * ---------------------------------------------------------------- */

    /**
     * A run starts. Refused (false) while an app is installing: the
     * install's own ending calls end(), which would quietly end this run
     * too — its next step would come back "not_running".
     */
    fun begin(allowedPkgs: List<String>, status: String, any: Boolean = false,
              mayInstall: Boolean = false, installApp: String = ""): Boolean {
        if (installing) return false
        allowed = allowedPkgs.filter { it.isNotBlank() && !never(it) }.toSet()
        anyApp = any
        this.mayInstall = mayInstall
        installWant = if (mayInstall) norm(installApp) else ""
        stopRequested = false
        ownerReply = ""
        lastShot = "none"
        actedAt = 0L
        watchSystemUi = false
        typingPkg = ""
        // The owner may have switched keyboards since the service started.
        imePkgs = readImePkgs()
        running = true
        heard()
        main.removeCallbacks(deadMan)
        main.postDelayed(deadMan, DEAD_MAN_TICK_MS)
        showPill(status)
        return true
    }

    /** The Dart task loop called in: it is alive. */
    fun heard() {
        lastHeardAt = SystemClock.uptimeMillis()
    }

    /**
     * NO ORPHANED RUN. The task loop lives in the app's Flutter engine,
     * which goes with the app's screen: swipe the app away mid-run and the
     * loop is gone while this service — and its bar, holding the screen on
     * — lives on. Nothing would ever call end(): the phone would never
     * lock again, and Stop would only ever say "Stopping…". So a run the
     * loop has not called in for [DART_SILENT_MS] ends here. A live loop
     * is never that quiet: it checks Stop four times a second while the
     * server thinks, and polls the bar the same way on the owner's turn.
     */
    private val deadMan = object : Runnable {
        override fun run() {
            if (!running) return
            val quiet = SystemClock.uptimeMillis() - lastHeardAt
            if (quiet >= DART_SILENT_MS) {
                // Counts and times only.
                Log.i(TAG, "task loop silent ${quiet / 1000}s — ending the run")
                end()
                return
            }
            main.postDelayed(this, DEAD_MAN_TICK_MS)
        }
    }

    /** May the run read and act in [pkg]? Never this app itself. */
    fun isAllowed(pkg: String): Boolean =
        pkg.isNotEmpty() && pkg != packageName && !never(pkg) && (anyApp || pkg in allowed)

    /** Why a package is off limits, for the hand-over message. */
    fun blockKind(pkg: String): String = when {
        pkg == packageName -> "returned"
        pkg in MONEY_APPS -> "payment"
        permissionPkg(pkg) -> "permission"
        never(pkg) -> "blocked_app"
        else -> "left_app"
    }

    fun allow(pkg: String) {
        if (pkg.isNotBlank() && !never(pkg)) allowed = allowed + pkg
    }

    /**
     * The run is over. With [finalText] the bar stays a few seconds to say
     * how it ended ("in your cart — ready to pay"); the owner is usually
     * still in the other app, where the assistant never speaks aloud.
     */
    fun end(finalText: String = "") {
        running = false
        main.removeCallbacks(deadMan)
        anyApp = false
        mayInstall = false
        installWant = ""
        allowed = emptySet()
        byId = emptyList()
        fps = emptyList()
        typingPkg = ""
        watchSystemUi = false
        ownerReply = ""
        // The screen may sleep again as soon as nothing is being done.
        keepScreenOn(installing)
        if (finalText.isBlank()) { hidePill(); return }
        main.post {
            pillText?.apply { text = finalText; maxLines = 3; maxWidth = dp(270) }
            pillStop?.apply {
                text = "OK"
                setTextColor(Color.parseColor("#B9F6CA"))
                setOnClickListener { hidePill() }
            }
            pillExtra?.visibility = View.GONE
        }
        main.postDelayed({ if (!running) hidePill() }, 9000)
    }

    fun foreground(): String = rootInActiveWindow?.packageName?.toString() ?: ""

    /** The lock screen is up (the owner pressed power, or it timed out). */
    private fun phoneLocked(): Boolean = try {
        (getSystemService(KEYGUARD_SERVICE) as? KeyguardManager)?.isKeyguardLocked == true
    } catch (_: Throwable) { false }

    /* ---------------------------------------------------------------- *
     * THE OWNER'S TURN — sign-in, an OTP, a CAPTCHA, a permission
     * ---------------------------------------------------------------- */

    /**
     * The server says the next step is the owner's own (owner_step). The
     * bar shows what to do and its Stop becomes Continue; NOTHING on the
     * screen is read or touched until they tap it — they may be typing an
     * OTP. Stop stays on the bar beside it. The Dart loop polls
     * [ownerAnswer]; no screen is read while it does.
     */
    fun ownerWait(text: String) {
        ownerReply = ""
        main.post {
            pillText?.apply { this.text = text; maxLines = 4; maxWidth = dp(230) }
            pillStop?.apply {
                this.text = "Continue"
                setTextColor(Color.parseColor("#B9F6CA"))
                contentDescription = "Continue the task"
                setOnClickListener {
                    ownerReply = "continue"
                    workingLook("Carrying on…")
                }
            }
            pillExtra?.visibility = View.VISIBLE
        }
    }

    /** "continue", "stop", or "" while the owner is still on their step. */
    fun ownerAnswer(): String = when {
        stopRequested -> "stop"
        !running -> "stop"
        else -> ownerReply
    }

    /* ---------------------------------------------------------------- *
     * READING THE SCREEN
     * ---------------------------------------------------------------- */

    /**
     * One look. Besides the elements it says what the phone could see
     * ("access"): tree = ok | empty | no_root (the app gave the service no
     * window at all), and locked. The picture's own status (ok, black…) is
     * added by the bridge after captureScreen. With those the server can
     * say "this app hides its screen from assistants" in one look instead
     * of guessing for 20 seconds.
     */
    fun snapshot(): Map<String, Any?> {
        val t0 = SystemClock.uptimeMillis()
        val root = rootInActiveWindow
        // Fresh, not the cached copy from the app's splash screen.
        try { root?.refresh() } catch (_: Throwable) {}
        val pkg = root?.packageName?.toString() ?: ""
        val out = ArrayList<Map<String, Any?>>()
        val keep = ArrayList<AccessibilityNodeInfo>()
        val prints = ArrayList<Fp>()
        // A locked phone is not read at all: the lock screen shows the
        // owner's notifications. The server ends the run with a plain
        // "your phone locked partway".
        val locked = phoneLocked()
        // Nothing is read outside a run, or from an app the run may not
        // touch — the package name alone is enough to hand over.
        val ok = running && isAllowed(pkg) && !locked
        if (root != null && ok) {
            val dm = resources.displayMetrics
            val screenArea = dm.widthPixels.toLong() * dm.heightPixels.toLong()
            // The display size once per look, not once per element (it was
            // a WindowManager lookup for each of up to 300 elements).
            val (sw, sh) = screenSize()
            val w = Walk(out, keep, prints, screenArea, sw, sh)
            walk(root, false, -1, w)
            // The active window can be an empty layer over the app's real
            // content (seen with a food-delivery app, 2026-09-24: every
            // look came back blank while the app showed a full page).
            // Then read the app's own windows, top-most first.
            if (out.isEmpty()) {
                try {
                    for (win in windows.sortedByDescending { it.layer }) {
                        if (win.type != AccessibilityWindowInfo.TYPE_APPLICATION) continue
                        val r = win.root ?: continue
                        if (r.packageName?.toString() != pkg) continue
                        walk(r, false, -1, w)
                        if (out.isNotEmpty()) break
                    }
                } catch (_: Throwable) {}
            }
        }
        val tree = when {
            root == null -> "no_root"
            out.isEmpty() -> "empty"
            else -> "ok"
        }
        val lookMs = SystemClock.uptimeMillis() - t0
        // Counts and times only — what was on screen never goes to the log.
        Log.i(TAG, "look $pkg ok=$ok nodes=${out.size} tree=$tree locked=$locked ms=$lookMs " +
            "kids=${root?.childCount ?: -1} vis=${root?.isVisibleToUser} " +
            "windows=${try { windows.size } catch (_: Throwable) { -1 }}")
        byId = keep
        fps = prints
        return mapOf(
            "pkg" to pkg,
            "allowed" to ok,
            // A missing root is the app keeping the service out, not
            // "another screen took over" (what blockKind("") used to say).
            "block" to when {
                ok -> ""
                locked -> "locked"
                root == null -> "no_root"
                else -> blockKind(pkg)
            },
            "keyboard" to keyboardOpen(),
            "stop" to stopRequested,
            "nodes" to out,
            "access" to mapOf("tree" to tree, "locked" to locked),
            "look_ms" to lookMs,
        )
    }

    /** The whole display in pixels (bounds and screenshots use this). */
    private fun screenSize(): Pair<Int, Int> {
        if (Build.VERSION.SDK_INT >= 30) {
            val b = (getSystemService(WINDOW_SERVICE) as WindowManager).currentWindowMetrics.bounds
            if (b.width() > 0 && b.height() > 0) return b.width() to b.height()
        }
        val dm = resources.displayMetrics
        return dm.widthPixels to dm.heightPixels
    }

    private fun norm(r: Rect, w: Int, h: Int): List<Int> =
        listOf(r.left * 1000 / w, r.top * 1000 / h, r.right * 1000 / w, r.bottom * 1000 / h)
            .map { it.coerceIn(0, 1000) }

    /**
     * May this look take a picture? Only during a run, of an app the run
     * may touch, on an unlocked phone. Asked BEFORE the element walk so the
     * two can run at once; the bridge drops the picture if the walk then
     * finds another app in front.
     */
    fun mayPhotograph(): Boolean = running && !phoneLocked() && isAllowed(foreground())

    private val shotWorker = Executors.newSingleThreadExecutor()

    /**
     * One look's picture. [jpeg] is set only when [status] is "ok".
     * status: ok | black | failed | rate_limited | unsupported (none is the
     * bridge's, for a look taken without a picture). [grid]: the picture's
     * brightness in 24 × 48 cells, base64 — stays on the phone, where it
     * tells whether a picture-only app's screen changed.
     */
    class Shot(val jpeg: String?, val status: String, val ms: Long, val kb: Int, val grid: String? = null)

    private class Encoded(val jpeg: String, val kb: Int, val black: Boolean, val grid: String)

    /**
     * THE SCREEN AS THE OWNER SEES IT — a small JPEG (540 px wide), base64.
     * Android 11+ lets an accessibility service take it with the permission
     * already granted. Our own bar is made see-through for the shot so it
     * never covers what the planner needs to read (see-through, not
     * hidden: a hidden bar would drop its keep-the-screen-on flag for that
     * moment). Only called during a run, for an app the run may touch.
     *
     * A SECURE APP IS A BLACK PICTURE, NOT AN ERROR. Apps that forbid
     * screenshots (banking, payment sheets — FLAG_SECURE) are left out of
     * the display picture: it succeeds, and their area is pure black. That
     * black image used to go to the planner as if it were the screen, and
     * the owner heard "I got stuck on the same step" 20 seconds later. Now a
     * black picture is judged here (brightness), confirmed on Android 14+
     * by asking for that one window's picture (which Android refuses for a
     * secure window), and never uploaded: status "black".
     * "Too soon after the last one" is retried once, 350 ms later.
     *
     * The bar steps aside for two frames (postOnAnimation), not a fixed
     * 90 ms: long enough for the see-through bar to be on screen, about
     * 17-33 ms on a 60 Hz phone. The bridge says which picture was sent
     * (shotSent) — a picture that arrives after the look was answered, or
     * of a screen the look found off limits, never counts.
     */
    fun captureScreen(done: (Shot) -> Unit) {
        val t0 = SystemClock.uptimeMillis()
        fun finish(jpeg: String?, status: String, kb: Int = 0, grid: String? = null) {
            val ms = SystemClock.uptimeMillis() - t0
            // Counts and times only.
            Log.i(TAG, "shot $status ${kb}KB ms=$ms")
            done(Shot(if (status == "ok") jpeg else null, status, ms, kb, grid))
        }
        if (Build.VERSION.SDK_INT < 30) { finish(null, "unsupported"); return }
        fun take(first: Boolean) {
            try {
                takeScreenshot(android.view.Display.DEFAULT_DISPLAY, mainExecutor,
                    object : TakeScreenshotCallback {
                        override fun onSuccess(shot: ScreenshotResult) {
                            pill?.alpha = 1f
                            shotWorker.execute {
                                val enc = try { encode(shot) } catch (e: Throwable) {
                                    Log.w(TAG, "shot encode failed: ${e.javaClass.simpleName}")
                                    null
                                }
                                when {
                                    enc == null -> finish(null, "failed")
                                    !enc.black -> finish(enc.jpeg, "ok", enc.kb, enc.grid)
                                    Build.VERSION.SDK_INT >= 34 ->
                                        confirmBlack { secure ->
                                            if (secure) finish(null, "black", enc.kb, enc.grid)
                                            else finish(enc.jpeg, "ok", enc.kb, enc.grid)
                                        }
                                    else -> finish(null, "black", enc.kb, enc.grid)
                                }
                            }
                        }
                        override fun onFailure(errorCode: Int) {
                            val tooSoon = errorCode == ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT
                            // Once more, 350 ms later — the bar stays
                            // see-through meanwhile.
                            if (tooSoon && first) {
                                main.postDelayed({ take(false) }, 350)
                                return
                            }
                            pill?.alpha = 1f
                            if (tooSoon) {
                                finish(null, "rate_limited")
                            } else {
                                Log.i(TAG, "shot unavailable ($errorCode)")
                                finish(null, "failed")
                            }
                        }
                    })
            } catch (e: Throwable) {
                pill?.alpha = 1f
                Log.w(TAG, "shot refused: ${e.javaClass.simpleName}")
                finish(null, "failed")
            }
        }
        main.post {
            val bar = pill
            if (bar == null || !bar.isAttachedToWindow) { take(true); return@post }
            bar.alpha = 0f
            // Two frames: the first draws the see-through bar, the second
            // makes sure that frame is the one on screen.
            bar.postOnAnimation { bar.postOnAnimation { take(true) } }
        }
    }

    /**
     * Which picture went out with the look: its status (ok, black…), or
     * "none" for a look without one. A point on the picture (tap_xy) is
     * only tapped when it was a real one.
     */
    fun shotSent(status: String) {
        lastShot = status
    }

    /** A look taken without a picture (not allowed, or asked without). */
    fun noPicture() {
        lastShot = "none"
    }

    /**
     * Android 14+: is the black picture a SECURE window, or just a dark
     * screen? The active window's own picture answers it — Android refuses
     * that one with ERROR_TAKE_SCREENSHOT_SECURE_WINDOW for a secure window.
     * Anything unclear counts as secure: a near-black picture is no use to
     * the planner either way.
     */
    @android.annotation.TargetApi(34)
    private fun confirmBlack(done: (Boolean) -> Unit) {
        val windowId = try { rootInActiveWindow?.windowId ?: -1 } catch (_: Throwable) { -1 }
        if (windowId < 0) { done(true); return }
        // Android refuses two pictures less than ~333 ms apart.
        main.postDelayed({
            try {
                takeScreenshotOfWindow(windowId, mainExecutor, object : TakeScreenshotCallback {
                    override fun onSuccess(shot: ScreenshotResult) {
                        try { shot.hardwareBuffer.close() } catch (_: Throwable) {}
                        done(false)
                    }
                    override fun onFailure(errorCode: Int) {
                        if (errorCode != ERROR_TAKE_SCREENSHOT_SECURE_WINDOW) {
                            Log.i(TAG, "window shot unavailable ($errorCode)")
                        }
                        done(true)
                    }
                })
            } catch (e: Throwable) {
                Log.w(TAG, "window shot refused: ${e.javaClass.simpleName}")
                done(true)
            }
        }, 350)
    }

    private fun encode(shot: ScreenshotResult): Encoded? {
        val buffer = shot.hardwareBuffer
        val hw = Bitmap.wrapHardwareBuffer(buffer, shot.colorSpace) ?: run { buffer.close(); return null }
        val soft = hw.copy(Bitmap.Config.ARGB_8888, false)
        hw.recycle()
        buffer.close()
        val w = 540
        val h = (soft.height * (w / soft.width.toFloat())).toInt().coerceAtLeast(1)
        val small = Bitmap.createScaledBitmap(soft, w, h, true)
        if (small != soft) soft.recycle()
        // BLACK = a secure window. Only the band between the status bar
        // and the navigation bar is judged (those still draw over a secure
        // app), on a 6-px grid; "black" means 99% of it is pure black.
        // Counts only — what is on screen is never logged.
        val px = IntArray(w * h)
        small.getPixels(px, 0, w, 0, 0, w, h)
        var luma = 0L
        var dark = 0
        var n = 0
        var y = h * 6 / 100
        val yEnd = h * 92 / 100
        while (y < yEnd) {
            var x = 0
            while (x < w) {
                val c = px[y * w + x]
                val l = ((c shr 16 and 0xff) * 3 + (c shr 8 and 0xff) * 6 + (c and 0xff)) / 10
                luma += l
                if (l <= 8) dark++
                n++
                x += 6
            }
            y += 6
        }
        val black = n > 0 && dark * 100L >= n * 99L
        val grid = lumaGrid(px, w, h)
        val bos = ByteArrayOutputStream()
        small.compress(Bitmap.CompressFormat.JPEG, 60, bos)
        small.recycle()
        val kb = bos.size() / 1024
        Log.i(TAG, "shot ${w}x$h ${kb}KB luma=${if (n > 0) luma / n else -1} " +
            "dark=${if (n > 0) dark * 100 / n else -1}%")
        return Encoded(Base64.encodeToString(bos.toByteArray(), Base64.NO_WRAP), kb, black, grid)
    }

    /**
     * DID A PICTURE-ONLY APP'S SCREEN CHANGE? A hash of the JPEG said
     * "changed" whenever the status bar's clock ticked or a banner moved,
     * and never "the same" in an app with no element list — so a tap that
     * did nothing looked like progress (2026-09-24). This is the picture's
     * brightness in 24 × 48 cells (one byte each, base64), without the
     * status bar; the Dart loop compares two of them (gridChanged). It
     * never leaves the phone.
     */
    private fun lumaGrid(px: IntArray, w: Int, h: Int): String {
        val cols = 24
        val rows = 48
        val sums = LongArray(cols * rows)
        val counts = IntArray(cols * rows)
        val y0 = h * 5 / 100
        val band = (h - y0).coerceAtLeast(1)
        var y = y0
        while (y < h) {
            val row = ((y - y0) * rows / band).coerceAtMost(rows - 1)
            var x = 0
            while (x < w) {
                val col = (x * cols / w).coerceAtMost(cols - 1)
                val c = px[y * w + x]
                sums[row * cols + col] += ((c shr 16 and 0xff) * 3 + (c shr 8 and 0xff) * 6 + (c and 0xff)) / 10
                counts[row * cols + col]++
                x += 3
            }
            y += 3
        }
        val cells = ByteArray(cols * rows) { i ->
            (if (counts[i] > 0) sums[i] / counts[i] else 0L).toInt().toByte()
        }
        return Base64.encodeToString(cells, Base64.NO_WRAP)
    }

    private fun keyboardOpen(): Boolean = try {
        windows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
    } catch (_: Throwable) { false }

    /** Where the keyboard is on screen, or null when it is not up. */
    private fun imeBounds(): Rect? = try {
        windows.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            ?.let { w -> Rect().also { w.getBoundsInScreen(it) } }
            ?.takeIf { !it.isEmpty }
    } catch (_: Throwable) { null }

    /** One look's lists and sizes, handed down the walk. */
    private class Walk(
        val out: ArrayList<Map<String, Any?>>,
        val keep: ArrayList<AccessibilityNodeInfo>,
        val prints: ArrayList<Fp>,
        val screenArea: Long,
        val sw: Int,
        val sh: Int,
    ) {
        /** How many short buttons had their row's words read (capped per look). */
        var rows = 0
    }

    /**
     * The words an element is recognised by when it is acted on: its own
     * text or description, a card's merged label, and for a field its hint
     * (a field's text is what gets typed, and an empty one reads as its
     * hint). Digits are left out: a countdown or a price ticking on the
     * same card is still the same card.
     */
    private fun fpKey(n: AccessibilityNodeInfo, text: String, desc: String, label: String, hint: String): String =
        (if (n.isEditable) "field|$hint|$desc" else text.ifEmpty { desc }.ifEmpty { label })
            .filterNot { it.isDigit() }

    /**
     * A SHORT BUTTON'S ROW. Every dish row has its own "ADD"; the button
     * alone can't tell a reused row from the one the planner meant. So a
     * short tappable label (12 letters or less) is also known by the words
     * of the row around it — the nearest parent (up to 3 up) that says more
     * than the button itself. Digits left out, as in fpKey.
     */
    private fun rowWords(n: AccessibilityNodeInfo, own: String): String {
        if (n.isEditable || !n.isClickable || own.isEmpty() || own.length > 12) return ""
        var p = n.parent
        var up = 0
        while (p != null && up < 3) {
            val sb = StringBuilder()
            collectText(p, sb, 0)
            val words = sb.toString().trim()
            if (words.isNotEmpty() && words != own) return words.filterNot { it.isDigit() }
            p = p.parent
            up++
        }
        return ""
    }

    private fun walk(
        n: AccessibilityNodeInfo,
        insideCard: Boolean,
        clickUp: Int,
        w: Walk,
        depth: Int = 0,
    ) {
        val out = w.out
        val keep = w.keep
        if (out.size >= MAX_NODES || depth > 60) return
        val r = Rect()
        n.getBoundsInScreen(r)
        // AN INVISIBLE WRAPPER IS NOT AN EMPTY SCREEN. Some apps wrap the
        // whole page in a container that reports zero size or "not
        // visible" (seen 2026-09-24: every look at a food-delivery app came
        // back blank while it showed a full page). Skip listing it, but
        // always look inside.
        if (!n.isVisibleToUser || r.width() <= 0 || r.height() <= 0) {
            for (i in 0 until n.childCount) {
                val c = n.getChild(i) ?: continue
                walk(c, insideCard, clickUp, w, depth + 1)
                if (out.size >= MAX_NODES) return
            }
            return
        }

        val text = n.text?.toString()?.trim().orEmpty()
        val desc = n.contentDescription?.toString()?.trim().orEmpty()
        val hint = if (Build.VERSION.SDK_INT >= 26) n.hintText?.toString()?.trim().orEmpty() else ""
        val interactive = n.isClickable || n.isEditable || n.isScrollable || n.isCheckable
        // A tappable card collects its children's words into one label, so
        // "Paradise Biryani 4.4 · 30 mins" is ONE thing to tap. Not for
        // containers covering most of the screen — they would swallow it.
        val area = r.width().toLong() * r.height().toLong()
        val isCard = n.isClickable && !n.isEditable && area < w.screenArea * 2 / 5

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
                    // Where it is, 0-1000 across and down — so the planner
                    // can match the list to the screenshot.
                    "b" to norm(r, w.sw, w.sh),
                )
            )
            keep.add(n)
            val own = if (n.isPassword) "" else text
            val row = if (w.rows < ROW_WORDS_CAP && n.isClickable && own.ifEmpty { desc }.length in 1..12) {
                w.rows++
                rowWords(n, own.ifEmpty { desc })
            } else ""
            w.prints.add(Fp(fpKey(n, own, desc, label, hint), rid, cls, Rect(r), row))
        }
        for (i in 0 until n.childCount) {
            val c = n.getChild(i) ?: continue
            val up = if (n.isClickable && myId >= 0) myId else clickUp
            walk(c, insideCard || isCard, up, w, depth + 1)
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

    /* ---- STILL THE SAME ELEMENT? ------------------------------------- */

    /** [n]'s recognition words as it is now (the look's fpKey, recomputed). */
    private fun keyNow(n: AccessibilityNodeInfo): String {
        val text = if (n.isPassword) "" else n.text?.toString()?.trim().orEmpty()
        val desc = n.contentDescription?.toString()?.trim().orEmpty()
        val hint = if (Build.VERSION.SDK_INT >= 26) n.hintText?.toString()?.trim().orEmpty() else ""
        var label = ""
        if (!n.isEditable && n.isClickable && text.isEmpty() && desc.isEmpty()) {
            val r = Rect()
            n.getBoundsInScreen(r)
            val dm = resources.displayMetrics
            if (r.width().toLong() * r.height() < dm.widthPixels.toLong() * dm.heightPixels * 2 / 5) {
                label = StringBuilder().also { collectText(n, it, 0) }.toString().trim()
            }
        }
        return fpKey(n, text, desc, label, hint)
    }

    private fun clsOf(n: AccessibilityNodeInfo) = n.className?.toString()?.substringAfterLast('.') ?: ""
    private fun ridOf(n: AccessibilityNodeInfo) = n.viewIdResourceName?.substringAfterLast('/') ?: ""

    private fun near(a: Rect, b: Rect, px: Int) =
        kotlin.math.abs(a.left - b.left) <= px && kotlin.math.abs(a.top - b.top) <= px &&
            kotlin.math.abs(a.right - b.right) <= px && kotlin.math.abs(a.bottom - b.bottom) <= px

    /**
     * STALE ELEMENTS (2026-09-24). The planner answers 2-8 s after the
     * look; meanwhile a list row can be reused for another dish (images
     * loading, a banner arriving) and a tap on the look's element landed on
     * its neighbour. So the element is refreshed first: same words, same
     * view id, same place (within 40 px) — it is the one. Moved or
     * changed: it is looked for again on the screen as it is now, and used
     * only when exactly one element matches ("remapped"); two "ADD"s and
     * no way to tell which is the planner's dish is "stale_element" — the
     * planner looks again rather than guess.
     * Returns the element and "" / "remapped", or null and the error.
     */
    private fun current(id: Int?): Pair<AccessibilityNodeInfo?, String> {
        val n = id?.let { byId.getOrNull(it) } ?: return null to "no_such_element"
        val fp = fps.getOrNull(id) ?: return n to ""
        val alive = try { n.refresh() } catch (_: Throwable) { false }
        if (alive && n.isVisibleToUser) {
            val r = Rect()
            n.getBoundsInScreen(r)
            if (ridOf(n) == fp.rid && clsOf(n) == fp.cls && near(r, fp.box, 40) && keyNow(n) == fp.key &&
                rowNow(n, fp) == fp.row) {
                return n to ""
            }
        }
        val again = refind(fp)
        // Counts only — never the element's words.
        Log.i(TAG, "element $id ${if (again != null) "remapped" else "stale"}")
        return if (again != null) again to "remapped" else null to "stale_element"
    }

    /**
     * The one element on screen now with the same words, view id and class
     * (and row). The active window first; when it has none, the app's other
     * windows — the look reads those too when the active one is an empty
     * layer.
     */
    private fun refind(fp: Fp): AccessibilityNodeInfo? {
        val active = rootInActiveWindow ?: return null
        fun matches(root: AccessibilityNodeInfo) = visibleNodes(root).filter { c ->
            val r = Rect()
            c.getBoundsInScreen(r)
            !r.isEmpty && ridOf(c) == fp.rid && clsOf(c) == fp.cls
        }.filter { keyNow(it) == fp.key && rowNow(it, fp) == fp.row }
        val hits = matches(active)
        if (hits.isNotEmpty()) return hits.singleOrNull()
        val pkg = active.packageName?.toString() ?: return null
        val others = try {
            windows.filter { it.type == AccessibilityWindowInfo.TYPE_APPLICATION }
                .mapNotNull { it.root }
                .filter { it.packageName?.toString() == pkg && it.windowId != active.windowId }
        } catch (_: Throwable) { emptyList() }
        return others.flatMap { matches(it) }.singleOrNull()
    }

    /** The row's words around [n] now — only when the look read them. */
    private fun rowNow(n: AccessibilityNodeInfo, fp: Fp): String {
        if (fp.row.isEmpty()) return ""
        val own = if (n.isPassword) "" else n.text?.toString()?.trim().orEmpty()
        return rowWords(n, own.ifEmpty { n.contentDescription?.toString()?.trim().orEmpty() })
    }

    /* ---- THE KEYBOARD ------------------------------------------------ */

    /**
     * What closing the keyboard for a point did:
     *   CLEAR   — the keyboard was not over the point; nothing moved, so the
     *             element judged before is still under the point.
     *   CLOSED  — the keyboard WAS over the point and Back closed it. The
     *             page can slide into the space it held (adjustResize /
     *             adjustPan), so what is under the point may have changed:
     *             nothing is pressed there before it is read and judged
     *             again (tap_xy: not at all).
     *   COVERED — the keyboard is still over the point (give up).
     */
    private enum class KbClear { CLEAR, CLOSED, COVERED }

    /**
     * A finger under the keyboard types a letter instead of pressing what
     * the planner saw there. Back closes only the keyboard, not the page;
     * then the point is free — but see CLOSED above.
     */
    private fun clearKeyboardAt(x: Float, y: Float): KbClear {
        val kb = imeBounds() ?: return KbClear.CLEAR
        if (!kb.contains(x.toInt(), y.toInt())) return KbClear.CLEAR
        performGlobalAction(GLOBAL_ACTION_BACK)
        repeat(8) {
            Thread.sleep(80)
            val now = imeBounds()
            if (now == null || !now.contains(x.toInt(), y.toInt())) {
                // Let the page finish moving back into place.
                Thread.sleep(120)
                return KbClear.CLOSED
            }
        }
        return KbClear.COVERED
    }

    /** The smallest visible node covering the point, read from a fresh tree. */
    private fun nodeUnderNow(x: Float, y: Float): AccessibilityNodeInfo? {
        val root = rootInActiveWindow ?: return null
        return visibleNodes(root).filter {
            val r = Rect(); it.getBoundsInScreen(r); r.contains(x.toInt(), y.toInt())
        }.minByOrNull { val r = Rect(); it.getBoundsInScreen(r); r.width().toLong() * r.height() }
    }

    /**
     * AFTER THE KEYBOARD CLOSED the page slides (adjustResize / adjustPan):
     * a bar anchored to the bottom — a chat's Send, a cart's Pay — drops
     * into the space the keyboard held. Whatever sits under the point NOW
     * is judged, on a fresh tree, exactly like a tap on it would be, before
     * any finger lands there. Null: nothing there crosses a line.
     */
    private fun judgePointNow(x: Float, y: Float, fg: String): String? {
        val u = nodeUnderNow(x, y) ?: return null
        var t: AccessibilityNodeInfo? = u
        while (t != null && !t.isClickable) t = t.parent
        return judgeTap(u, t, fg)
    }

    /** A long press is refused on money and on deleting words. */
    private fun pressVeto(words: List<String>): String? = when {
        words.any { PAY.containsMatchIn(it) || MONEY.containsMatchIn(it) } -> "payment"
        words.any { DESTRUCTIVE.containsMatchIn(it) } -> "destructive"
        else -> null
    }

    /** The same, for whatever sits under the point now (fresh tree). */
    private fun pressVetoAt(x: Float, y: Float): String? {
        val u = nodeUnderNow(x, y) ?: return null
        var t: AccessibilityNodeInfo? = u
        while (t != null && !t.isLongClickable && !t.isClickable) t = t.parent
        return pressVeto(tapWords(t ?: u))
    }

    /**
     * [n] read again after the keyboard closed, with its new place in
     * [r]. False: it is gone or hidden — the planner looks again rather
     * than a finger landing on its old spot.
     */
    private fun movedTo(n: AccessibilityNodeInfo, r: Rect): Boolean {
        val alive = try { n.refresh() } catch (_: Throwable) { false }
        if (!alive || !n.isVisibleToUser) return false
        n.getBoundsInScreen(r)
        return !r.isEmpty
    }

    /* ---- TYPING THAT APPS REACT TO ----------------------------------- */

    /**
     * A search box (or a search bar that opens one): Enter searches, typing
     * should show results. A field is judged by its hint, id and label —
     * never its text, which is what was typed; a bar that is a button also
     * by the words it shows ("Search for dishes").
     */
    private fun searchLike(n: AccessibilityNodeInfo): Boolean =
        SUBMITTABLE.containsMatchIn(
            fieldWords(n) + " " + (if (n.isEditable) "" else n.text ?: "") + " " + (n.className ?: ""))

    /**
     * Does the field hold [text]? Compared on letters and digits only, so
     * a phone number shown as "98765 43210" or a date the field formats
     * still counts. An empty field's hint is not text.
     */
    private fun holds(n: AccessibilityNodeInfo, text: String): Boolean {
        if (text.isEmpty()) return true
        val shown = if (Build.VERSION.SDK_INT >= 26 && n.isShowingHintText) "" else n.text?.toString().orEmpty()
        if (shown == text || shown.contains(text)) return true
        val k = { s: String -> s.lowercase().filter { it.isLetterOrDigit() } }
        val want = k(text)
        return want.isNotEmpty() && k(shown).contains(want)
    }

    /** Waits up to [ms] after the text was set for the field's app to answer it. */
    private fun appReacted(ms: Long): Boolean {
        while (SystemClock.uptimeMillis() - typedAt < ms) {
            if (reactedAt >= typedAt) return true
            if (stopRequested) return false
            Thread.sleep(40)
        }
        return reactedAt >= typedAt
    }

    /**
     * TYPED THE WAY THE KEYBOARD TYPES (Android 13+). Some apps ignore
     * text that is set straight into a field: Instagram's search showed no
     * results for set text while real typing worked (2026-09-24). Set text
     * swaps the field's whole text; a keyboard edits it in place, through
     * the field's own input connection, and that is what the app listens
     * to. This service has its own input method (flagInputMethodEditor in
     * hari_automation.xml) on that same connection: the field is selected,
     * emptied and the text committed, exactly as a keyboard would. The
     * owner's clipboard is never touched (the paste below needs it, and on
     * Android 10+ it cannot be read back from the background).
     *
     * Only into [n], and only while [n] holds the input focus — never into
     * whatever field happens to be focused. Never text with a line break:
     * in a chat a committed Enter can send. False: not possible here (older
     * Android, no connection, focus elsewhere); the caller falls back.
     */
    private fun retype(n: AccessibilityNodeInfo, text: String): Boolean {
        if (Build.VERSION.SDK_INT < 33) return false
        if (text.isEmpty() || text.contains('\n') || text.contains('\r')) return false
        val im = try { inputMethod } catch (_: Throwable) { null } ?: return false
        val pkg = n.packageName?.toString() ?: return false
        // The connection starts a moment after the field takes the focus.
        var found: InputMethod.AccessibilityInputConnection? = null
        val until = SystemClock.uptimeMillis() + 400
        while (found == null) {
            if (stopRequested) return false
            val focus = try { findFocus(AccessibilityNodeInfo.FOCUS_INPUT) } catch (_: Throwable) { null }
            if (focus == n && im.currentInputStarted && im.currentInputEditorInfo?.packageName == pkg) {
                found = im.currentInputConnection
            }
            if (found == null) {
                if (SystemClock.uptimeMillis() >= until) return false
                Thread.sleep(40)
            }
        }
        val ic = found ?: return false
        try {
            ic.performContextMenuAction(android.R.id.selectAll)
            // Emptied first, then typed: an app that skips a query equal
            // to the last one still sees the text arrive.
            ic.commitText("", 1, null)
            // An editor that ignores "select all" still holds the text set
            // before: whatever is left around the cursor is deleted too
            // (editors clamp to what is there), so the text is never typed
            // twice ("raviravi" would still pass holds(), which looks for
            // the text inside the field).
            ic.deleteSurroundingText(10_000, 10_000)
            ic.commitText(text, 1, null)
            // A read on the same connection comes back only after the
            // edits above are done — so the field is checked after them.
            ic.getSurroundingText(text.length + 64, 64, 0)
        } catch (e: Throwable) {
            Log.w(TAG, "retype failed: ${e.javaClass.simpleName}")
            return false
        }
        val end = SystemClock.uptimeMillis() + 400
        while (true) {
            try { n.refresh() } catch (_: Throwable) {}
            if (holds(n, text)) return true
            if (SystemClock.uptimeMillis() >= end) return false
            Thread.sleep(40)
        }
    }

    /**
     * PASTE, THE WAY A FINGER DOES — the fallback where the keyboard's way
     * above is not possible (Android 12 and older). A paste also goes
     * through the field's own editing, so the app sees it as typed. The
     * field is cleared (or selected), the text pasted from the clipboard,
     * and the owner's clipboard put back exactly as it was.
     *
     * Android 10+ (API 29) lets a background service neither read nor
     * reliably restore the primary clip. When the owner's clip cannot be
     * read we do NOT touch the clipboard: overwriting it would wipe whatever
     * they copied (and leave our text — sometimes owner details — behind,
     * including in the keyboard's clipboard history). We skip the paste and
     * report UNAVAILABLE so the planner submits or taps a suggestion instead
     * (rule 3b); by then ACTION_SET_TEXT has already put the text in the
     * field.
     */
    private enum class PasteResult { OK, FAILED, UNAVAILABLE }

    private fun paste(n: AccessibilityNodeInfo, text: String): PasteResult {
        val cm = getSystemService(CLIPBOARD_SERVICE) as? ClipboardManager ?: return PasteResult.UNAVAILABLE
        // Only use the clipboard when the owner's clip can be read back, so
        // it is always restored. A null clip means either the background
        // restriction hid it or it is empty; either way, overwriting what we
        // cannot put back is not allowed.
        val saved = try { cm.primaryClip } catch (_: Throwable) { null } ?: return PasteResult.UNAVAILABLE
        var pasted = false
        try {
            val clip = ClipData.newPlainText("", text)
            if (Build.VERSION.SDK_INT >= 33) {
                // No preview of it in the clipboard pop-up.
                clip.description.extras = PersistableBundle().apply {
                    putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
                }
            }
            cm.setPrimaryClip(clip)
            n.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
            n.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, "")
            })
            n.refresh()
            // Whatever is left (set-text refused) is selected, so the paste
            // replaces it.
            val left = if (Build.VERSION.SDK_INT >= 26 && n.isShowingHintText) 0 else n.text?.length ?: 0
            if (left > 0) {
                n.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, left)
                })
            }
            pasted = n.performAction(AccessibilityNodeInfo.ACTION_PASTE)
            n.refresh()
        } catch (e: Throwable) {
            Log.w(TAG, "paste failed: ${e.javaClass.simpleName}")
        } finally {
            // Always put the owner's clip back exactly as it was.
            try { cm.setPrimaryClip(saved) } catch (_: Throwable) {}
        }
        return if (pasted) PasteResult.OK else PasteResult.FAILED
    }

    /* ---- SCROLLING --------------------------------------------------- */

    /** A list that runs sideways (a chip row, a banner carousel). */
    private fun sideways(n: AccessibilityNodeInfo, r: Rect): Boolean {
        val cls = n.className?.toString().orEmpty()
        if (cls.contains("Horizontal") || cls.contains("ViewPager") || cls.contains("Carousel")) return true
        val ci = n.collectionInfo
        if (ci != null && ci.rowCount == 1 && ci.columnCount > 1) return true
        return r.height() * 2 <= r.width()
    }

    /**
     * "Scroll down" means the page: the largest list that runs up and
     * down. The first scrollable in the tree was usually the filter-chip
     * row or the banner at the top, so "scroll down" moved chips sideways
     * and reported success.
     */
    private fun pageScrollable(): AccessibilityNodeInfo? {
        val all = byId.mapNotNull { n ->
            if (!n.isScrollable || !n.isVisibleToUser) return@mapNotNull null
            val r = Rect()
            n.getBoundsInScreen(r)
            if (r.isEmpty) null else n to r
        }
        val upDown = all.filter { (n, r) -> !sideways(n, r) }
        return (upDown.ifEmpty { all }).maxByOrNull { (_, r) -> r.width().toLong() * r.height() }?.first
    }

    /** The list scrolled by its own up/down action, else forward/back. */
    private fun scrollList(target: AccessibilityNodeInfo, forward: Boolean): Boolean {
        if (Build.VERSION.SDK_INT >= 23) {
            val upDown = if (forward) AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_DOWN
            else AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_UP
            if (target.actionList.any { it.id == upDown.id } && target.performAction(upDown.id)) return true
        }
        return target.performAction(
            if (forward) AccessibilityNodeInfo.ACTION_SCROLL_FORWARD else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)
    }

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

    /**
     * A Settings row's title: its own words, or the first part of the
     * card's merged words ("System · Languages, gestures, time, backup" is
     * judged as "System").
     */
    private fun rowTitle(n: AccessibilityNodeInfo): String = ownLabel(n).ifEmpty {
        StringBuilder().also { collectText(n, it, 0) }.toString().substringBefore(" · ").trim()
    }

    private fun securityRow(fg: String, title: String): Boolean =
        fg in SETTINGS_APPS && SECURITY_SETTING.containsMatchIn(title)

    /**
     * The kind of line a tap on [n] would cross, or null. [target] is what
     * the click would really press: n itself, the button around it, or
     * null when nothing above it is tappable. (The server's checkAction
     * for a tap, on the same words.)
     */
    private fun judgeTap(n: AccessibilityNodeInfo, target: AccessibilityNodeInfo?, fg: String): String? {
        // A BARE PRICE ON WHAT THE TAP PRESSES is a buy button, in any
        // app (a game's "₹89.00"): the element when it is tappable, else
        // the button around it — and when that says nothing itself, the
        // price tapped inside it. "₹99" on a dish card that says more, or
        // with nothing tappable around it, is a label.
        if (target != null) {
            val says = ownLabel(target).ifEmpty { cardLabel(target) }.ifEmpty { ownLabel(n) }
            if (PRICE_ONLY.matches(says)) return "payment"
        }
        for (judged in listOfNotNull(n, target).distinct()) {
            val words = tapWords(judged)
            val merged = StringBuilder().also { collectText(judged, it, 0) }.toString()
            if (PAY.containsMatchIn(merged)) return "payment"
            judgeWords(words, fg, button = n)?.let { return it }
            if (judged.isCheckable && CONSENT.containsMatchIn(merged)) return "consent"
            if (securityRow(fg, rowTitle(judged))) return "security"
        }
        return null
    }

    /**
     * [prices]: a bare price counts in any app (the planner's own words
     * for a point it taps). [button]: the element tapped, for the install
     * check (null for a point).
     */
    private fun judgeWords(words: List<String>, fg: String, prices: Boolean = false,
                           button: AccessibilityNodeInfo? = null): String? {
        val w = words.filter { it.isNotBlank() }
        val store = fg in STORES
        if (w.any { PAY.containsMatchIn(it) } ||
            ((store || prices) && w.any { PRICE_ONLY.matches(it) }) ||
            (store && w.any { STORE_PAY.containsMatchIn(it) })) return "payment"
        if (w.any { MONEY.containsMatchIn(it) }) return "money"
        if (store && w.any { INSTALL_BUTTON.matches(it) } && !installAsked(button)) return "install"
        if (w.any { PUBLISH.matches(it) }) return "publish"
        // On a compose screen a social app's "Share" / "Reply" publishes
        // (in a chat app it sends); from the feed it only opens a box.
        if (fg in MESSAGING && w.any { COMPOSE_SUBMIT.matches(it) } && composeScreen()) {
            return if (fg in SOCIAL_APPS) "publish" else "message_send"
        }
        if (w.any { SEND_BUTTON.matches(it) }) return "message_send"
        if (fg in MESSAGING && w.any { SEND.matches(it) }) return "message_send"
        if (w.any { DESTRUCTIVE.containsMatchIn(it) && !SAFE_CLEAR.matches(it) }) return "destructive"
        if (fg in SETTINGS_APPS && w.any { DISABLE_APP.matches(it) }) return "destructive"
        if (w.any { CONSENT.containsMatchIn(it) }) return "consent"
        return null
    }

    /**
     * A tappable card's merged words — what the snapshot sends as its
     * label (walk's isCard: tappable, not a field, under 2/5 of the
     * screen). A bigger container has none: it would swallow the screen.
     */
    private fun cardLabel(n: AccessibilityNodeInfo): String {
        if (!n.isClickable || n.isEditable) return ""
        val r = Rect()
        n.getBoundsInScreen(r)
        val dm = resources.displayMetrics
        val area = r.width().toLong() * r.height().toLong()
        if (area >= dm.widthPixels.toLong() * dm.heightPixels.toLong() * 2 / 5) return ""
        return StringBuilder().also { collectText(n, it, 0) }.toString().trim()
    }

    /**
     * A compose screen in a social or messaging app (the server's
     * composeScreen): a caption, reply or comment box, a box that holds
     * text (not a search box), or a "New post" heading.
     */
    private fun composeScreen(): Boolean = byId.any { n ->
        if (n.isEditable) {
            val f = fieldWords(n)
            !SEARCH_FIELD.containsMatchIn(f) &&
                (!n.text?.toString().isNullOrBlank() || COMPOSE_FIELD.containsMatchIn(f))
        } else {
            val t = ownLabel(n)
            t.isNotEmpty() && t.length <= 40 && COMPOSE_TEXT.containsMatchIn(t)
        }
    }

    /**
     * May Install / Update be pressed here (the server's installAsked)?
     * Only when the owner asked to install an app — and, when the server
     * named it (install_app), only that app's button: a result card that
     * names it and is not an ad, or its own page, whose heading starts
     * with its name. "Download my invoice" names no app; an ad beside it
     * is someone else's. Without a name (an older server) may_install
     * alone decides, as before.
     */
    private fun installAsked(button: AccessibilityNodeInfo?): Boolean {
        if (!mayInstall) return false
        val want = installWant
        if (want.isEmpty()) return true
        if (want.length < 2) return false
        // The smallest card around the button, when it sits in one.
        var p = button?.parent
        var depth = 0
        while (p != null && depth < 12) {
            val parts = cardLabel(p).split(PARTS).filter { it.isNotBlank() }
            if (parts.size > 1) {
                return parts.none { AD_PART.matches(it.trim()) } && parts.any { norm(it).startsWith(want) }
            }
            p = p.parent
            depth++
        }
        // The app's own page: a short heading that starts with its name
        // ("Zomato: Food Delivery & Dining").
        return byId.any {
            val t = ownLabel(it)
            t.isNotEmpty() && t.length <= 60 && norm(t).startsWith(want)
        }
    }

    /** Words of the screen just read that say "enter the OTP". */
    private fun otpScreen(): Boolean = byId.any {
        val t = ownLabel(it)
        t.isNotEmpty() && t.length <= 120 && OTP_SCREEN.containsMatchIn(t)
    }

    /**
     * May the keyboard's Enter be pressed in this field? Only where Enter
     * searches. In a chat, a comment box or the shade's reply it SENDS —
     * that tap stays the owner's.
     */
    private fun maySubmit(n: AccessibilityNodeInfo, fg: String): Boolean =
        fg !in MESSAGING && fg != SYSTEMUI &&
            SUBMITTABLE.containsMatchIn(fieldWords(n) + " " + (n.className ?: ""))

    fun act(a: Map<String, Any?>): Map<String, Any?> {
        if (stopRequested) return mapOf("ok" to false, "error" to "stopped", "stop" to true)
        if (!running) return fail("not_running")
        // Nothing is done on a locked phone; the next look reports it.
        if (phoneLocked()) return fail("locked")
        val fg = foreground()
        val type = a["type"] as? String ?: return fail("no_type")
        // The settle after this step waits for THIS action's effect.
        actedAt = SystemClock.uptimeMillis()
        // In the shade, SystemUI is the screen; elsewhere its clock is noise.
        watchSystemUi = type == "notifications" || type == "quick_settings" || fg == SYSTEMUI
        // Moving around the phone (Home, Back, opening an app, the shade)
        // is fine from anywhere; touching a screen needs it to be allowed.
        val global = type in setOf("home", "back", "recents", "notifications",
            "quick_settings", "open_app", "wait", "screenshot")
        if (!global && !isAllowed(fg)) return fail("not_allowed:$fg")

        val id = (a["id"] as? Number)?.toInt()
        val node = id?.let { byId.getOrNull(it) }

        return when (type) {
            "tap" -> {
                // Still the element the planner saw — or found again.
                val (n, how0) = current(id)
                if (n == null) return fail(how0)
                var target: AccessibilityNodeInfo? = n
                while (target != null && !target.isClickable) target = target.parent
                // Judged on what the click would ACTUALLY press: "₹312"
                // is harmless text, its parent "Proceed to Pay" is not.
                judgeTap(n, target, fg)?.let { return blocked(it) }
                val ok = target?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true
                val done = if (ok) mapOf("ok" to true, "how" to "click") else {
                    val r = Rect(); n.getBoundsInScreen(r)
                    when (clearKeyboardAt(r.exactCenterX(), r.exactCenterY())) {
                        KbClear.COVERED -> return fail("under_keyboard")
                        // The page slid when the keyboard closed: the finger
                        // must land on THIS element at its new place, not on
                        // whatever dropped into its old spot. It is judged
                        // again, and so is whatever now sits on top at its
                        // new centre (a bar that slid over it).
                        KbClear.CLOSED -> {
                            if (!movedTo(n, r)) return fail("keyboard_closed")
                            judgeTap(n, target, fg)?.let { return blocked(it) }
                            judgePointNow(r.exactCenterX(), r.exactCenterY(), fg)?.let { return blocked(it) }
                        }
                        KbClear.CLEAR -> {}
                    }
                    if (r.isEmpty) fail("tap_failed")
                    else if (tapAt(r.exactCenterX(), r.exactCenterY())) mapOf("ok" to true, "how" to "gesture")
                    else fail("tap_failed")
                }
                if (how0 == "remapped") done + ("remapped" to true) else done
            }
            // A point on the screenshot, for what the element list lacks.
            // Judged twice: the planner's own words for it, and whatever
            // element sits under the point.
            "tap_xy" -> {
                // A point needs a picture: with a black (secure), missing
                // or failed picture the planner is aiming at nothing.
                if (lastShot != "ok") return fail("no_picture")
                val (sw, sh) = screenSize()
                val x = ((a["x"] as? Number)?.toFloat() ?: return fail("no_point")) * sw / 1000f
                val y = ((a["y"] as? Number)?.toFloat() ?: return fail("no_point")) * sh / 1000f
                val said = (a["label"] as? String).orEmpty()
                // "Send button", "the Pay icon" are "Send" and "Pay".
                val bare = said.replace(Regex("^\\s*(?:the|a|an)\\s+", RegexOption.IGNORE_CASE), "")
                    .replace(Regex("\\s+(?:button|icon|arrow|key|tab|option|link)s?\\s*$", RegexOption.IGNORE_CASE), "")
                    .trim()
                // Its words are what the finger presses: a bare price counts.
                judgeWords(listOf(said, bare), fg, prices = true)?.let { return blocked(it) }
                if (securityRow(fg, said)) return blocked("security")
                val under = byId.filter {
                    val r = Rect(); it.getBoundsInScreen(r); r.contains(x.toInt(), y.toInt())
                }.minByOrNull { val r = Rect(); it.getBoundsInScreen(r); r.width().toLong() * r.height() }
                if (under != null) {
                    var t: AccessibilityNodeInfo? = under
                    while (t != null && !t.isClickable) t = t.parent
                    judgeTap(under, t, fg)?.let { return blocked(it) }
                }
                // Under the keyboard the finger would type a letter: Back
                // closes the keyboard first.
                when (clearKeyboardAt(x, y)) {
                    KbClear.COVERED -> return fail("under_keyboard")
                    // The keyboard closed and the page slid (adjustResize /
                    // adjustPan): a bottom-anchored Send, Pay or cart bar can
                    // drop into the space the keyboard held. The point was
                    // aimed at the picture, where the KEYBOARD was drawn —
                    // whatever is under it now, the planner never saw. So no
                    // finger lands: "keyboard_closed", and the next look
                    // shows the page as it is. (Before, the tap landed
                    // unchecked, and a chat's Send that slid into place went
                    // without the owner's tap.)
                    KbClear.CLOSED -> return fail("keyboard_closed")
                    KbClear.CLEAR -> {}
                }
                if (tapAt(x, y)) mapOf("ok" to true, "how" to "point") else fail("tap_failed")
            }
            "type" -> {
                // The notification shade's inline Reply sends what is typed
                // there — no typing in it at all.
                if (fg == SYSTEMUI) return blocked("message_send")
                val (picked, how0) = current(id)
                var n = picked ?: return fail(how0)
                val text = (a["text"] as? String).orEmpty()
                var how = "set_text"
                // A SEARCH BAR THAT IS REALLY A BUTTON (food and shop home
                // pages): it opens the search page. Tap it — judged like any
                // tap — and type into the field that takes the cursor, in
                // one step instead of a failed "not_a_field" and another.
                if (!n.isEditable) {
                    if (!searchLike(n)) return fail("not_a_field")
                    var target: AccessibilityNodeInfo? = n
                    while (target != null && !target.isClickable) target = target.parent
                    judgeTap(n, target, fg)?.let { return blocked(it) }
                    if (target?.performAction(AccessibilityNodeInfo.ACTION_CLICK) != true) return fail("not_a_field")
                    var field: AccessibilityNodeInfo? = null
                    val until = SystemClock.uptimeMillis() + 1500
                    while (field == null && SystemClock.uptimeMillis() < until) {
                        Thread.sleep(100)
                        field = try { findFocus(AccessibilityNodeInfo.FOCUS_INPUT) } catch (_: Throwable) { null }
                            ?.takeIf { it.isEditable && isAllowed(it.packageName?.toString() ?: "") }
                    }
                    n = field ?: return fail("not_a_field")
                    how = "tap_type"
                }
                if (n.isPassword || CREDENTIAL.containsMatchIn(fieldWords(n)) ||
                    CARD_NUMBER.containsMatchIn(text)) return blocked("credential")
                // OTP boxes usually carry no label: a code-shaped number, or
                // any unlabeled field, on a screen that asks for the OTP is
                // the owner's to type.
                if ((OTP_DIGITS.matches(text) || fieldWords(n).isBlank()) && otpScreen()) {
                    return blocked("credential")
                }
                n.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
                val args = Bundle().apply {
                    putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
                }
                // Watch the field's app answer the text (reactedAt).
                typingPkg = n.packageName?.toString().orEmpty()
                typedAt = SystemClock.uptimeMillis()
                val set = n.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                n.refresh()
                // Verified, not assumed: the field must now hold the text.
                var verified = set && holds(n, text)
                // TYPING THAT APPS REACT TO (2026-09-24). A field that
                // refused the text, or a search box whose app did not answer
                // it within ~600 ms (no results, no suggestions), gets the
                // text again the way a keyboard types it — what Instagram's
                // search needed. Through the keyboard's connection first (no
                // clipboard); else pasted, only when the owner's clipboard
                // can be put back exactly as it was.
                val retypeNeeded = text.isNotEmpty() && (!verified || (searchLike(n) && !appReacted(600)))
                if (retypeNeeded) {
                    if (retype(n, text)) {
                        how = if (how == "tap_type") "tap_retype" else "retype"
                        verified = true
                    } else when (paste(n, text)) {
                        PasteResult.OK -> {
                            how = if (how == "tap_type") "tap_paste" else "paste"
                            verified = holds(n, text)
                        }
                        // Neither way could be used without destroying the
                        // owner's clip, so nothing more was done. The text
                        // set by ACTION_SET_TEXT stays; the planner is told
                        // (it sees "paste_unavailable") so it submits or taps
                        // a suggestion (rule 3b) instead of waiting for
                        // suggestions that set text did not bring.
                        PasteResult.UNAVAILABLE -> if (verified) how = "paste_unavailable"
                        PasteResult.FAILED -> {}
                    }
                }
                typingPkg = ""
                var submitted = false
                var submitRefused = false
                if (verified && a["submit"] == true) {
                    // Enter only where it searches; elsewhere it can send.
                    // The text stays typed and the planner is told, so it
                    // taps the screen's own search button instead.
                    if (!maySubmit(n, fg)) submitRefused = true
                    else if (Build.VERSION.SDK_INT >= 30) {
                        submitted = n.performAction(
                            AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
                    }
                }
                var done = if (!verified) fail("text_not_set")
                else if (submitRefused) {
                    mapOf("ok" to true, "verified" to true, "submitted" to false, "submit_refused" to true)
                } else mapOf("ok" to true, "verified" to true, "submitted" to submitted)
                // How it was typed, when not the plain way (the planner's
                // history shows it): typed again the keyboard's way, pasted,
                // set but not answered (paste_unavailable), or a search bar
                // tapped first. It rides in "how" — the one field the loop
                // and the server pass on to the planner.
                if (how != "set_text") done = done + ("how" to how)
                if (how0 == "remapped") done + ("remapped" to true) else done
            }
            "scroll" -> {
                val forward = (a["direction"] as? String) != "up"
                var target: AccessibilityNodeInfo? = node
                while (target != null && !target.isScrollable) target = target.parent
                // No element named: the page itself, not a chip row.
                if (target == null) target = pageScrollable()
                if (target != null && scrollList(target, forward)) mapOf("ok" to true, "how" to "scroll")
                else if (dragScroll(forward)) mapOf("ok" to true, "how" to "gesture")
                else fail("scroll_failed")
            }
            "long_press" -> {
                val (picked, how0) = current(id)
                val n = picked ?: return fail(how0)
                var target: AccessibilityNodeInfo? = n
                while (target != null && !target.isLongClickable && !target.isClickable) target = target.parent
                pressVeto(tapWords(target ?: n))?.let { return blocked(it) }
                val done = if (target?.performAction(AccessibilityNodeInfo.ACTION_LONG_CLICK) == true) {
                    mapOf("ok" to true, "how" to "long_click")
                } else {
                    val r = Rect(); n.getBoundsInScreen(r)
                    when (clearKeyboardAt(r.exactCenterX(), r.exactCenterY())) {
                        KbClear.COVERED -> return fail("under_keyboard")
                        // The page slid when the keyboard closed: press THIS
                        // element at its new place, judged again — and so is
                        // whatever now sits on top at its new centre — not
                        // whatever dropped into its old spot.
                        KbClear.CLOSED -> {
                            if (!movedTo(n, r)) return fail("keyboard_closed")
                            pressVeto(tapWords(target ?: n))?.let { return blocked(it) }
                            pressVetoAt(r.exactCenterX(), r.exactCenterY())?.let { return blocked(it) }
                        }
                        KbClear.CLEAR -> {}
                    }
                    if (r.isEmpty) fail("long_press_failed")
                    else if (pressAt(r.exactCenterX(), r.exactCenterY())) mapOf("ok" to true, "how" to "gesture")
                    else fail("long_press_failed")
                }
                if (how0 == "remapped") done + ("remapped" to true) else done
            }
            "swipe" -> if (swipeDir((a["direction"] as? String) ?: "up")) mapOf("ok" to true) else fail("swipe_failed")
            "open_app" -> {
                val name = (a["name"] as? String).orEmpty()
                val hit = matchLauncherApp(packageManager, name) ?: return fail("app_not_found")
                if (hit.first in MONEY_APPS) return blocked("payment")
                if (never(hit.first) || hit.first == packageName) return blocked("blocked_app")
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

    /**
     * WAIT FOR THE ACTION'S EFFECT, NOT FOR SILENCE (2026-09-24). The old
     * wait ended as soon as the phone had been quiet for a moment — ~280 ms
     * after a tap whose result was still on its way (ADD → the cart bar
     * 0.4-1.5 s later), so the old screen was read and the planner tapped
     * again; and on a screen that never stops moving (a carousel, a video,
     * the keyboard's strip) it always ran to its 4-6 s cap.
     *
     * With [expectMs] > 0 it waits for a change AFTER the last action:
     *   none   — nothing changed within [expectMs] of the action
     *   quiet  — it changed, then stayed still for [quietMs]
     *   stable — it keeps moving, but no window has come or gone for
     *            900 ms and 600 ms have passed: the page is there, only
     *            its content ticks
     *   cap    — [maxMs] reached
     *   stop   — the owner pressed Stop
     * With [expectMs] 0 (waiting for a screen to calm down, not for an
     * action): quiet for [quietMs], or stable, or the cap. Never done
     * before [minMs]. Calls back on the UI thread with (ms, reason).
     */
    fun settle(quietMs: Long, maxMs: Long, expectMs: Long = 0, minMs: Long = 250,
               done: (Long, String) -> Unit) {
        val start = SystemClock.uptimeMillis()
        val acted = actedAt
        // What "after" means: the action just done — or this call.
        val from = if (expectMs > 0 && acted > 0 && start - acted in 0..15_000) acted else start
        val tick = object : Runnable {
            override fun run() {
                val now = SystemClock.uptimeMillis()
                val waited = now - start
                val saw = lastChangeAt > from
                val reason = when {
                    stopRequested || !running -> "stop"
                    waited >= maxMs -> "cap"
                    waited < minMs -> null
                    expectMs > 0 && !saw -> if (now - from >= expectMs) "none" else null
                    now - lastChangeAt >= quietMs -> "quiet"
                    now - lastStateAt >= 900 && now - from >= 600 -> "stable"
                    else -> null
                }
                if (reason != null) done(waited, reason) else main.postDelayed(this, 80)
            }
        }
        main.postDelayed(tick, 100)
    }

    /**
     * WAIT FOR THE APP, NOT THE CLOCK (2026-09-24). After opening an app the
     * first look used to wait a fixed 700 ms of silence (up to 6 s) and then
     * poll 20 × 300 ms for the app to come to the front — 5-11 s before the
     * first tap. Now: as soon as [pkg] (empty: any app but this one) is in
     * front and drawn — at least 8 elements and a quarter second of calm, or
     * 600 ms of calm, or an app with no element list that has been in front
     * for 1.2 s. Another app in front for 1.2 s (a permission pop-up, an
     * "open with" chooser) is the loop's to judge. Blocking: call it on a
     * worker thread. Counts and times only.
     */
    fun waitForApp(pkg: String, maxMs: Long): Map<String, Any?> {
        val start = SystemClock.uptimeMillis()
        var front = ""
        var frontSince = start
        var nodes = 0
        while (true) {
            val now = SystemClock.uptimeMillis()
            val reason: String? = when {
                stopRequested || !running -> "stop"
                phoneLocked() -> "locked"
                else -> {
                    val fg = foreground()
                    if (fg != front) { front = fg; frontSince = now }
                    val inFront = now - frontSince
                    val calm = now - lastChangeAt
                    val other = fg.isNotEmpty() && fg != packageName
                    if (other && (pkg.isEmpty() || fg == pkg)) {
                        nodes = countDrawn(8)
                        when {
                            nodes >= 8 && calm >= 250 -> "drawn"
                            nodes > 0 && calm >= 600 && inFront >= 600 -> "quiet"
                            nodes == 0 && inFront >= 1200 -> "no_list"
                            else -> null
                        }
                    } else if (other && inFront >= 1200) "other" else null
                }
            }
            val waited = now - start
            if (reason != null || waited >= maxMs) {
                val why = reason ?: "cap"
                Log.i(TAG, "app ready=$why ms=$waited nodes=$nodes")
                return mapOf("ok" to (why != "cap" && why != "stop" && why != "locked"), "reason" to why,
                    "ms" to waited, "pkg" to front)
            }
            Thread.sleep(120)
        }
    }

    /** How many elements the app in front shows (up to [limit]): words, or something to tap. */
    private fun countDrawn(limit: Int): Int {
        val root = rootInActiveWindow ?: return 0
        var seen = 0
        var hits = 0
        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.add(root)
        while (stack.isNotEmpty() && hits < limit && seen < 200) {
            val n = stack.removeLast()
            seen++
            if (!n.isVisibleToUser) continue
            if (n.isClickable || n.isEditable || !n.text.isNullOrBlank() || !n.contentDescription.isNullOrBlank()) hits++
            for (i in n.childCount - 1 downTo 0) n.getChild(i)?.let { stack.add(it) }
        }
        return hits
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
    @Volatile var installing = false
        private set

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

    /**
     * How the last install ended, for a task waiting on it (build 117):
     * installed | already | paid | sign_in | not_started | no_button |
     * stopped | timeout — "" while one runs or none has.
     */
    @Volatile var installOutcome = ""

    /**
     * [forTask]: installing the app a task needs (build 117). The owner,
     * 2026-09-26: "order something from Amazon" with no Amazon on the phone
     * — "it should click on the install and it should install the app", and
     * then do the task. On success the app is NOT opened here and the bar is
     * not ended: the task's own run opens it where it needs to (a search
     * link) and takes the bar over. The outcome is left in [installOutcome].
     */
    fun autoInstall(pkg: String, name: String, forTask: Boolean = false): Boolean {
        if (installing || running) {
            Log.i(TAG, "install refused: installing=$installing running=$running")
            return false
        }
        installing = true
        installOutcome = ""
        stopRequested = false
        Log.i(TAG, "install start pkg=$pkg name=$name forTask=$forTask")
        val store = "com.android.vending"
        val label = name.trim().ifEmpty { pkg }
        val want = norm(name)
        val started = SystemClock.uptimeMillis()
        var pressedAt = 0L
        var presses = 0
        var openedListing = pkg.isNotEmpty()
        showPill("Installing $label…")

        fun done(text: String, outcome: String) {
            Log.i(TAG, "install end outcome=$outcome presses=$presses")
            if (forTask) InstallWatch.clear(this)
            installOutcome = outcome
            installing = false
            end(text)
        }

        fun openApp(launch: Intent) {
            if (forTask) {
                // The task opens it, where it needs to; the bar stays up.
                Log.i(TAG, "install end outcome=installed presses=$presses (task carries on)")
                InstallWatch.clear(this)
                installOutcome = "installed"
                installing = false
                status("$label is installed — carrying on…")
                // Should the task never take the bar over, it goes anyway.
                main.postDelayed({ if (!running && !installing) hidePill() }, 30_000)
                return
            }
            try {
                startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                done("$label is installed — opened it for you.", "installed")
            } catch (e: Throwable) {
                done("$label is installed — tap its icon to open it.", "installed")
            }
        }

        val tick = object : Runnable {
            override fun run() {
                if (!installing) return
                val now = SystemClock.uptimeMillis()
                if (stopRequested) {
                    done(if (presses > 0) "Stopped. The download may still finish on its own." else "Stopped.", "stopped")
                    return
                }
                // Arrived — open it (InstallWatch saw the package land).
                InstallWatch.takeReady(this@HariAccessibilityService, installer = true)?.let { openApp(it); return }
                if (pkg.isNotEmpty() && presses > 0) {
                    packageManager.getLaunchIntentForPackage(pkg)?.let { openApp(it); return }
                }

                val root = rootInActiveWindow
                val front = root?.packageName?.toString().orEmpty()
                if (front != store && presses == 0) Log.i(TAG, "install waiting: front=$front")
                if (front == store) {
                    val nodes = visibleNodes(root!!)
                    val said = { n: AccessibilityNodeInfo ->
                        (n.text?.toString()?.trim().takeUnless { it.isNullOrEmpty() }
                            ?: n.contentDescription?.toString()?.trim()).orEmpty()
                    }
                    val install = nodes.firstOrNull { said(it).equals("install", ignoreCase = true) }
                    val open = nodes.firstOrNull { said(it).equals("open", ignoreCase = true) }
                    // A price instead of Install: buying is the owner's step.
                    if (presses == 0 && install == null &&
                        nodes.any { PRICE_ONLY.matches(said(it)) || said(it).startsWith("Buy", true) }) {
                        done("$label is a paid app — buying it is your step, so I've left it open for you.", "paid")
                        return
                    }
                    if (nodes.any { said(it).matches(Regex("(?i)^sign in$")) }) {
                        done("The app store wants you to sign in first — then say install $label again.", "sign_in")
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
                                done("The download didn't start — tap Install yourself.", "not_started")
                                return
                            }
                            if (clickUp(install)) {
                                presses++
                                pressedAt = now
                                Log.i(TAG, "install pressed ($presses)")
                                status("Downloading $label…")
                            }
                        }
                    } else if (install == null && presses > 0) {
                        // Downloading: show Play Store's own progress.
                        nodes.map { said(it) }.firstOrNull { Regex("\\d+\\s*%").containsMatchIn(it) }
                            ?.let { status("Downloading $label… ${Regex("\\d+\\s*%").find(it)!!.value}") }
                    } else if (open != null && presses == 0) {
                        // Already on the phone.
                        if (forTask) {
                            Log.i(TAG, "install end outcome=already")
                            InstallWatch.clear(this@HariAccessibilityService)
                            installOutcome = "already"
                            installing = false
                            return
                        }
                        clickUp(open)
                        done("$label was already installed — opened it.", "already")
                        return
                    } else if (install == null && presses == 0) {
                        Log.i(TAG, "install looking: no Install button yet (${nodes.size} nodes)")
                    }
                }

                val waited = now - started
                if (presses == 0 && waited > 30_000) {
                    done("I couldn't find the Install button — please tap it yourself.", "no_button")
                    return
                }
                if (waited > 12 * 60_000) {
                    done("$label is still downloading — it'll be on your home screen when done.", "timeout")
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
        return dispatch(GestureDescription.StrokeDescription(path, 0, 90), x, y)
    }

    private fun pressAt(x: Float, y: Float): Boolean {
        if (Build.VERSION.SDK_INT < 24) return false
        val path = Path().apply { moveTo(x, y) }
        return dispatch(GestureDescription.StrokeDescription(path, 0, 700), x, y)
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

    /**
     * A SCROLL THAT DOESN'T FLING. The quick swipe flung the page two or
     * three screens on, past the item being looked for. This drags 70% →
     * 35% of the height over 600 ms, then holds the finger still for
     * 150 ms before lifting — no speed left, so the page moves about one
     * screen with some overlap. (Android 8+; older phones swipe.)
     */
    private fun dragScroll(forward: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < 26) return swipe(forward)
        val dm = resources.displayMetrics
        val x = dm.widthPixels / 2f
        val low = dm.heightPixels * 0.70f
        val high = dm.heightPixels * 0.35f
        val (from, to) = if (forward) low to high else high to low
        val drag = GestureDescription.StrokeDescription(
            Path().apply { moveTo(x, from); lineTo(x, to) }, 0, 600, true)
        if (!dispatch(drag)) return swipe(forward)
        val hold = try {
            drag.continueStroke(Path().apply { moveTo(x, to) }, 0, 150, false)
        } catch (e: Throwable) {
            Log.w(TAG, "hold refused: ${e.javaClass.simpleName}")
            null
        }
        return hold != null && dispatch(hold)
    }

    /** Is (x, y) on our own bar? Then it must step aside for the tap. */
    private fun onPill(x: Float, y: Float): Boolean {
        val v = pill ?: return false
        if (v.visibility != View.VISIBLE || v.width == 0) return false
        val at = IntArray(2)
        v.getLocationOnScreen(at)
        return x >= at[0] && x <= at[0] + v.width && y >= at[1] && y <= at[1] + v.height
    }

    /**
     * A gesture, confirmed. Returns true only when Android reports it
     * COMPLETED — the old version reported success the moment it was
     * handed over, so a tap the system cancelled still counted as done and
     * the planner kept tapping a button that never received it (seen
     * 2026-09-24). The bar is left alone unless the finger lands on it:
     * changing its window during a gesture can cancel the gesture.
     */
    private fun dispatch(stroke: GestureDescription.StrokeDescription, x: Float = -1f, y: Float = -1f): Boolean {
        if (Build.VERSION.SDK_INT < 24) return false
        val onMain = Looper.myLooper() == Looper.getMainLooper()
        val latch = java.util.concurrent.CountDownLatch(1)
        var completed = false
        val go = Runnable {
            val hide = x >= 0 && onPill(x, y)
            if (hide) pill?.visibility = View.INVISIBLE
            gestureBusy = true
            val restore = {
                gestureBusy = false
                if (hide) pill?.visibility = View.VISIBLE
            }
            val sent = try {
                dispatchGesture(
                    GestureDescription.Builder().addStroke(stroke).build(),
                    object : GestureResultCallback() {
                        override fun onCompleted(g: GestureDescription?) {
                            completed = true; restore(); latch.countDown()
                        }
                        override fun onCancelled(g: GestureDescription?) {
                            restore(); latch.countDown()
                        }
                    },
                    null
                )
            } catch (e: Throwable) { false }
            if (!sent) { restore(); latch.countDown() }
        }
        if (onMain) { main.post(go); return true } // cannot wait on the UI thread
        main.post(go)
        latch.await(3, java.util.concurrent.TimeUnit.SECONDS)
        Log.i(TAG, "gesture ${if (completed) "completed" else "not completed"}")
        return completed
    }

    /* ---------------------------------------------------------------- *
     * THE PILL — "working on it… Stop", drawn over the other app
     * ---------------------------------------------------------------- */

    private fun dp(v: Int): Int = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    fun status(text: String) {
        main.post { pillText?.text = text }
    }

    /**
     * THE BAR SITS AT THE BOTTOM (2026-09-24). At the top it covered apps'
     * search bars — Instagram's among them — which are exactly what a task
     * taps first. Now it is centred just above the navigation / gesture
     * bar, and moves up above the keyboard while one is open (the owner may
     * be typing an OTP on their turn). Returns the offset from the bottom.
     */
    private fun pillY(): Int {
        val kb = imeBounds()
        if (kb != null) {
            val (_, sh) = screenSize()
            return (sh - kb.top).coerceAtLeast(0) + dp(8)
        }
        return navBarHeight() + dp(10)
    }

    /** The navigation / gesture bar's height, or 0. */
    private fun navBarHeight(): Int {
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                return (getSystemService(WINDOW_SERVICE) as WindowManager).currentWindowMetrics.windowInsets
                    .getInsetsIgnoringVisibility(WindowInsets.Type.navigationBars()).bottom
            } catch (_: Throwable) {}
        }
        return try {
            val id = resources.getIdentifier("navigation_bar_height", "dimen", "android")
            if (id > 0) resources.getDimensionPixelSize(id) else 0
        } catch (_: Throwable) { 0 }
    }

    /** Puts the bar where pillY says — on the UI thread, never mid-gesture. */
    private val placePill: Runnable = object : Runnable {
        override fun run() {
            val v = pill ?: return
            val lp = pillParams ?: return
            // Moving the bar's window while a finger is down can cancel
            // the gesture; wait for it to finish.
            if (gestureBusy) { main.postDelayed(this, 250); return }
            val y = pillY()
            if (y == lp.y) return
            lp.y = y
            try {
                (getSystemService(WINDOW_SERVICE) as WindowManager).updateViewLayout(v, lp)
            } catch (_: Throwable) {}
        }
    }

    private fun showPill(text: String) {
        main.post {
            try {
                if (pill == null) {
                    val wm = getSystemService(WINDOW_SERVICE) as WindowManager
                    // Compact: one short line and the Stop button.
                    val row = LinearLayout(this).apply {
                        orientation = LinearLayout.HORIZONTAL
                        gravity = Gravity.CENTER_VERTICAL
                        setPadding(dp(12), dp(6), dp(6), dp(6))
                        background = GradientDrawable().apply {
                            cornerRadius = dp(18).toFloat()
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
                    row.addView(dot, LinearLayout.LayoutParams(dp(7), dp(7)).apply { rightMargin = dp(8) })
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
                        setOnClickListener { pressStop() }
                    }
                    row.addView(stop)
                    // Shown only on the owner's turn, when the first button
                    // reads Continue: Stop is still one tap away.
                    val extra = TextView(this).apply {
                        this.text = "Stop"
                        setTextColor(Color.parseColor("#FFB4A9"))
                        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                        setTypeface(typeface, android.graphics.Typeface.BOLD)
                        setPadding(dp(8), dp(4), dp(8), dp(4))
                        contentDescription = "Stop the assistant"
                        visibility = View.GONE
                        setOnClickListener { pressStop() }
                    }
                    row.addView(extra)
                    val lp = WindowManager.LayoutParams(
                        WindowManager.LayoutParams.WRAP_CONTENT,
                        WindowManager.LayoutParams.WRAP_CONTENT,
                        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                        PixelFormat.TRANSLUCENT
                    ).apply {
                        // At the bottom, clear of apps' top search bars.
                        gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
                        y = pillY()
                    }
                    wm.addView(row, lp)
                    pill = row
                    pillText = label
                    pillStop = stop
                    pillExtra = extra
                    pillParams = lp
                }
                // A new run over a finished bar: back to the working look.
                workingLook(text)
                // The keyboard may have come or gone since it was placed.
                placePill.run()
            } catch (e: Throwable) {
                // No pill is not a reason to fail the task; Stop is also
                // reachable by returning to the app.
                Log.w(TAG, "pill failed: ${e.javaClass.simpleName}")
            }
        }
        // While a run or an install is on, the screen stays on.
        keepScreenOn(running || installing)
    }

    /** "…working… Stop" — on the UI thread. */
    private fun workingLook(text: String) {
        pillText?.apply { this.text = text; maxLines = 1; maxWidth = dp(230) }
        pillStop?.apply {
            this.text = "Stop"
            setTextColor(Color.parseColor("#FFB4A9"))
            contentDescription = "Stop the assistant"
            setOnClickListener { pressStop() }
        }
        pillExtra?.visibility = View.GONE
    }

    /**
     * Stop on the bar — on the UI thread. The task loop sees it within a
     * moment and ends the run with a report. If the loop has gone (the
     * app was swiped away) nothing would ever answer, so after
     * [STOP_FALLBACK_MS] without a word from it the bar ends the run
     * itself. An install's Stop is answered by the install (not running).
     */
    private fun pressStop() {
        stopRequested = true
        pillText?.text = "Stopping…"
        val pressedAt = SystemClock.uptimeMillis()
        main.postDelayed({
            if (running && lastHeardAt < pressedAt) {
                Log.i(TAG, "Stop unanswered — ending the run")
                end()
            }
        }, STOP_FALLBACK_MS)
    }

    /**
     * THE SCREEN STAYS ON WHILE THE ASSISTANT WORKS. A slow step or an
     * install outlasted a 15-30 s screen timeout; the phone locked mid-task
     * and the next look read the lock screen. The bar is a visible
     * accessibility overlay, so its FLAG_KEEP_SCREEN_ON holds the screen on
     * without a wake lock — and lets go the moment the run ends.
     */
    private fun keepScreenOn(on: Boolean) {
        main.post {
            val v = pill ?: return@post
            val lp = pillParams ?: return@post
            val flag = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            val want = if (on) lp.flags or flag else lp.flags and flag.inv()
            if (want == lp.flags) return@post
            lp.flags = want
            try {
                (getSystemService(WINDOW_SERVICE) as WindowManager).updateViewLayout(v, lp)
            } catch (_: Throwable) {}
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
            pillExtra = null
            pillParams = null
        }
    }
}
