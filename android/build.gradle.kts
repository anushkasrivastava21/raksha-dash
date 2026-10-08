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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

subprojects {
    val proj = this

    tasks.withType(JavaCompile::class.java).configureEach {
        sourceCompatibility = "11"
        targetCompatibility = "11"
    }

    tasks.matching { it.name.contains("Kotlin") }.configureEach {
        try {
            val compilerOptions = property("compilerOptions")
            val getJvmTarget = compilerOptions?.javaClass?.getMethod("getJvmTarget")?.invoke(compilerOptions)
            val setMethod = getJvmTarget?.javaClass?.getMethod("set", Any::class.java)
            val jvmTargetClass = Class.forName("org.jetbrains.kotlin.gradle.dsl.JvmTarget")
            val jvm11 = jvmTargetClass.getField("JVM_11").get(null)
            setMethod?.invoke(getJvmTarget, jvm11)
        } catch (_: Throwable) {
            try {
                val kotlinOptions = property("kotlinOptions")
                val setJvmTarget = kotlinOptions?.javaClass?.getMethod("setJvmTarget", String::class.java)
                setJvmTarget?.invoke(kotlinOptions, "11")
            } catch (_: Throwable) {}
        }
    }

    val configureAndroid: () -> Unit = {
        if (plugins.hasPlugin("com.android.application") || plugins.hasPlugin("com.android.library")) {
            val androidExt = extensions.findByName("android")
            if (androidExt != null) {
                try {
                    val getNamespace = androidExt.javaClass.getMethod("getNamespace")
                    val currentNs = getNamespace.invoke(androidExt) as? String
                    if (currentNs.isNullOrEmpty()) {
                        val setNamespace = androidExt.javaClass.getMethod("setNamespace", String::class.java)
                        setNamespace.invoke(androidExt, "com.example.${proj.name.replace('-', '_')}")
                    }
                } catch (_: Throwable) {}

                try {
                    val compileOptions = androidExt.javaClass.getMethod("getCompileOptions").invoke(androidExt)
                    val setSource = compileOptions.javaClass.getMethod("setSourceCompatibility", JavaVersion::class.java)
                    val setTarget = compileOptions.javaClass.getMethod("setTargetCompatibility", JavaVersion::class.java)
                    setSource.invoke(compileOptions, JavaVersion.VERSION_11)
                    setTarget.invoke(compileOptions, JavaVersion.VERSION_11)
                } catch (_: Throwable) {}
            }
        }
    }

    if (state.executed) {
        configureAndroid()
    } else {
        afterEvaluate { configureAndroid() }
    }
}

