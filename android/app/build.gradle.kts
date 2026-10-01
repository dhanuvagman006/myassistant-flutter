import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
    // Crash reports with symbols, and the start-up/network traces
    // (services/telemetry.dart, 2026-10-01).
    id("com.google.firebase.crashlytics")
    id("com.google.firebase.firebase-perf")
}

// Release signing: reads android/key.properties (git-ignored). If the file
// is missing, release builds fall back to debug signing so `flutter run
// --release` keeps working on machines without the keystore.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.myassistant.myassistant"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

     compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    // The release lint-vital pass alone needs ~1.5 GB of JVM heap and
    // OOM-killed builds on this 5 GB machine; it only re-checks what the
    // analyzer already covers.
    lint {
        checkReleaseBuilds = false
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.myassistant.myassistant"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 8 (API 26): the documented minimum for Firebase Phone
        // Number Verification (2026-09-29). Flutter's default is 24.
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Real phones only: x86/x86_64 are emulator ABIs, and with the
        // onnxruntime + webrtc native libs they were ~70 MB of dead
        // weight in every shared APK.
        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a")
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
        // `flutter run` on the owner's phone (2026-09-30): the debug build
        // is signed like the release, so it installs OVER the published app
        // (keeping his sign-in and data) instead of being refused, which
        // makes flutter run uninstall the app first.
        debug {
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    // The abiFilters above are overridden by the Flutter gradle plugin,
    // so plugin .so files (onnxruntime 25 MB, webrtc 16 MB, sherpa 5 MB)
    // still shipped for the emulator-only x86_64 ABI. Packaging excludes
    // are applied last and actually stick.
    packaging {
        jniLibs {
            excludes.add("lib/x86_64/**")
            excludes.add("lib/x86/**")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // SEND FEEDBACK (owner, 2026-09-25: "yes add the send feedback button").
    // The client gets the app through Firebase App Distribution; this SDK
    // opens its feedback form (TesterFeedbackBridge), and what the client
    // writes shows up in the Firebase console under the release.
    //
    // The FULL SDK, because this app is sideloaded and never on Play. It
    // also carries App Distribution's own self-update code, which Play
    // forbids: a Play build must use "firebase-appdistribution-api"
    // instead. We never call that update code (updateIfNewReleaseAvailable,
    // checkForNewRelease, updateApp) — our own updater stays the only one.
    implementation("com.google.firebase:firebase-appdistribution:16.0.0-beta20")

    // PHONE NUMBER VERIFICATION (owner, 2026-09-29): the SIM's number, read
    // from the carrier by Google after Android's consent sheet — it replaced
    // the SMS code (firebase_auth). PhoneNumberVerificationBridge.
    implementation("com.google.firebase:firebase-pnv:16.1.1")
}
