import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// lx 生成的 local.properties：SDK 目录、Lua 目录、应用 id / 名字 / 版本号（来自 lx.json，改 lx.json 后 lx sync 即可）
val lxProps = Properties().apply {
    rootProject.file("local.properties").takeIf { it.isFile }?.reader(Charsets.UTF_8)?.use { load(it) }   // 按 UTF-8 读（路径、App 名可能有中文）
}
fun lx(key: String, default: String? = null): String =
    lxProps.getProperty("lx.$key") ?: default ?: throw GradleException("local.properties 里没有 lx.$key：先运行 lx sync")

val lxSdk = file(lx("sdk"))
val luaAssetsDir = layout.buildDirectory.dir("generated/lxLua")

// Lua 框架（SDK 的 framework/lua）+ 应用脚本（项目的 lua/）合在一起打进 assets/app（LXActivity 启动时解压）
// release 加固：lx build android 传 -PlxLuaHardened=<已编译+加密的目录>，这里直接用它（debug 不传，走源码，热更新/调试不受影响）
val luaHardened = project.findProperty("lxLuaHardened") as String?
val syncLua by tasks.registering(Sync::class) {
    if (luaHardened != null) {
        from(luaHardened) { into("app") }
    } else {
        from(lxSdk.resolve("framework/lua")) { into("app") }
        from(file(lx("appDir"))) { into("app") }
    }
    into(luaAssetsDir)
    duplicatesStrategy = DuplicatesStrategy.INCLUDE
    exclude("**/.DS_Store")
}

android {
    namespace = "com.chaochuan.chaochuan"
    compileSdk = 35

    defaultConfig {
        applicationId = lx("applicationId")
        minSdk = 24
        targetSdk = 35
        versionCode = lx("versionCode", "1").toInt()
        versionName = lx("versionName", "1.0.0")
        resValue("string", "app_name", lx("displayName"))
        // lx install 装的包：启动时加载的原生库、要注册的插件类（LXActivity / LXEngine 读取）
        resValue("string", "lx_native_libraries", lx("packages.nativeLibraries", ""))
        resValue("string", "lx_plugins", lx("packages.plugins", ""))
        ndk { abiFilters += listOf("arm64-v8a") }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // 正式发布前换成自己的签名（signingConfigs），这里先用调试签名方便安装测试
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    sourceSets["main"].assets.srcDir(luaAssetsDir)
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    androidResources { noCompress += listOf("lua") }
    // 包的 AAR 里可能也带着 STL；统一用 lxkit 带的那份
    packaging {
        jniLibs { pickFirsts += listOf("**/libc++_shared.so"); useLegacyPackaging = true }
        // 第三方 protobuf 运行时 jar 带进来的标准 .proto：运行时只用 .pb，源文件不进包
        resources { excludes += listOf("**/*.proto") }
    }
}

tasks.named("preBuild") { dependsOn(syncLua) }

dependencies {
    implementation("com.lx:lxkit:${lx("sdkVersion")}")
    // lx install 装的包（.lx/deps/<包>/platforms/android/*.aar）和它们声明的 Maven 依赖
    lx("packages.aars", "").split(";").filter { it.isNotBlank() }.forEach { implementation(files(it)) }
    lx("packages.dependencies", "").split(";").filter { it.isNotBlank() }.forEach { implementation(it) }
}
