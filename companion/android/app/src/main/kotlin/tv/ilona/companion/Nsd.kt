package tv.ilona.companion

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.InetAddress

private const val TAG = "IlonaTvCompanion"

/** Finds `_ilonatv._tcp` TVs and reports each resolved one to Dart as found/lost, on the main thread. */
class Nsd(ctx: Context, private val channel: MethodChannel) {
    private val nsd = ctx.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifi = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val main = Handler(Looper.getMainLooper())
    private var listener: NsdManager.DiscoveryListener? = null
    private var lock: WifiManager.MulticastLock? = null
    private val callbacks = HashMap<String, NsdManager.ServiceInfoCallback>()
    private val queue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    fun start() {
        if (listener != null) return
        // Before T extensions 7 mDNS replies are dropped without the lock.
        lock = wifi.createMulticastLock(TAG).apply { setReferenceCounted(false); acquire() }
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) {}
            override fun onDiscoveryStopped(type: String) {}
            override fun onStartDiscoveryFailed(type: String, code: Int) {
                Log.w(TAG, "discovery failed: $code")
                main.post { if (listener === this) { listener = null; releaseLock() } }
            }
            override fun onStopDiscoveryFailed(type: String, code: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) = main.post { resolve(info) }.let {}
            override fun onServiceLost(info: NsdServiceInfo) = main.post { lost(info.serviceName) }.let {}
        }
        listener = l
        runCatching { nsd.discoverServices("_ilonatv._tcp", NsdManager.PROTOCOL_DNS_SD, l) }
            .onFailure { Log.w(TAG, "discovery failed", it); listener = null; releaseLock() }
    }

    fun stop() {
        listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        listener = null
        queue.clear()
        resolving = false
        if (Build.VERSION.SDK_INT >= 34) {
            callbacks.values.forEach { runCatching { nsd.unregisterServiceInfoCallback(it) } }
        }
        callbacks.clear()
        releaseLock()
    }

    private fun releaseLock() {
        lock?.let { if (it.isHeld) it.release() }
        lock = null
    }

    private fun resolve(info: NsdServiceInfo) {
        if (listener == null) return
        if (Build.VERSION.SDK_INT >= 34) resolveWithCallback(info) else {
            queue.addLast(info)
            next()
        }
    }

    private fun resolveWithCallback(info: NsdServiceInfo) {
        val name = info.serviceName
        callbacks.remove(name)?.let { runCatching { nsd.unregisterServiceInfoCallback(it) } }
        val cb = object : NsdManager.ServiceInfoCallback {
            override fun onServiceInfoCallbackRegistrationFailed(code: Int) { Log.w(TAG, "resolve failed: $code") }
            override fun onServiceUpdated(updated: NsdServiceInfo) = found(updated, updated.hostAddresses)
            override fun onServiceLost() = lost(name)
            override fun onServiceInfoCallbackUnregistered() {}
        }
        callbacks[name] = cb
        runCatching { nsd.registerServiceInfoCallback(info, { main.post(it) }, cb) }
            .onFailure { Log.w(TAG, "resolve failed", it); callbacks.remove(name) }
    }

    // resolveService allows one at a time (FAILURE_ALREADY_ACTIVE otherwise); deprecated from API 34, used only below it.
    @Suppress("DEPRECATION")
    private fun next() {
        if (resolving) return
        val info = queue.removeFirstOrNull() ?: return
        resolving = true
        val rl = object : NsdManager.ResolveListener {
            override fun onResolveFailed(i: NsdServiceInfo, code: Int) { Log.w(TAG, "resolve failed: $code"); done() }
            override fun onServiceResolved(i: NsdServiceInfo) {
                main.post { found(i, listOfNotNull(i.host)); done() }
            }
            private fun done() = main.post { resolving = false; next() }.let {}
        }
        runCatching { nsd.resolveService(info, rl) }
            .onFailure { Log.w(TAG, "resolve failed", it); resolving = false; next() }
    }

    private fun found(info: NsdServiceInfo, addresses: List<InetAddress>) {
        // A link-local IPv6 address means nothing to the Dart HTTP client; the TV serves on IPv4.
        val host = addresses.firstOrNull { it is Inet4Address }?.hostAddress ?: return
        channel.invokeMethod("found", mapOf("name" to info.serviceName, "host" to host, "port" to info.port))
    }

    private fun lost(name: String) {
        if (Build.VERSION.SDK_INT >= 34) callbacks.remove(name)?.let { runCatching { nsd.unregisterServiceInfoCallback(it) } }
        channel.invokeMethod("lost", mapOf("name" to name))
    }
}
