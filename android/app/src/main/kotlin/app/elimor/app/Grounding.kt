package app.elimor.app

import android.content.Context
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The live facts Gemini cannot know on its own: the current time (the TV's clock) and the weather (Open-Meteo, free,
 * no key). Fed into the prompt so the assistant can answer "what time is it" and "what's the temperature". Runs on a
 * background thread (makes a network call).
 */
object Grounding {
    fun now(ctx: Context, pt: Boolean): String {
        val loc = if (pt) Locale("pt", "BR") else Locale.US
        val d = Date()
        val time = SimpleDateFormat("HH:mm", loc).format(d)
        val date = SimpleDateFormat(if (pt) "EEEE, d 'de' MMMM 'de' yyyy" else "EEEE, MMMM d, yyyy", loc).format(d)
        val sb = StringBuilder(if (pt) "Hora atual: $time de $date." else "Current time: $time, $date.")
        val prefs = ctx.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val city = prefs.getString("flutter.weatherCity", "").orEmpty()
        val lat = double(prefs.getString("flutter.weatherLat", null))
        val lon = double(prefs.getString("flutter.weatherLon", null))
        if (city.isNotEmpty() && lat != null && lon != null) {
            weather(lat, lon, prefs.getBoolean("flutter.fahrenheit", false), pt)?.let {
                sb.append(if (pt) " Clima em $city: $it." else " Weather in $city: $it.")
            }
        }
        return sb.toString()
    }

    // The legacy shared_preferences plugin keeps a Dart double as this prefix and its toString()
    // (shared_preferences_android LegacySharedPreferencesPlugin.setDouble).
    private const val DOUBLE_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu"

    private fun double(stored: String?) = stored?.removePrefix(DOUBLE_PREFIX)?.toDoubleOrNull()

    private fun weather(lat: Double, lon: Double, fahrenheit: Boolean, pt: Boolean): String? = runCatching {
        val url = "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon" +
            "&current=temperature_2m,weather_code&timezone=auto" +
            if (fahrenheit) "&temperature_unit=fahrenheit" else ""
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 5000; readTimeout = 5000
        }
        val json = conn.inputStream.bufferedReader().use { it.readText() }
        val cur = JSONObject(json).getJSONObject("current")
        val temp = cur.getDouble("temperature_2m").toInt()
        val cond = condition(cur.getInt("weather_code"), pt)
        "$temp°${if (fahrenheit) "F" else "C"}, $cond"
    }.getOrNull()

    /** WMO weather code to a short description. */
    private fun condition(code: Int, pt: Boolean): String = when (code) {
        0 -> if (pt) "céu limpo" else "clear"
        1, 2, 3 -> if (pt) "parcialmente nublado" else "partly cloudy"
        45, 48 -> if (pt) "névoa" else "fog"
        in 51..67 -> if (pt) "chuva" else "rain"
        in 71..77 -> if (pt) "neve" else "snow"
        in 80..82 -> if (pt) "pancadas de chuva" else "showers"
        in 95..99 -> if (pt) "trovoada" else "thunderstorm"
        else -> if (pt) "nublado" else "cloudy"
    }
}
