# Shorten package names for classes eligible for obfuscation.
-repackageclasses ''

# JNI entry points use this fully qualified class name.
-keep class ai.tokenstat.tokenstat.core.NativeBridge { *; }
