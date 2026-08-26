package com.photosorter.photo_sorter

import android.os.OperationCanceledException
import android.system.ErrnoException
import android.system.OsConstants
import java.io.FileNotFoundException
import java.io.IOException

object SafErrors {
  private val QUOTA_MESSAGE = Regex("(?i)(no space|ENOSPC|EDQUOT|disk full)")

  fun details(
    op: String,
    treeUri: String? = null,
    documentId: String? = null,
    displayName: String? = null,
    extra: Map<String, Any?> = emptyMap(),
  ): HashMap<String, Any?> {
    val map = HashMap<String, Any?>()
    map["op"] = op
    if (treeUri != null) {
      map["treeUri"] = treeUri
    }
    if (documentId != null) {
      map["documentId"] = documentId
    }
    if (displayName != null) {
      map["displayName"] = displayName
    }
    map.putAll(extra)
    return map
  }

  fun mapThrowable(
    t: Throwable,
    op: String,
    treeUri: String? = null,
    documentId: String? = null,
    readOnlyGrant: Boolean = false,
  ): SafCodedException {
    if (t is SafCodedException) {
      return t
    }
    val code = when {
      t is SecurityException -> if (readOnlyGrant) "read_only" else "permission_denied"
      t is FileNotFoundException -> "not_found"
      t is UnsupportedOperationException -> "unsupported"
      t is IllegalArgumentException -> "invalid_arg"
      t is OperationCanceledException -> "cancelled"
      t is InterruptedException -> "cancelled"
      isQuotaErrno(t) -> "quota"
      t is IOException && t.message?.let { QUOTA_MESSAGE.containsMatchIn(it) } == true -> "quota"
      t is OutOfMemoryError -> "io_failure"
      else -> "io_failure"
    }
    val message = t.message?.takeIf { it.isNotEmpty() } ?: "$op failed"
    return SafCodedException(code, message, details(op, treeUri, documentId))
  }

  private fun isQuotaErrno(t: Throwable): Boolean {
    var current: Throwable? = t
    while (current != null) {
      if (current is ErrnoException && isQuotaErrnoCode(current.errno)) {
        return true
      }
      current = current.cause
    }
    return false
  }

  private fun isQuotaErrnoCode(errno: Int): Boolean {
    if (errno == OsConstants.ENOSPC) return true
    return try {
      errno == OsConstants.EDQUOT
    } catch (_: Throwable) {
      false
    }
  }
}
