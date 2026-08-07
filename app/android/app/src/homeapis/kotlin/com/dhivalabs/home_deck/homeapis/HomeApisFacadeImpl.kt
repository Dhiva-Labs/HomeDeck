package com.dhivalabs.home_deck.homeapis

import android.app.Activity
import com.dhivalabs.home_deck.HomeApisFacade
import com.google.home.DeviceType
import com.google.home.Home
import com.google.home.HomeDevice
import com.google.home.matter.standard.LevelControl
import com.google.home.matter.standard.OnOff
import com.google.home.matter.standard.OnOffLightDevice
import com.google.home.matter.standard.OnOffPluginUnitDevice
import com.google.home.matter.standard.Thermostat
import kotlinx.coroutines.flow.first

/**
 * The real Google Home APIs implementation. This file is compiled only when
 * the `homeApis` Gradle property is set (which also adds the SDK
 * dependency), i.e. only after the one-time Home Developer Console
 * registration is done and the SDK is available to this project.
 *
 * NOTE: written against the Home APIs public-beta surface; when activating,
 * check the imports against the SDK version actually downloaded — Google
 * has renamed packages during the beta.
 */
@Suppress("unused") // constructed by reflection from GoogleHomeBridge
class HomeApisFacadeImpl(private val activity: Activity) : HomeApisFacade {

    private val home: Home by lazy { Home.getClient(activity) }

    override suspend fun init(): Boolean {
        // Triggers Google's account-picker + consent sheet on first run;
        // afterwards it resolves silently.
        val permissions = home.hasPermissions()
        if (!permissions) {
            home.requestPermissions(activity)
            if (!home.hasPermissions()) return false
        }
        return home.structures().first().isNotEmpty()
    }

    override suspend fun listDevices(): List<Map<String, Any?>> =
        home.structures().first().flatMap { structure ->
            structure.devices().first().map { device ->
                mapOf(
                    "id" to device.id.id,
                    "name" to device.name,
                    "type" to wireType(device),
                    "state" to stateOf(device),
                )
            }
        }

    override suspend fun execute(
        deviceId: String,
        action: String,
        args: Map<String, Any?>,
    ) {
        val device = findDevice(deviceId)
            ?: throw IllegalArgumentException("Unknown Google Home device $deviceId")

        when (action) {
            "turn_on" -> device.trait(OnOff)?.on()
            "turn_off" -> device.trait(OnOff)?.off()
            "toggle" -> device.trait(OnOff)?.toggle()
            "set_brightness" -> {
                val percent = (args["value"] as? Number)?.toInt() ?: return
                // Matter LevelControl is 0-254.
                device.trait(LevelControl)
                    ?.moveToLevel((percent * 254 / 100).toUByte())
            }
            "set_temperature" -> {
                val degrees = (args["value"] as? Number)?.toDouble() ?: return
                // Matter thermostats take centidegrees.
                device.trait(Thermostat)
                    ?.setOccupiedHeatingSetpoint((degrees * 100).toInt().toShort())
            }
        }
    }

    private suspend fun findDevice(id: String): HomeDevice? =
        home.structures().first()
            .flatMap { it.devices().first() }
            .firstOrNull { it.id.id == id }

    private fun wireType(device: HomeDevice): String = when {
        device.has(OnOffLightDevice) -> "light"
        device.has(OnOffPluginUnitDevice) -> "outlet"
        device.has(Thermostat) -> "thermostat"
        device.has(OnOff) -> "switch"
        else -> "unknown"
    }

    private suspend fun stateOf(device: HomeDevice): Map<String, Any?> {
        val state = mutableMapOf<String, Any?>()
        device.trait(OnOff)?.let { state["on"] = it.onOff }
        device.trait(LevelControl)?.currentLevel?.let {
            state["brightness"] = it.toInt() * 100 / 254
        }
        device.trait(Thermostat)?.occupiedHeatingSetpoint?.let {
            state["value"] = it.toInt() / 100.0
        }
        return state
    }

    private fun HomeDevice.has(type: DeviceType.Factory<*>) = types().contains(type)
}
