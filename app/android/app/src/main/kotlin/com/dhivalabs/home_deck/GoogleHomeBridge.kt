package com.dhivalabs.home_deck

import android.app.Activity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Native side of `MethodChannel('homedeck/googlehome')` — the channel the
 * Dart `GoogleHomeConnector` scaffold already speaks.
 *
 * The actual Google Home APIs SDK is only distributed to developers who have
 * registered the app in the Home Developer Console, so this bridge never
 * references it directly. It looks for [HomeApisFacade.IMPL_CLASS] at
 * runtime: present (the `homeApis` Gradle property is set and the SDK is in
 * `libs/`) → real device control; absent → `init` answers `false` and the
 * Dart side keeps showing its "needs setup" status. Either way the app
 * builds and runs everywhere.
 */
class GoogleHomeBridge(private val activity: Activity) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "homedeck/googlehome"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // Eager: the real implementation registers the permission-flow activity
    // result caller, which must happen while the activity is being created.
    private val facade: HomeApisFacade = try {
        Class.forName(HomeApisFacade.IMPL_CLASS)
            .getConstructor(Activity::class.java)
            .newInstance(activity) as HomeApisFacade
    } catch (_: Throwable) {
        UnavailableHomeApisFacade()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> launchReplying(result) { facade.init() }
            "listDevices" -> launchReplying(result) { facade.listDevices() }
            "execute" -> launchReplying(result) {
                facade.execute(
                    deviceId = call.argument<String>("deviceId")
                        ?: throw IllegalArgumentException("deviceId missing"),
                    action = call.argument<String>("action")
                        ?: throw IllegalArgumentException("action missing"),
                    args = call.argument<Map<String, Any?>>("args") ?: emptyMap(),
                )
            }
            else -> result.notImplemented()
        }
    }

    /** Runs [block] off the main thread and maps outcomes onto the channel. */
    private fun <T> launchReplying(
        result: MethodChannel.Result,
        block: suspend () -> T,
    ) {
        scope.launch(Dispatchers.Default) {
            val reply: Result<T> = runCatching { block() }
            launch(Dispatchers.Main) {
                reply.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { e ->
                        result.error("ghome", e.message ?: e.toString(), null)
                    },
                )
            }
        }
    }

    fun dispose() = scope.cancel()
}
