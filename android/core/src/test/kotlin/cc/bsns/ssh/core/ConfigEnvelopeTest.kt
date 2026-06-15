package cc.bsns.ssh.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ConfigEnvelopeTest {

    /**
     * The cross-platform contract: this envelope was produced by the iOS
     * `ConfigCrypto` (CryptoKit + CommonCrypto) — PBKDF2-SHA256/210k, AES-256-GCM,
     * fixed salt 00..0f, passphrase "test-pass-123". If Kotlin decrypts it to the
     * original plaintext, the KDF, AEAD, and envelope format all match iOS.
     */
    @Test fun decryptsRealIosVector() {
        val iosEnvelope = """
            {"combined":"U317mm8V3j0YNTDmuLSZOYvEpdQdTtOZZ6Bbkuc5J/oLk4JazgwD2PCQ2wQnwzfilK1EYtF7OAheF3iIqiw=","format":"bsns-config-aesgcm-v1","iterations":210000,"salt":"AAECAwQFBgcICQoLDA0ODw=="}
        """.trimIndent().toByteArray(Charsets.UTF_8)

        val plaintext = ConfigEnvelope.decrypt(iosEnvelope, "test-pass-123")
        assertEquals("hello bsns-ssh cross-platform sync", plaintext.toString(Charsets.UTF_8))
    }

    @Test fun wrongPassphraseFails() {
        val iosEnvelope = """
            {"combined":"U317mm8V3j0YNTDmuLSZOYvEpdQdTtOZZ6Bbkuc5J/oLk4JazgwD2PCQ2wQnwzfilK1EYtF7OAheF3iIqiw=","format":"bsns-config-aesgcm-v1","iterations":210000,"salt":"AAECAwQFBgcICQoLDA0ODw=="}
        """.trimIndent().toByteArray(Charsets.UTF_8)
        assertFailsWith<BadPassphraseException> { ConfigEnvelope.decrypt(iosEnvelope, "wrong") }
    }

    @Test fun roundTrips() {
        val secret = "my hosts and settings".toByteArray(Charsets.UTF_8)
        val blob = ConfigEnvelope.encrypt(secret, "hunter2")
        assertEquals("my hosts and settings", ConfigEnvelope.decrypt(blob, "hunter2").toString(Charsets.UTF_8))
    }

    @Test fun isEncryptedDiscriminates() {
        val blob = ConfigEnvelope.encrypt("x".toByteArray(), "p")
        assertTrue(ConfigEnvelope.isEncrypted(blob))
        // A plain config bundle (no envelope fields) is not "encrypted".
        assertFalse(ConfigEnvelope.isEncrypted("""{"hosts":[],"settings":{}}""".toByteArray()))
    }
}
