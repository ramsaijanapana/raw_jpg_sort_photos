package com.photosorter.photo_sorter

import java.net.URI

class SafCodedException(
  val code: String,
  override val message: String,
  val details: Map<String, Any?>? = null,
) : RuntimeException(message)

object SafCodec {
  const val CHANNEL = "com.photosorter.photo_sorter/saf"
  const val COPY_BUFFER_BYTES = 65536
  const val CACHE_FILE_PREFIX = "ps_saf_"
  const val MAX_OP_ID_LEN = 120

  val ACCEPTED_ERROR_CODES: Set<String> = setOf(
    "already_exists",
    "cancelled",
    "incomplete_move",
    "invalid_arg",
    "io_failure",
    "not_found",
    "permission_denied",
    "quota",
    "read_only",
    "unsupported",
  )

  private val OP_ID_CHARS = Regex("^[A-Za-z0-9._-]+$")

  fun asArgMap(arguments: Any?): Map<String, Any?> {
    if (arguments == null) return emptyMap()
    if (arguments !is Map<*, *>) {
      throw invalidArg("arguments must be a map")
    }
    val out = LinkedHashMap<String, Any?>()
    for ((key, value) in arguments) {
      if (key !is String) {
        throw invalidArg("map keys must be strings")
      }
      out[key] = value
    }
    return out
  }

  fun optionalString(map: Map<String, Any?>, key: String): String? {
    if (!map.containsKey(key) || map[key] == null) return null
    val value = map[key]
    if (value !is String) {
      throw invalidArg("expected string for $key")
    }
    return value
  }

  fun requireString(map: Map<String, Any?>, key: String): String {
    val value = map[key]
    if (value !is String) {
      throw invalidArg("expected string for $key")
    }
    return value
  }

  fun requireNonEmptyString(map: Map<String, Any?>, key: String): String {
    val value = requireString(map, key)
    if (value.isEmpty() || value.indexOf('\u0000') >= 0) {
      throw invalidArg("expected nonempty string for $key")
    }
    return value
  }

  fun requireBool(map: Map<String, Any?>, key: String): Boolean {
    val value = map[key]
    if (value !is Boolean) {
      throw invalidArg("expected bool for $key")
    }
    return value
  }

  fun requireLong(map: Map<String, Any?>, key: String): Long {
    return when (val value = map[key]) {
      is Long -> value
      is Int -> value.toLong()
      else -> throw invalidArg("expected int for $key")
    }
  }

  fun requireByteArray(map: Map<String, Any?>, key: String): ByteArray {
    val value = map[key]
    if (value !is ByteArray) {
      throw invalidArg("expected bytes for $key")
    }
    return value
  }

  fun requireOpId(map: Map<String, Any?>): String = requireOpIdValue(requireString(map, "opId"))

  fun requireFileName(name: String): String {
    if (
      name.isEmpty() ||
      name.indexOf('\u0000') >= 0 ||
      name.indexOf('/') >= 0 ||
      name.indexOf('\\') >= 0 ||
      name == "." ||
      name == ".."
    ) {
      throw invalidArg("invalid file name")
    }
    return name
  }

  fun requireDocumentId(id: String, key: String = "documentId"): String {
    if (id.isEmpty() || id.indexOf('\u0000') >= 0) {
      throw invalidArg("invalid $key")
    }
    return id
  }

  fun requireContentUriString(uri: String, key: String): String {
    if (uri.isEmpty() || uri.indexOf('\u0000') >= 0) {
      throw invalidArg("invalid $key")
    }
    val parsed = try {
      URI(uri)
    } catch (_: Exception) {
      throw invalidArg("invalid $key")
    }
    val scheme = parsed.scheme ?: throw invalidArg("invalid $key")
    if (!scheme.equals("content", ignoreCase = true)) {
      throw invalidArg("invalid $key")
    }
    return uri
  }

