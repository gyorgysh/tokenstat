// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.localization

import org.junit.Assert.assertEquals
import org.junit.Test

class LanguageCatalogTest {
    @Test fun languagePreferenceAndRegionalFallback() {
        val tables = mapOf(
            "en/common" to mapOf("shared" to "English", "fallback" to "Still English", "platform" to "Common"),
            "en/android" to mapOf("platform" to "Android"),
            "hu/common" to mapOf("shared" to "Magyar", "base" to "Base language"),
            "hu-HU/android" to mapOf("shared" to "Regional", "platform" to "Regional Android"),
            "zh-Hant/android" to mapOf("shared" to "Script language"),
        )
        fun catalog(vararg languages: String) = LanguageCatalog.load(languages.toList()) { language, table ->
            tables["$language/$table"] ?: emptyMap()
        }
        val regional = catalog("hu_HU", "en")
        assertEquals("Regional", regional.text("shared"))
        assertEquals("Base language", regional.text("base"))
        assertEquals("Regional Android", regional.text("platform"))
        assertEquals("Still English", regional.text("fallback"))
        assertEquals("Magyar", catalog("zz", "hu").text("shared"))
        assertEquals("English", catalog("en-US", "hu").text("shared"))
        assertEquals("Android", catalog("zz").text("platform"))
        assertEquals("Script language", catalog("zh-Hant-TW").text("shared"))
    }

    @Test fun placeholdersDoNotInterpretInsertedValues() {
        val catalog = LanguageCatalog(mapOf("message" to "Á😀 {1}: {0} / {1} · 100%", "overflow" to "{999999999999999999999}"))
        assertEquals("Á😀 \$5% \\ path: {1} / \$5% \\ path · 100%", catalog.text("message", listOf("{1}", "\$5% \\ path")))
        assertEquals("Á😀 {1}: {0} / {1} · 100%", catalog.text("message"))
        assertEquals("{999999999999999999999}", catalog.text("overflow", listOf("x")))
        assertEquals("missing", catalog.text("missing"))
    }

    @Test fun englishResourcesAreOnTheAppClasspath() {
        assertEquals("Cancel", L10n.text("common.cancel"))
    }

    @Test fun malformedTablesCannotReplaceEnglishWithNonStringValues() {
        for (source in listOf("{", "[]", "{\"shared\":null}", "{\"shared\":42}", "{\"shared\":false}")) {
            val catalog = LanguageCatalog.load(listOf("xx")) { language, _ ->
                if (language == "en") mapOf("shared" to "English") else LanguageCatalog.decode(source)
            }
            assertEquals("English", catalog.text("shared"))
        }
        assertEquals(mapOf("shared" to "Magyar"), LanguageCatalog.decode("{\"shared\":\"Magyar\"}"))
    }
}
