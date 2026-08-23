plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.fundus.fundus"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.fundus.fundus"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    val previewStoreFile = System.getenv("FUNDUS_ANDROID_STORE_FILE")
    val previewStorePassword = System.getenv("FUNDUS_ANDROID_STORE_PASSWORD")
    val previewKeyAlias = System.getenv("FUNDUS_ANDROID_KEY_ALIAS")
    val previewKeyPassword = System.getenv("FUNDUS_ANDROID_KEY_PASSWORD")
    val hasPreviewSigning = listOf(
        previewStoreFile,
        previewStorePassword,
        previewKeyAlias,
        previewKeyPassword,
    ).all { !it.isNullOrBlank() }

    signingConfigs {
        if (hasPreviewSigning) {
            create("preview") {
                storeFile = file(previewStoreFile!!)
                storePassword = previewStorePassword
                keyAlias = previewKeyAlias
                keyPassword = previewKeyPassword
                storeType = "PKCS12"
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(
                if (hasPreviewSigning) "preview" else "debug",
            )
        }
    }
}

flutter {
    source = "../.."
}