  fun looksLikeTreeUri(treeUri: String): Boolean {
    val parsed = try {
      URI(treeUri)
    } catch (_: Exception) {
      return false
    }
    val scheme = parsed.scheme ?: return false
    if (!scheme.equals("content", ignoreCase = true)) return false
    val path = parsed.rawPath ?: parsed.path ?: return false
    val segments = path.split('/').filter { it.isNotEmpty() }
    return segments.size >= 2 && segments[0] == "tree"
  }

  fun normalizeTreeUri(treeUri: String): String {
    val uri = try {
      URI(treeUri)
    } catch (_: Exception) {
      throw invalidArg("invalid treeUri")
    }
    val scheme = (uri.scheme ?: "").lowercase()
    val authority = uri.authority
    val path = uri.rawPath ?: uri.path ?: ""
    return if (authority.isNullOrEmpty()) {
      "$scheme:$path"
    } else {
      "$scheme://${authority.lowercase()}$path"
    }
  }

  fun cacheFileNameForOpId(opId: String): String = "$CACHE_FILE_PREFIX$opId.bin"

  fun isIssuedCacheFileName(fileName: String): Boolean {
    if (!fileName.startsWith(CACHE_FILE_PREFIX) || !fileName.endsWith(".bin")) {
      return false
    }
    val opId = fileName.substring(CACHE_FILE_PREFIX.length, fileName.length - 4)
    return try {
      requireOpIdValue(opId)
      true
    } catch (_: SafCodedException) {
      false
    }
  }

  fun ok(): Map<String, Any?> = mapOf("ok" to true)

  fun okBool(value: Boolean): Map<String, Any?> = mapOf("ok" to value)

  fun sizeMap(size: Long): Map<String, Any?> = mapOf("size" to size)

  fun entry(
    documentId: String,
    displayName: String,
    mimeType: String,
    isDirectory: Boolean,
    size: Long? = null,
    lastModified: Long? = null,
  ): Map<String, Any?> {
    val map = LinkedHashMap<String, Any?>()
    map["documentId"] = documentId
    map["displayName"] = displayName
    map["mimeType"] = mimeType
    map["isDirectory"] = isDirectory
    if (size != null) {
      map["size"] = size
    }
    if (lastModified != null) {
      map["lastModified"] = lastModified
    }
    return map
  }

  fun listEntries(entries: List<Map<String, Any?>>): Map<String, Any?> = mapOf("entries" to entries)

  fun childResult(entry: Map<String, Any?>?): Map<String, Any?> {
    val map = HashMap<String, Any?>()
    map["entry"] = entry
    return map
  }

  fun moveResult(outcome: String, entry: Map<String, Any?>): Map<String, Any?> {
    if (outcome == "copiedSourceRemains" || (outcome != "renamed" && outcome != "copiedAndDeleted")) {
      throw invalidArg("invalid move outcome")
    }
    return mapOf("outcome" to outcome, "entry" to entry)
  }

  fun copyResult(entry: Map<String, Any?>, bytesCopied: Long): Map<String, Any?> =
    mapOf("entry" to entry, "bytesCopied" to bytesCopied)

  fun cacheResult(cachePath: String, size: Long): Map<String, Any?> =
    mapOf("cachePath" to cachePath, "size" to size)

  fun pickResult(
    treeUri: String,
    documentId: String,
    displayName: String,
    writeGranted: Boolean,
  ): Map<String, Any?> =
    mapOf(
      "treeUri" to treeUri,
      "documentId" to documentId,
      "displayName" to displayName,
      "writeGranted" to writeGranted,
    )

  fun treesResult(trees: List<Map<String, Any?>>): Map<String, Any?> = mapOf("trees" to trees)

  internal fun requireOpIdValue(value: String): String {
    if (
      value.isEmpty() ||
      value.indexOf('\u0000') >= 0 ||
      value.indexOf('/') >= 0 ||
      value.indexOf('\\') >= 0 ||
      value == "." ||
      value == ".." ||
      value.length > MAX_OP_ID_LEN ||
      !OP_ID_CHARS.matches(value)
    ) {
      throw invalidArg("invalid opId")
    }
    return value
  }

  private fun invalidArg(message: String): SafCodedException =
    SafCodedException("invalid_arg", message)
}
