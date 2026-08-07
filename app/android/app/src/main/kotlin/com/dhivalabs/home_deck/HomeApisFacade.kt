package com.dhivalabs.home_deck

/**
 * Everything [GoogleHomeBridge] needs from the Google Home APIs, expressed
 * without importing them — the SDK only exists in builds where the
 * `homeApis` Gradle property enables the `src/homeapis` source set.
 *
 * Device maps use the wire shape the Dart connector parses:
 * `{id, name, type: light|outlet|switch|thermostat, state: {on, brightness, value}}`.
 */
interface HomeApisFacade {
    companion object {
        /** Implementation looked up by reflection when the SDK is bundled. */
        const val IMPL_CLASS = "com.dhivalabs.home_deck.homeapis.HomeApisFacadeImpl"
    }

    /**
     * True when the Home APIs are ready to serve devices: SDK present, the
     * user finished Google's permission flow, and at least one structure is
     * accessible. Expected to trigger the permission UI on first call.
     */
    suspend fun init(): Boolean

    suspend fun listDevices(): List<Map<String, Any?>>

    /** [action] is HomeDeck's action vocabulary: turn_on / turn_off /
     *  toggle / set_brightness (args.value 0-100) / set_temperature. */
    suspend fun execute(deviceId: String, action: String, args: Map<String, Any?>)
}

/** Stands in whenever the SDK isn't bundled: everything reports "not set up". */
class UnavailableHomeApisFacade : HomeApisFacade {
    override suspend fun init() = false
    override suspend fun listDevices(): List<Map<String, Any?>> = emptyList()
    override suspend fun execute(
        deviceId: String,
        action: String,
        args: Map<String, Any?>,
    ) = throw IllegalStateException(
        "Google Home SDK not bundled — see docs/google-home-setup.md")
}
