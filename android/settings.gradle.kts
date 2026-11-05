import java.util.Properties

// lx 项目的 Android 工程：app 模块依赖 SDK 本地 Maven 仓库里的 lxkit（lx precache 编译，bin/cache/artifacts/android/repo）
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

// local.properties 由 lx 生成（不要提交）：lx.sdk = SDK 目录，另有应用 id / 名字 / 版本号（来自 lx.json）
val lxProps = Properties().apply {
    rootDir.resolve("local.properties").takeIf { it.isFile }?.reader(Charsets.UTF_8)?.use { load(it) }   // 按 UTF-8 读（路径、App 名可能有中文）
}
val lxSdk = lxProps.getProperty("lx.sdk")
    ?: throw GradleException("没有 local.properties 里的 lx.sdk：先在项目目录运行一次 lx run / lx build / lx sync")

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        maven { url = uri("$lxSdk/bin/cache/artifacts/android/repo") }
    }
}

rootProject.name = "chaochuan"
include(":app")
