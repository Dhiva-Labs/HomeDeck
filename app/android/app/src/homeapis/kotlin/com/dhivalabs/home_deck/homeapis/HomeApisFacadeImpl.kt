package com.dhivalabs.home_deck.homeapis

import android.app.Activity
import androidx.activity.result.ActivityResultCaller
import com.dhivalabs.home_deck.HomeApisFacade
import com.google.home.DeviceType
import com.google.home.FactoryRegistry
import com.google.home.Home
import com.google.home.HomeClient
import com.google.home.HomeConfig
import com.google.home.HomeDevice
import com.google.home.PermissionsResultStatus
import com.google.home.PermissionsState
import com.google.home.Trait
import com.google.home.matter.standard.ColorTemperatureLightDevice
import com.google.home.matter.standard.DimmableLightDevice
import com.google.home.matter.standard.ExtendedColorLightDevice
import com.google.home.matter.standard.LevelControl
import com.google.home.matter.standard.LevelControlTrait
import com.google.home.matter.standard.OnOff
import com.google.home.matter.standard.OnOffLightDevice
import com.google.home.matter.standard.OnOffLightSwitchDevice
import com.google.home.matter.standard.OnOffPluginUnitDevice
import com.google.home.matter.standard.Thermostat
import com.google.home.matter.standard.ThermostatDevice
import com.google.home.matter.standard.ThermostatTrait
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The real Google Home APIs implementation, written against SDK 17.1.0
 * (signatures verified with javap against the downloaded artifacts, call
 * shapes matched to Google's sample app). Compiled only when the `homeApis`
 * Gradle property is set.
 *
 * Requires the host activity to be an AndroidX [ActivityResultCaller]
 * (HomeDeck's MainActivity is a FlutterFragmentActivity), because the
 * Permissions API drives Google's consent UI through activity results.
 */
@Suppress("unused") // constructed by reflection from GoogleHomeBridge
class HomeApisFacadeImpl(activity: Activity) : HomeApisFacade {

    private val home: HomeClient = Home.getClient(
        activity,
        HomeConfig(
            factoryRegistry = FactoryRegistry(
                traits = listOf(OnOff, LevelControl, Thermostat),
                types = listOf(
                    OnOffLightDevice,
                    DimmableLightDevice,
                    ColorTemperatureLightDevice,
                    ExtendedColorLightDevice,
                    OnOffPluginUnitDevice,
                    OnOffLightSwitchDevice,
                    ThermostatDevice,
                ),
            ),
        ),
    ).also {
        // Must happen during activity creation — Google's consent sheet is
        // launched through the activity-result mechanism.
        it.registerActivityResultCallerForPermissions(
            activity as ActivityResultCaller)
    }

    override suspend fun init(): Boolean {
        val state = home.hasPermissions().first()
        if (state != PermissionsState.GRANTED) {
            val result = home.requestPermissions()
            if (result.status != PermissionsResultStatus.SUCCESS) return false
        }
        // Permission granted to a structure; give the first sync a moment.
        return withTimeoutOrNull(10_000) {
            home.structures().first { it.isNotEmpty() }
        } != null
    }

    override suspend fun listDevices(): List<Map<String, Any?>> =
        home.devices().first().map { device ->
            val traits = traitsOf(device)
            mapOf(
                "id" to device.id.id,
                "name" to device.name,
                "type" to wireType(device, traits),
                "state" to stateFrom(traits),
            )
        }

    override suspend fun execute(
        deviceId: String,
        action: String,
        args: Map<String, Any?>,
    ) {
        val device = home.devices().first().firstOrNull { it.id.id == deviceId }
            ?: throw IllegalArgumentException("Unknown Google Home device $deviceId")
        val traits = traitsOf(device)
        val onOff = traits.filterIsInstance<OnOff>().firstOrNull()
        val level = traits.filterIsInstance<LevelControl>().firstOrNull()
        val thermostat = traits.filterIsInstance<Thermostat>().firstOrNull()

        when (action) {
            "turn_on" -> onOff?.on()
            "turn_off" -> onOff?.off()
            "toggle" -> onOff?.toggle()
            "set_brightness" -> {
                val percent = (args["value"] as? Number)?.toInt() ?: return
                level?.moveToLevelWithOnOff(
                    level = (percent.coerceIn(0, 100) * 254 / 100).toUByte(),
                    transitionTime = null,
                    optionsMask = LevelControlTrait.OptionsBitmap(),
                    optionsOverride = LevelControlTrait.OptionsBitmap(),
                )
            }
            "set_temperature" -> {
                val target = (args["value"] as? Number)?.toDouble() ?: return
                val current = thermostat?.occupiedHeatingSetpoint ?: return
                // setpointRaiseLower moves in 0.1 °C steps; attribute is in
                // centidegrees.
                val deciDelta = ((target * 100 - current) / 10).toInt()
                thermostat.setpointRaiseLower(
                    ThermostatTrait.SetpointRaiseLowerModeEnum.Both,
                    deciDelta.coerceIn(-127, 127).toByte(),
                )
            }
        }
    }

    // ---- helpers -------------------------------------------------------------

    private suspend fun traitsOf(device: HomeDevice): List<Trait> =
        device.types().first().flatMap { type -> type.traits() }

    private suspend fun wireType(device: HomeDevice, traits: List<Trait>): String {
        val types: Set<DeviceType> = device.types().first()
        val factories = types.map { it.factory }
        return when {
            factories.any {
                it == OnOffLightDevice || it == DimmableLightDevice ||
                    it == ColorTemperatureLightDevice || it == ExtendedColorLightDevice
            } -> "light"
            factories.any { it == OnOffPluginUnitDevice } -> "outlet"
            factories.any { it == ThermostatDevice } -> "thermostat"
            traits.any { it is OnOff } -> "switch"
            else -> "unknown"
        }
    }

    private fun stateFrom(traits: List<Trait>): Map<String, Any?> {
        val state = mutableMapOf<String, Any?>()
        traits.filterIsInstance<OnOff>().firstOrNull()?.onOff?.let {
            state["on"] = it
        }
        traits.filterIsInstance<LevelControl>().firstOrNull()?.currentLevel?.let {
            state["brightness"] = it.toInt() * 100 / 254
        }
        traits.filterIsInstance<Thermostat>().firstOrNull()
            ?.occupiedHeatingSetpoint?.let {
                state["value"] = it.toInt() / 100.0
            }
        return state
    }
}
