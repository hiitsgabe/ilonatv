package tv.ilona.app

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import kotlin.math.roundToInt

/** The Launcher mode switch in Ilona TV's settings, as Flutter's shared_preferences stores it. */
fun Context.fireTvMode(): Boolean =
    getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).getBoolean("flutter.fireTvMode", false)

/** The "remote sends power twice" fix in Ilona TV's settings (see HomeWatcher.screen). */
fun Context.doublePowerFix(): Boolean =
    getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).getBoolean("flutter.doublePowerFix", false)

/** The "mic button opens Ilona TV, not Alexa" switch (see HomeWatcher.onAlexa). */
fun Context.alexaBounce(): Boolean =
    getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).getBoolean("flutter.alexaBounce", false)

/** The assistant overlay's accent colour (ARGB). shared_preferences stores a Dart int as a Long. */
fun Context.assistantColor(): Int =
    getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        .getLong("flutter.assistantColor", 0xFF4F8CFFL).toInt()

private fun Context.prefs() = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

/** Ilona TV's UI language ("en" or "pt"), as Settings stores it. */
fun Context.language(): String = prefs().getString("flutter.language", "en") ?: "en"

/** The Gemini API key for the assistant (never committed; set in Settings). */
fun Context.geminiKey(): String = prefs().getString("flutter.geminiKey", "") ?: ""

/** The Gemini model id. 3.6-flash is stable and has capacity; 3.8-flash 503s on the free tier. */
fun Context.geminiModel(): String = prefs().getString("flutter.geminiModel", "gemini-3.6-flash") ?: "gemini-3.6-flash"

/**
 * Opaque window over the Amazon home while Ilona TV comes back: the last snapshot of Ilona TV's home, else black, with
 * a "Loading" pill at the bottom, since the snapshot alone looks ready while the keys pressed under it are dropped.
 * Comes down once MainActivity shows Ilona TV's UI again, or after 7 s. Main thread only.
 */
object Curtain {
    private val handler = Handler(Looper.getMainLooper())
    private val timeout = Runnable { hide("timeout") }
    private var view: View? = null
    private var image: ImageView? = null

    val isUp get() = view != null

    /** Ilona TV's home as last drawn. The curtain, if up, moves to the new bitmap before the old one is recycled. */
    @Volatile
    var snapshot: Bitmap? = null
        set(value) {
            val old = field
            field = value
            image?.setImageBitmap(value)
            if (old !== value) old?.recycle()
        }

    private fun dp(ctx: Context, n: Int) = (n * ctx.resources.displayMetrics.density).roundToInt()

    /** A spinner and "Loading…" (in Ilona TV's language) on a dark glass pill. */
    private fun loadingPill(ctx: Context): View = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(ctx, 18), dp(ctx, 10), dp(ctx, 22), dp(ctx, 10))
        background = GradientDrawable().apply {
            cornerRadius = dp(ctx, 24).toFloat()
            setColor(0xB3141418.toInt())
            setStroke(dp(ctx, 1), 0x33FFFFFF)
        }
        addView(
            ProgressBar(ctx).apply {
                isIndeterminate = true
                indeterminateTintList = ColorStateList.valueOf(Color.WHITE)
            },
            LinearLayout.LayoutParams(dp(ctx, 20), dp(ctx, 20)),
        )
        addView(
            TextView(ctx).apply {
                text = if (ctx.language() == "pt") "Carregando…" else "Loading…"
                setTextColor(Color.WHITE)
                textSize = 15f
                setPadding(dp(ctx, 12), 0, 0, 0)
            },
        )
    }

    fun show(service: AccessibilityService) {
        if (view != null) return
        val img = ImageView(service).apply {
            scaleType = ImageView.ScaleType.FIT_XY
            setImageBitmap(snapshot)
        }
        val v = FrameLayout(service).apply {
            setBackgroundColor(Color.BLACK)
            addView(img, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
            addView(
                loadingPill(service),
                FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL)
                    .apply { bottomMargin = dp(service, 44) },
            )
        }
        runCatching {
            service.getSystemService(WindowManager::class.java).addView(
                v,
                WindowManager.LayoutParams(
                    WindowManager.LayoutParams.MATCH_PARENT,
                    WindowManager.LayoutParams.MATCH_PARENT,
                    WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                    // Not focusable: the keys that would reach the Amazon home under it are dropped by
                    // HomeWatcher.onKeyEvent while it is up.
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
                    PixelFormat.OPAQUE,
                ),
            )
        }.onFailure {
            Log.w(TAG, "curtain addView failed", it)
            return
        }
        view = v
        image = img
        handler.postDelayed(timeout, 7000)
        // Posted: addView's traversal barrier holds it until the curtain's first draw, which is what the eye sees.
        handler.post { Log.i(TAG, "curtain up +${HomeWatcher.sinceHome()}ms") }
    }

    fun hide(why: String) {
        val v = view ?: return
        view = null
        image = null
        handler.removeCallbacks(timeout)
        // Throws once the window is gone with the service's token.
        runCatching { v.context.getSystemService(WindowManager::class.java).removeView(v) }
            .onFailure { Log.w(TAG, "curtain removeView failed", it) }
        Log.i(TAG, "curtain down ($why) +${HomeWatcher.sinceHome()}ms")
    }
}
