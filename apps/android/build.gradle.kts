// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
buildscript {
    configurations.getByName("classpath") {
        // Current plugins still pull vulnerable build-only libraries. Keep
        // their compatible patches until upstream raises these requirements.
        resolutionStrategy.force(
            "org.apache.commons:commons-lang3:3.21.0",
            "org.bouncycastle:bcpkix-jdk18on:1.86",
            "org.bouncycastle:bcprov-jdk18on:1.86",
            "org.bouncycastle:bcutil-jdk18on:1.86",
            "org.bitbucket.b_c:jose4j:0.9.7",
            "org.jdom:jdom2:2.0.6.1",
        )
    }
}

plugins {
    id("com.android.application") version "9.4.1" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.21" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.4.21" apply false
    id("com.google.gms.google-services") version "4.5.0" apply false
    id("com.google.devtools.ksp") version "2.3.12" apply false
}
