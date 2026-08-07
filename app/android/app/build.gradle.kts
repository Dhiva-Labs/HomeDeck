import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing lives in android/key.properties (gitignored). CI recreates
// that file plus the keystore from repository secrets; locally it just exists.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "com.dhivalabs.home_deck"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.dhivalabs.home_deck"
        // Old repurposed phones/tablets are a primary target, so we go below
        // Flutter's default of 24 (Android 7.0) down to Android 5.0.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystoreProperties.isNotEmpty()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Real release signing when key.properties is present; debug keys
            // otherwise so `flutter run --release` still works on a fresh clone.
            signingConfig = if (keystoreProperties.isNotEmpty()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// The Google Home APIs SDK is only available to registered Home Developer
// Console projects, so the code that calls it lives in src/homeapis and is
// compiled only when `-PhomeApis` is passed (or homeApis= is set in
// gradle.properties) AND the SDK has been dropped into app/libs/. Without
// the flag every build works normally and GoogleHomeBridge falls back to
// its "needs setup" facade. See docs/google-home-setup.md.
if (project.hasProperty("homeApis")) {
    android.sourceSets.getByName("main") {
        kotlin.srcDir("src/homeapis/kotlin")
    }
    dependencies {
        implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar", "*.jar"))))
    }
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
}

flutter {
    source = "../.."
}
