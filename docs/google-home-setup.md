# Setting up the Google Home connector (Android only)

HomeDeck's `ghome` connector (`app/lib/connectors/googlehome/googlehome_connector.dart`)
is a scaffold, not a working integration. Out of the box it will always show
"Needs Google Home Developer Console setup" in Settings, because the native
Android half it depends on hasn't been built yet. This document is that
missing half: the exact steps to make it real, and a Kotlin sketch of what
goes where.

Read `docs/ASSISTANT_PLAN.md`'s platform reality matrix first if you haven't —
it explains why this is the only "smart home platform" connector besides Hue
that gets built directly, and why it can never exist on the Linux build.

## The two facts that shape everything here

1. **Android only.** The Home APIs live in Google Play services
   (`com.google.android.gms.home`). There is no iOS, Linux, or web
   equivalent, and there will not be one. On any other HomeDeck build, this
   connector reports itself unavailable and that's the correct, permanent
   behavior — not a bug to fix later.
2. **100 test users until certification.** Google Home apps work
   immediately for development and testing, but only for accounts you add as
   test users in the Home Developer Console — capped at 100. Real public
   distribution requires registering the app in the
   [Home Developer Console](https://developers.home.google.com/apis/android/sdk)
   and passing Google's brand/behavior verification. Don't promise "Google
   Home support" in release notes until that's done; until then it's a
   feature for testers only.

## 1. Create a project in the Google Home Developer Console

1. Go to the [Home Developer Console](https://developers.home.google.com/apis/android/sdk)
   and sign in with the Google account that will own this integration.
2. Create a new project (or link an existing Google Cloud project).
3. Register HomeDeck's Android application ID (from `app/android/app/build.gradle`,
   the `applicationId` under `defaultConfig`) against the project. This is
   what lets the Home APIs recognize HomeDeck as the caller.
4. Add the Google accounts that will test the integration as test users
   (up to 100) — anyone not on this list gets a permissions error, not a
   helpful one, so this step is easy to forget and confusing to debug later.

## 2. Enable the Home APIs and set up OAuth

1. In the same console project, enable the **Home APIs** (Device Access,
   Structure, Commissioning, Automation — whichever your feature set needs;
   HomeDeck only needs Device + Structure to start).
2. Configure the **OAuth consent screen** for the project (app name, support
   email, scopes). The Home APIs authenticate per-*structure*: a user grants
   HomeDeck access to one of their Google Home structures (a home), not to
   their whole Google account.
3. Sensitive device types — locks and cameras — require a **separate,
   per-device-type consent** on top of the structure grant. Don't assume
   structure access implies camera/lock access; the SDK will tell you it
   doesn't (`structure.consentedDeviceTypes()`, see below).

## 3. Add the SDK dependency

As of this writing the Home APIs for Android are in **open beta** and are
**not published to Maven Central or Google's Maven repository** — the
console gives you a local AAR/library bundle to download and host in the
project after enrollment, rather than a `implementation("com.google.android.gms:...")`
coordinate you can copy-paste here. Concretely, in
`app/android/app/build.gradle`:

```gradle
android {
    // ...
    // As directed by the Home Developer Console after you download the SDK:
    // either a flatDir repo pointing at the downloaded AAR, or (if Google
    // has since promoted it to a normal Maven artifact — check the console,
    // it changes) a standard implementation() coordinate.
}

dependencies {
    // Exact coordinate/AAR reference comes from the Home Developer Console
    // download page for your enrolled project — do not hardcode a version
    // here, it will go stale.
    implementation(/* Home Mobile SDK, per Home Developer Console */)

    // Play services base, if not already present elsewhere in the project:
    implementation("com.google.android.gms:play-services-base:18.5.0")
}
```

Check the console's own SDK page at setup time for the current artifact —
this is exactly the kind of detail that drifts, and pasting the wrong
version has broken more than one integration guide already (see
`docs/ASSISTANT_PLAN.md`'s notes on SmartThings/Tuya token churn for why this
repo is allergic to hardcoding things that expire).

## 4. Kotlin: Permissions API

Before any device is visible, the user has to grant HomeDeck access to a
structure. Sketch (in whatever Activity hosts the Flutter engine —
`MainActivity.kt`):

```kotlin
import com.google.android.gms.home.HomeManager
import com.google.android.gms.home.PermissionsState
import com.google.android.gms.home.ConsentScreenOptions

class MainActivity : FlutterActivity() {
    private lateinit var homeManager: HomeManager

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        homeManager = HomeManager.create(this)
        // Must happen during onCreate, before permissions are requested.
        homeManager.registerActivityResultCallerForPermissions(this)
    }

    private suspend fun ensurePermission(): Boolean {
        val state = homeManager.hasPermissions().first() // Flow<PermissionsState>
        if (state == PermissionsState.GRANTED) return true

        val result = homeManager.requestPermissions(
            ConsentScreenOptions(allowStructureChange = true)
        )
        return result.status == PermissionsResultStatus.SUCCESS
    }
}
```

For locks/cameras, additionally check
`structure.consentedDeviceTypes()` (a `Flow<Set<DeviceTypeFactory<out DeviceType>>>`)
before offering control of those device types — a structure grant alone does
not cover them.

## 5. Kotlin: Commissioning (adding new Matter devices)

Only needed if HomeDeck wants to *add* devices to the user's Google Home
structure, as opposed to controlling ones already there. Uses
`CommissioningClient` from the Home Mobile SDK; while your app is
foregrounded during a commissioning flow, call
`suppressHalfSheetNotification()` so Android's own "device found" system
sheet doesn't fight with HomeDeck's UI (it times out after 15 minutes in the
foreground, so re-invoke if a flow runs long). See the
[commissioning docs](https://developers.home.google.com/matter/apis/home/commissioning)
and Google's
[sample app](https://github.com/google-home/sample-apps-for-matter-android)
(`HalfSheetSuppressionObserver.kt`) for a full worked example — it's
substantial enough that reproducing it here would just be a stale copy.

For HomeDeck's M4 scope (control existing devices, not onboard new ones),
commissioning can be skipped entirely at first.

## 6. Where the Flutter MethodChannel handler goes

The Dart side (`GoogleHomeConnector` in
`app/lib/connectors/googlehome/googlehome_connector.dart`) already calls a
channel named `homedeck/googlehome` with three methods. The native
implementation is a `MethodChannel` handler registered in `MainActivity.kt`
(or a small dedicated class it delegates to,
e.g. `GoogleHomeChannelHandler.kt` next to it):

```kotlin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // ... homeManager as above ...

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "homedeck/googlehome")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "init" -> lifecycleScope.launch {
                        result.success(ensurePermission())
                    }
                    "listDevices" -> lifecycleScope.launch {
                        result.success(listDevicesAsMaps()) // List<Map<String, Any?>>
                    }
                    "execute" -> lifecycleScope.launch {
                        val deviceId = call.argument<String>("deviceId")!!
                        val action = call.argument<String>("action")!!
                        val args = call.argument<Map<String, Any?>>("args") ?: emptyMap()
                        executeCommand(deviceId, action, args)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
```

**Contract the Dart side expects** (see `googlehome_connector.dart` for the
exact call sites):

| Method | Args | Return | Meaning |
|---|---|---|---|
| `init` | none | `bool` | `true` once a structure permission is granted and ready to query; `false`/throw means "not set up" |
| `listDevices` | none | `List<Map>` | Each map: `{"id": String, "name": String, "type": "light"\|"outlet"\|"switch"\|"thermostat", "state": {"on": bool, ...}}` |
| `execute` | `{"deviceId": String, "action": String, "args": Map}` | `null` | `action` mirrors HomeDeck's `DeviceAction.name` (`turn_on`, `turn_off`, `toggle`, `set_brightness`, ...) — map each to the matching Home API device trait call |

If the channel has no handler registered at all (native work not started
yet), Dart sees a `MissingPluginException`, which `GoogleHomeConnector`
already treats the same as "not set up" — so the app never crashes over
this, it just stays in the documented error state until the above is built.

## No changes made outside this document and the Dart connector

This setup guide and `app/lib/connectors/googlehome/googlehome_connector.dart`
are the full scope of the current work. `app/android/app/build.gradle`,
`AndroidManifest.xml`, and any new Kotlin files are **not** created yet —
they're the next, separate piece of work this document exists to hand off,
per `app/lib/connectors/googlehome/INTEGRATION_NOTES.md`.
