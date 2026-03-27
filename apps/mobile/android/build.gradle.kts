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

val patchCargokitRunScripts =
    tasks.register("patchCargokitRunScripts") {
        group = "build setup"
        description = "Patches Cargokit run scripts in pub cache so IDE-launched Gradle builds can find the correct Rust toolchain."

        doLast {
            val userHome = System.getProperty("user.home")
            val pubCache = File(userHome, ".pub-cache/hosted/pub.dev")
            if (!pubCache.exists()) {
                return@doLast
            }

            val marker = "# vibe-bridge-companion rust env"
            val snippet =
                """
$marker
export CARGO_HOME="$userHome/.cargo"
export RUSTUP_HOME="$userHome/.rustup"
case ":${'$'}PATH:" in
  *":${'$'}CARGO_HOME/bin:"*) ;;
  *) export PATH="${'$'}CARGO_HOME/bin:${'$'}PATH" ;;
esac
""".trimIndent()

            pubCache
                .walkTopDown()
                .filter { it.isFile && it.name == "run_build_tool.sh" && it.parentFile?.name == "cargokit" }
                .forEach { script ->
                    val original = script.readText()
                    val updatedWithSnippet =
                        if (original.contains(marker)) {
                            original.replace(
                                Regex("""(?ms)^# vibe-bridge-companion rust env\n.*?^esac\n"""),
                            ) {
                                "$snippet\n"
                            }
                        } else if (original.contains("set -e")) {
                            original.replaceFirst("set -e", "set -e\n\n$snippet")
                        } else {
                            "$snippet\n\n$original"
                        }

                    val normalizedScript =
                        updatedWithSnippet.replace(
                            "rm \"\$PACKAGE_HASH_FILE\"",
                            "rm -f \"\$PACKAGE_HASH_FILE\"",
                        )

                    if (normalizedScript == original) {
                        return@forEach
                    }
                    script.writeText(normalizedScript)
                }
        }
    }

val ensureRustAndroidTargets =
    tasks.register("ensureRustAndroidTargets") {
        group = "build setup"
        description = "Ensures Rust Android stdlib targets exist for Flutter plugins that build Rust code."

        doLast {
            val rustupFromDefaultHome = File(System.getProperty("user.home"), ".cargo/bin/rustup")
            val rustupExecutable =
                listOf(rustupFromDefaultHome)
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
            dependsOn(rootProject.tasks.named("patchCargokitRunScripts"))
            dependsOn(rootProject.tasks.named("ensureRustAndroidTargets"))
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
