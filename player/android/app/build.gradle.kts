plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.archivetv.archive_tv_player"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.archivetv.player"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Plugins (media_kit's libmpv) ship every ABI, but `--target-platform` only limits Flutter's own libs.
        // An APK with an arm64 folder but no arm64 libflutter.so crashes on 64-bit phones, so keep only the
        // ABIs being built: android-arm = ArchiveTV-32bit.apk, android-arm64 = ArchiveTV-64bit.apk.
    }

    (project.findProperty("target-platform") as String?)?.let { tp ->
        val all = mapOf("android-arm" to "armeabi-v7a", "android-arm64" to "arm64-v8a", "android-x64" to "x86_64")
        val keep = tp.split(",").mapNotNull { all[it] }
        if (keep.isNotEmpty()) packaging { jniLibs { excludes += (all.values - keep.toSet()).map { "lib/$it/**" } } }
    }

    buildTypes {
        release {
            // Signed with the Android debug keystore (%USERPROFILE%\.android\debug.keystore): fine for sideloading.
            signingConfig = signingConfigs.getByName("debug")
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
