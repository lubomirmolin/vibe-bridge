import java.io.File
import org.gradle.api.GradleException

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val rustAndroidTargets =
    listOf(
        "aarch64-linux-android",
        "armv7-linux-androideabi",
        "x86_64-linux-android",
        "i686-linux-android",
    )

val ensureRustAndroidTargets =
    tasks.register("ensureRustAndroidTargets") {
        group = "build setup"
        description = "Ensures Rust Android stdlib targets exist for Flutter plugins that build Rust code."

        doLast {
            val rustupFromCargoHome =
                System.getenv("CARGO_HOME")?.let { File(it, "bin/rustup") }
            val rustupFromDefaultHome = File(System.getProperty("user.home"), ".cargo/bin/rustup")
            val rustupExecutable =
                listOfNotNull(rustupFromCargoHome, rustupFromDefaultHome)
                    .firstOrNull { it.exists() }
                    ?.absolutePath
                    ?: "rustup"

            try {
                exec {
                    commandLine(
                        listOf(
                            rustupExecutable,
                            "target",
                            "add",
                            "--toolchain",
                            "stable",
                        ) + rustAndroidTargets,
                    )
                }
            } catch (error: Exception) {
                throw GradleException(
                    "Failed to install required Rust Android targets via `$rustupExecutable`. " +
                        "Ensure Rustup is installed and accessible to Gradle.",
                    error,
                )
            }
        }
    }

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

subprojects {
    tasks.configureEach {
        if (name.startsWith("cargokitCargoBuild")) {
            dependsOn(rootProject.tasks.named("ensureRustAndroidTargets"))
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
