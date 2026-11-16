import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// UnifiedPush and secure storage request the JVM and Android Tink artifacts respectively.
// Use one Android implementation, as recommended by UnifiedPush, instead of packaging duplicate crypto classes.
configurations.configureEach {
    resolutionStrategy.dependencySubstitution {
        substitute(module("com.google.crypto.tink:tink"))
            .using(module("com.google.crypto.tink:tink-android:1.23.0"))
    }
}

// Release keys stay outside Git; production artifacts must never silently use debug credentials.
val signingProperties = Properties()
val signingFile = rootProject.file("key.properties")
if (signingFile.exists()) signingFile.inputStream().use { signingProperties.load(it) }
val buildingRelease = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
if (buildingRelease && !signingFile.exists()) {
    throw GradleException("Configure android/key.properties with your release signing key before building a release.")
}

android {
    namespace = "org.bindubashini.bloodconnection"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Native notification APIs require Java library backports on older supported phones.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // One stable community-owned package ID keeps installs and OAuth registrations aligned.
        applicationId = "org.bindubashini.bloodconnection"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (signingFile.exists()) {
            create("release") {
                keyAlias = signingProperties["keyAlias"] as String
                keyPassword = signingProperties["keyPassword"] as String
                storeFile = file(signingProperties["storeFile"] as String)
                storePassword = signingProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
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
}
