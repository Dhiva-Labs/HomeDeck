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

// Some plugins (porcupine_flutter) still declare an ancient compileSdk that
// current AndroidX libraries refuse to build against. Lift every library
// module to the app's compileSdk.
fun liftCompileSdk(p: Project) {
    p.extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)
        ?.apply { compileSdk = 36 }
}

subprojects {
    // Must run after the plugin's own script (which pins the old value), and
    // some subprojects are already evaluated here thanks to
    // evaluationDependsOn(":app") above.
    if (state.executed) liftCompileSdk(this) else afterEvaluate { liftCompileSdk(this) }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
