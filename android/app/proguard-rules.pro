# R8 keep rules for the release build.
#
# The app is open source, so obfuscation isn't a goal — R8 is enabled for dead-code
# stripping + size. These rules protect the few things R8 can't see: JNI entry
# points and the sign callback the native layer invokes by name.

# --- JNI ---------------------------------------------------------------------
# Keep the names of every `external fun native*` so libssh2's symbol lookup
# (Java_cc_bsns_ssh_transport_SshBridge_native*) still resolves.
-keepclasseswithmembernames class * { native <methods>; }

# The native sign callback does GetMethodID(signerClass, "sign", "([B)[B") on the
# signer object, so the method name + signature must survive on every signer.
-keep,includedescriptorclasses class cc.bsns.ssh.transport.KeystoreSigner { byte[] sign(byte[]); }
-keep,includedescriptorclasses class cc.bsns.ssh.FileKeySigner { byte[] sign(byte[]); }
-keep,includedescriptorclasses class cc.bsns.ssh.YubiKeyPivKey { byte[] sign(byte[]); }
# FIDO2 sk keys sign via a different callback: GetMethodID(signer, "signSk", "([B)[B").
-keep,includedescriptorclasses class cc.bsns.ssh.FidoSkKey { byte[] signSk(byte[]); }

# --- Vendored Termux terminal (internal reflection) --------------------------
-keep class com.termux.** { *; }
-dontwarn com.termux.**

# --- Bouncy Castle (key math; provider + reflection) -------------------------
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

# --- SLF4J capture sink (loaded by ServiceLoader, so R8 can't see it) ---------
-keep class cc.bsns.ssh.diag.BsnsSlf4jProvider { *; }
-keep class cc.bsns.ssh.diag.** { *; }
-keep class org.slf4j.** { *; }
-dontwarn org.slf4j.**

# --- YubiKit (smartcard reflection) ------------------------------------------
-keep class com.yubico.** { *; }
-dontwarn javax.smartcardio.**
# yubikit references compile-only annotations (findbugs / JSR-305) not on the runtime classpath
-dontwarn edu.umd.cs.findbugs.annotations.**
-dontwarn javax.annotation.**

# --- kotlinx.serialization (ConfigEnvelope in :core) -------------------------
# The library ships its own rules, but keep our @Serializable types' generated
# serializers explicitly so the encrypted config bundle still (de)serializes.
-keepclassmembers class cc.bsns.ssh.core.** {
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
-keepclasseswithmembers class cc.bsns.ssh.core.** {
    public static kotlinx.serialization.KSerializer serializer(...);
}
