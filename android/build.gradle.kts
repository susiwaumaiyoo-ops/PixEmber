allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// 全プラグインを JDK 21 に統一（evaluationDependsOn より前に置くこと！）
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { ext ->
            try {
                val base = ext as com.android.build.gradle.BaseExtension
                base.compileOptions.sourceCompatibility = JavaVersion.VERSION_21
                base.compileOptions.targetCompatibility = JavaVersion.VERSION_21
                if (base.namespace == null) {
                    base.namespace = "com.example.${project.name.replace("-", "_")}"
                }
            } catch (_: Exception) {
            }
        }
    }

    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21)
        }
    }

    tasks.withType<JavaCompile>().configureEach {
        sourceCompatibility = "21"
        targetCompatibility = "21"
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}