import java.io.File
import java.util.Properties
import org.gradle.api.GradleException

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing values: PHOTO_SORTER_ANDROID_* environment variables override
// matching keys in ignored app/android/key.properties. Relative storeFile paths
// resolve from the Android Gradle root (this rootProject: app/android).
val releaseKeyProperties = Properties()
val releaseKeyPropertiesFile = rootProject.file("key.properties")
if (releaseKeyPropertiesFile.isFile) {
    releaseKeyPropertiesFile.reader(Charsets.UTF_8).use { releaseKeyProperties.load(it) }
}

fun androidReleaseCredential(propertyName: String, envName: String): String {
    val fromEnv = System.getenv(envName)?.trim().orEmpty()
    if (fromEnv.isNotEmpty()) {
        return fromEnv
    }
    return releaseKeyProperties.getProperty(propertyName)?.trim().orEmpty()
}

fun resolveAndroidReleaseStoreFile(rawPath: String): File? {
    if (rawPath.isEmpty()) {
        return null
    }
    val resolved = rootProject.file(rawPath)
    return resolved.takeIf { it.isFile }
}

fun isReleaseLikeGradleTask(taskName: String): Boolean {
    val leaf = taskName.substringAfterLast(':')
    return leaf.contains("release", ignoreCase = true)
}

val releaseStoreFileValue =
    androidReleaseCredential("storeFile", "PHOTO_SORTER_ANDROID_STORE_FILE")
val releaseStorePassword =
    androidReleaseCredential("storePassword", "PHOTO_SORTER_ANDROID_STORE_PASSWORD")
val releaseKeyAlias =
    androidReleaseCredential("keyAlias", "PHOTO_SORTER_ANDROID_KEY_ALIAS")
val releaseKeyPassword =
    androidReleaseCredential("keyPassword", "PHOTO_SORTER_ANDROID_KEY_PASSWORD")
val releaseStoreFile = resolveAndroidReleaseStoreFile(releaseStoreFileValue)
val androidReleaseSigningReady =
    releaseStoreFileValue.isNotEmpty() &&
        releaseStorePassword.isNotEmpty() &&
        releaseKeyAlias.isNotEmpty() &&
        releaseKeyPassword.isNotEmpty() &&
        releaseStoreFile != null

val requestedReleaseLikeTask =
    gradle.startParameter.taskNames.any(::isReleaseLikeGradleTask)

if (!androidReleaseSigningReady && requestedReleaseLikeTask) {
    val missingKeys = buildList {
        if (releaseStoreFileValue.isEmpty() || releaseStoreFile == null) add("storeFile")
        if (releaseStorePassword.isEmpty()) add("storePassword")
        if (releaseKeyAlias.isEmpty()) add("keyAlias")
        if (releaseKeyPassword.isEmpty()) add("keyPassword")
    }
    throw GradleException(
        "Android release signing is not configured. Missing or unusable: " +
            missingKeys.joinToString(", ") +
            ". Copy app/android/key.properties.example to app/android/key.properties " +
            "(or set PHOTO_SORTER_ANDROID_STORE_FILE, PHOTO_SORTER_ANDROID_STORE_PASSWORD, " +
            "PHOTO_SORTER_ANDROID_KEY_ALIAS, PHOTO_SORTER_ANDROID_KEY_PASSWORD). " +
            "Environment variables override key.properties.",
    )
}

android {
    namespace = "com.photosorter.photo_sorter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.photosorter.photo_sorter"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    val configuredReleaseStoreFile = releaseStoreFile
    if (androidReleaseSigningReady && configuredReleaseStoreFile != null) {
        signingConfigs {
            create("release") {
                storeFile = configuredReleaseStoreFile
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (androidReleaseSigningReady && configuredReleaseStoreFile != null) {
                signingConfig = signingConfigs.getByName("release")
            }
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
