package tv.ilona.app

import android.app.Activity
import android.media.tv.TvContract
import android.media.tv.TvView
import android.os.Bundle
import android.util.Log
import android.graphics.Color
import android.media.tv.TvInputManager
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import android.view.WindowManager

// An HDMI input full screen, in Ilona TV's own TvView: Fire OS keeps its input
// player and the passthrough link behind Amazon-signed permissions. The
// remote's keys go to the input's session, and the TV's input service passes
// them on to the HDMI-CEC device there (a console's menus move with the TV's
// remote). Back leaves when nothing on the input takes it; a held Back, or
// Home, leaves whatever the device does with it. The session goes with the
// activity.
class InputActivity : Activity() {
    private var tv: TvView? = null
    private var message: TextView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
        val view = TvView(this).apply {
            // Focused, so the keys reach the session (TvView.dispatchKeyEvent).
            isFocusable = true
            isFocusableInTouchMode = true
        }
        // What the TV's own player says on an input with nothing on it.
        val text = TextView(this).apply {
            text = intent.getStringExtra(EXTRA_NO_SIGNAL) ?: "No signal"
            setTextColor(Color.WHITE)
            textSize = 32f
            visibility = View.GONE
        }
        setContentView(FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(view)
            addView(text, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        })
        tv = view
        message = text
        view.requestFocus()
        // The keys the input did not take (a port with no CEC device, or one that ignores Back): Back leaves, the
        // rest are dropped.
        view.setOnUnhandledInputEventListener { e ->
            if (e is KeyEvent && e.keyCode == KeyEvent.KEYCODE_BACK) {
                if (e.action == KeyEvent.ACTION_UP) finish()
                true
            } else {
                false
            }
        }
        view.setCallback(object : TvView.TvInputCallback() {
            override fun onConnectionFailed(inputId: String) {
                Log.w(TAG, "input: connection failed $inputId")
                message?.visibility = View.VISIBLE
            }
            override fun onDisconnected(inputId: String) { Log.w(TAG, "input: disconnected $inputId") }
            override fun onVideoAvailable(inputId: String) {
                Log.i(TAG, "input: video on $inputId")
                message?.visibility = View.GONE
            }
            override fun onVideoUnavailable(inputId: String, reason: Int) {
                Log.i(TAG, "input: no video $inputId reason=$reason")
                // Tuning is the black of a switch; anything after it is an input with nothing to show.
                message?.visibility =
                    if (reason == TvInputManager.VIDEO_UNAVAILABLE_REASON_TUNING) View.GONE else View.VISIBLE
            }
        })
        tune()
    }

    // A held Back leaves even when the device takes every Back (a console does).
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_DOWN && event.isLongPress) {
            finish()
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        tune()
    }

    private fun tune() {
        val id = intent.getStringExtra(EXTRA_ID) ?: return finish()
        Log.i(TAG, "input: tune $id")
        try {
            tv?.tune(id, TvContract.buildChannelUriForPassthroughInput(id))
        } catch (e: RuntimeException) {
            Log.w(TAG, "input: tune failed $e")
            finish()
        }
    }

    // Home (Launcher mode brings Ilona TV back) or another app: nothing plays behind it.
    override fun onStop() {
        super.onStop()
        finish()
    }

    override fun onDestroy() {
        tv?.reset()
        tv = null
        super.onDestroy()
    }

    companion object {
        const val EXTRA_ID = "id"
        const val EXTRA_NO_SIGNAL = "noSignal"
    }
}
