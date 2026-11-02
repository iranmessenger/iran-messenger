val mirrors = System.getenv("MAVEN_MIRRORS")?.split(",")?.filter { it.isNotBlank() } ?: emptyList()

allprojects {
    repositories {
        mirrors.forEach { maven { url = uri(it.trim()) } }
        google()
        mavenCentral()
    }

    // Flutter plugins declare their own buildscript repositories; add the
    // mirrors there too.
    buildscript {
        repositories {
            mirrors.forEach { maven { url = uri(it.trim()) } }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
