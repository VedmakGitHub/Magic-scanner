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

// Force every Android library module (e.g. opencv_core, which ships compiled
// against android-33 while its androidx deps require 34+) to compile against a
// modern SDK so AAR-metadata checks pass. Uses afterEvaluate so it overrides the
// module's own compileSdk, and is registered BEFORE evaluationDependsOn below so
// the callback is in place before evaluation is triggered. Dynamic (Groovy) call
// so the AGP type need not be on the root buildscript classpath.
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.withGroovyBuilder {
            "compileSdkVersion"(36)
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
