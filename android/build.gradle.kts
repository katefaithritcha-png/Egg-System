allprojects {
    repositories {
        google()
        mavenCentral()
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

// Align Kotlin JVM target with each plugin's Java target.
// tflite_flutter compiles Java 11; other Flutter plugins and the app use 17.
gradle.projectsEvaluated {
    rootProject.subprojects.forEach { subproject ->
        val javaVersion =
            subproject.extensions
                .findByType(com.android.build.gradle.BaseExtension::class.java)
                ?.compileOptions
                ?.targetCompatibility
        val alignedJvm =
            if (javaVersion == JavaVersion.VERSION_11) {
                org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11
            } else {
                org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
            }
        subproject.tasks
            .withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile::class.java)
            .configureEach {
                compilerOptions {
                    jvmTarget.set(alignedJvm)
                }
            }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
