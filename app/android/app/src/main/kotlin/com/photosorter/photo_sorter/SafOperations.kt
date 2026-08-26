package com.photosorter.photo_sorter

import android.content.ContentResolver
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel

class SafOperations(
  private val resolver: ContentResolver,
  private val cacheDir: File,
  private val cancelled: MutableSet<String>,
) {
  private data class DocumentMeta(
    val documentId: String,
    val displayName: String,
    val mimeType: String,
    val isDirectory: Boolean,
    val size: Long?,
    val lastModified: Long?,
    val flags: Int,
  ) {
    fun toEntry(): Map<String, Any?> =
      SafCodec.entry(
        documentId = documentId,
        displayName = displayName,
        mimeType = mimeType,
        isDirectory = isDirectory,
        size = size,
        lastModified = lastModified,
      )
  }

  private data class ApiCopyDestination(
    val createdId: String,
    val destId: String,
  )

  fun takePersistable(args: Map<String, Any?>): Map<String, Any?> {
    val (treeUri, tree) = requireTree(args, "takePersistable")
    persistGrant(tree, treeUri, "takePersistable")
    return SafCodec.ok()
  }

  fun releasePersistable(args: Map<String, Any?>): Map<String, Any?> {
    val (_, tree) = requireTree(args, "releasePersistable")
    val persisted = findPersisted(tree)
    if (persisted != null) {
      try {
        resolver.releasePersistableUriPermission(
          persisted.uri,
          Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        )
      } catch (_: SecurityException) {
        // Missing grant is still success.
      }
    }
    return SafCodec.ok()
  }

  fun hasPersisted(args: Map<String, Any?>): Map<String, Any?> {
    val (_, tree) = requireTree(args, "hasPersisted")
    return SafCodec.okBool(hasAnyGrant(tree))
  }

  fun persistedTrees(): Map<String, Any?> {
    val trees = ArrayList<Map<String, Any?>>()
    for (permission in resolver.persistedUriPermissions) {
      val uri = permission.uri
      if (!isTreeUri(uri)) continue
      val documentId = DocumentsContract.getTreeDocumentId(uri)
      val displayName = try {
        queryDisplayName(uri, documentId)
      } catch (_: Exception) {
        ""
      }
      trees.add(
        mapOf(
          "treeUri" to uri.toString(),
          "documentId" to documentId,
          "displayName" to displayName,
        ),
      )
    }
    return SafCodec.treesResult(trees)
  }

  fun listChildren(args: Map<String, Any?>): Map<String, Any?> {
    val op = "listChildren"
    val (treeUri, tree) = requireTree(args, op)
    val documentId = requireDocId(args, "documentId")
    requireReadGrant(tree, treeUri, documentId, op)
    val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, documentId)
    val cursor = queryWithRetry(childrenUri, FULL_PROJECTION)
      ?: throw coded("not_found", "listChildren failed", op, treeUri, documentId)
    cursor.use { rows ->
      val idIdx = rows.getColumnIndex(COL_ID)
      if (idIdx < 0) {
        throw coded("io_failure", "listChildren failed", op, treeUri, documentId)
      }
      val entries = ArrayList<Map<String, Any?>>()
      while (rows.moveToNext()) {
        val meta = readMeta(rows) ?: continue
        entries.add(meta.toEntry())
      }
      return SafCodec.listEntries(entries)
    }
  }

  fun childByName(args: Map<String, Any?>): Map<String, Any?> {
    val op = "childByName"
    val (treeUri, tree) = requireTree(args, op)
    val parentDocumentId = requireDocId(args, "parentDocumentId")
    val name = SafCodec.requireFileName(SafCodec.requireString(args, "name"))
    requireReadGrant(tree, treeUri, parentDocumentId, op)
    requireDocument(tree, parentDocumentId, treeUri, op)
    val child = findChildByName(tree, parentDocumentId, name)
    return SafCodec.childResult(child?.toEntry())
  }

  fun createDirectory(args: Map<String, Any?>): Map<String, Any?> {
    val name = SafCodec.requireFileName(SafCodec.requireString(args, "name"))
    return createChild(
      args = args,
      op = "createDirectory",
      displayName = name,
      mimeType = DocumentsContract.Document.MIME_TYPE_DIR,
    )
  }

  fun createFile(args: Map<String, Any?>): Map<String, Any?> {
    val displayName = SafCodec.requireFileName(SafCodec.requireString(args, "displayName"))
    val mimeType = SafCodec.requireString(args, "mimeType").ifEmpty { "application/octet-stream" }
    return createChild(args, "createFile", displayName, mimeType)
  }

  fun delete(args: Map<String, Any?>): Map<String, Any?> {
    val op = "delete"
    val (treeUri, tree) = requireTree(args, op)
    val documentId = requireDocId(args, "documentId")
    requireWriteGrant(tree, treeUri, documentId, op)
    assertNotRoot(tree, documentId, treeUri, op)
    val meta = requireDocument(tree, documentId, treeUri, op)
    val uri = documentUri(tree, documentId)
    val deleted = DocumentsContract.deleteDocument(resolver, uri)
    if (!deleted) {
      val code =
        if (meta.flags and DocumentsContract.Document.FLAG_SUPPORTS_DELETE == 0) {
          "unsupported"
        } else {
          "io_failure"
        }
      throw coded(code, "delete failed", op, treeUri, documentId, meta.displayName)
    }
    return SafCodec.ok()
  }

  fun byteLength(args: Map<String, Any?>): Map<String, Any?> {
    val op = "byteLength"
    val (treeUri, tree) = requireTree(args, op)
    val documentId = requireDocId(args, "documentId")
    requireReadGrant(tree, treeUri, documentId, op)
    return SafCodec.sizeMap(documentByteLength(tree, documentId, treeUri, op))
  }

  fun readRange(args: Map<String, Any?>): ByteArray {
    val op = "readRange"
    val (treeUri, tree) = requireTree(args, op)
    val documentId = requireDocId(args, "documentId")
    val offset = SafCodec.requireLong(args, "offset")
    val length = SafCodec.requireLong(args, "length")
    if (offset < 0L || length < 0L) {
      throw coded("invalid_arg", "offset and length must be non-negative", op, treeUri, documentId)
    }
    requireReadGrant(tree, treeUri, documentId, op)
    val meta = requireDocument(tree, documentId, treeUri, op)
    if (meta.isDirectory) {
      throw coded("invalid_arg", "expected a file", op, treeUri, documentId)
    }
    val size = documentByteLength(tree, documentId, treeUri, op)
    if (offset > size) {
      throw coded("invalid_arg", "offset is past the end of the file", op, treeUri, documentId)
    }
    if (length == 0L || offset == size) {
      return ByteArray(0)
    }
    val toReadLong = minOf(length, size - offset)
    if (toReadLong > Int.MAX_VALUE) {
      throw coded("io_failure", "range too large", op, treeUri, documentId)
    }
    val toRead = toReadLong.toInt()
    val uri = documentUri(tree, documentId)
    val virtual = meta.flags and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT != 0
    if (virtual) {
      return readVirtualRange(uri, offset, toRead, treeUri, documentId, op)
    }
    val pfd = resolver.openFileDescriptor(uri, "r")
      ?: throw coded("not_found", "readRange failed", op, treeUri, documentId)
    return readRangeFromPfd(pfd, offset, toRead, treeUri, documentId, op)
  }

  fun writeBytes(args: Map<String, Any?>): Map<String, Any?> {
    val op = "writeBytes"
    val (treeUri, tree) = requireTree(args, op)
    val documentId = requireDocId(args, "documentId")
    val bytes = SafCodec.requireByteArray(args, "bytes")
    requireWriteGrant(tree, treeUri, documentId, op)
    val meta = requireDocument(tree, documentId, treeUri, op)
    if (meta.isDirectory) {
      throw coded("invalid_arg", "expected a file", op, treeUri, documentId)
    }
    val uri = documentUri(tree, documentId)
    val output = resolver.openOutputStream(uri, "wt")
      ?: throw coded("not_found", "writeBytes failed", op, treeUri, documentId)
    output.use { stream ->
      var index = 0
      while (index < bytes.size) {
        val n = minOf(SafCodec.COPY_BUFFER_BYTES, bytes.size - index)
        stream.write(bytes, index, n)
        index += n
      }
      stream.flush()
    }
    return SafCodec.ok()
  }

  fun copyTo(args: Map<String, Any?>): Map<String, Any?> {
    val op = "copyTo"
    val opId = SafCodec.requireOpId(args)
    try {
      val (srcTreeUri, srcTree) = requireTree(args, op, "srcTreeUri")
      val srcDocumentId = requireDocId(args, "srcDocumentId")
      val (destTreeUri, destTree) = requireTree(args, op, "destTreeUri")
      val destParentId = requireDocId(args, "destParentId")
      val destName = SafCodec.requireFileName(SafCodec.requireString(args, "destName"))
      val overwrite = SafCodec.requireBool(args, "overwrite")
      requireReadGrant(srcTree, srcTreeUri, srcDocumentId, op)
      requireWriteGrant(destTree, destTreeUri, destParentId, op)
      if (isCancelled(opId)) {
        throw coded("cancelled", "cancelled", op, srcTreeUri, srcDocumentId)
      }
      val copied = copyInternal(
        srcTree = srcTree,
        srcTreeUri = srcTreeUri,
        srcDocumentId = srcDocumentId,
        destTree = destTree,
        destTreeUri = destTreeUri,
        destParentId = destParentId,
        destName = destName,
        overwrite = overwrite,
        opId = opId,
        op = op,
      )
      return SafCodec.copyResult(copied.first, copied.second)
    } finally {
      cancelled.remove(opId)
    }
  }

  fun move(args: Map<String, Any?>): Map<String, Any?> {
    val op = "move"
    val (treeUri, tree) = requireTree(args, op)
    val documentId = requireDocId(args, "documentId")
    val destParentId = requireDocId(args, "destParentId")
    val destName = SafCodec.requireFileName(SafCodec.requireString(args, "destName"))
    val sourceParentRaw = SafCodec.optionalString(args, "sourceParentId")
    requireWriteGrant(tree, treeUri, documentId, op)
    assertNotRoot(tree, documentId, treeUri, op)
    val source = requireDocument(tree, documentId, treeUri, op)
    requireDocument(tree, destParentId, treeUri, op)
    val existingDest = findChildByName(tree, destParentId, destName)
    if (existingDest != null && existingDest.documentId != documentId) {
      throw coded("already_exists", "destination exists", op, treeUri, documentId, destName)
    }
    if (existingDest != null && existingDest.documentId == documentId && destName == source.displayName) {
      return SafCodec.moveResult("renamed", source.toEntry())
    }
    val resolvedParent = resolveSourceParentId(tree, treeUri, documentId, sourceParentRaw, op)
    if (
      resolvedParent != null &&
      resolvedParent == destParentId &&
      source.displayName == destName
    ) {
      return SafCodec.moveResult("renamed", source.toEntry())
    }
    val srcUri = documentUri(tree, documentId)
    if (
      resolvedParent != null &&
      resolvedParent == destParentId &&
      source.displayName != destName &&
      source.flags and DocumentsContract.Document.FLAG_SUPPORTS_RENAME != 0
    ) {
      val renamed = try {
        DocumentsContract.renameDocument(resolver, srcUri, destName)
      } catch (e: SecurityException) {
        throw e
      } catch (_: FileNotFoundException) {
        throwIfVerifiedInputGone(tree, documentId, treeUri, op)
        null
      }
      if (renamed != null) {
        val renamedId = DocumentsContract.getDocumentId(renamed)
        val meta = queryDocument(tree, renamedId)
        if (meta == null || meta.displayName != destName) {
          throw coded("incomplete_move", "move did not produce the destination name", op, treeUri, renamedId, destName)
        }
        return SafCodec.moveResult("renamed", meta.toEntry())
      }
    }
    if (
      resolvedParent != null &&
      resolvedParent != destParentId &&
      Build.VERSION.SDK_INT >= 24 &&
      source.flags and DocumentsContract.Document.FLAG_SUPPORTS_MOVE != 0
    ) {
      val moved = try {
        DocumentsContract.moveDocument(
          resolver,
          srcUri,
          documentUri(tree, resolvedParent),
          documentUri(tree, destParentId),
        )
      } catch (e: SecurityException) {
        throw e
      } catch (_: UnsupportedOperationException) {
        null
      } catch (_: FileNotFoundException) {
        throwIfVerifiedInputGone(tree, documentId, treeUri, op)
        throwIfVerifiedInputGone(tree, destParentId, treeUri, op)
        null
      }
      if (moved != null) {
        val leftover = findChildByName(tree, resolvedParent, source.displayName)
        if (leftover != null && leftover.documentId == documentId) {
          throw coded("incomplete_move", "same-tree move left the source in place", op, treeUri, documentId)
        }
        var movedId = DocumentsContract.getDocumentId(moved)
        var meta = queryDocument(tree, movedId)
        if (meta != null && meta.displayName != destName) {
          val renamed = try {
            DocumentsContract.renameDocument(resolver, documentUri(tree, movedId), destName)
          } catch (e: SecurityException) {
            throw e
          } catch (_: Exception) {
            null
          }
          if (renamed == null) {
            throw coded("incomplete_move", "move did not produce the destination name", op, treeUri, movedId, destName)
          }
          movedId = DocumentsContract.getDocumentId(renamed)
          meta = queryDocument(tree, movedId)
        }
        if (meta == null || meta.displayName != destName) {
          throw coded("incomplete_move", "move did not produce the destination name", op, treeUri, movedId, destName)
        }
        return SafCodec.moveResult("renamed", meta.toEntry())
      }
    }
    val copied = copyInternal(
      srcTree = tree,
      srcTreeUri = treeUri,
      srcDocumentId = documentId,
      destTree = tree,
      destTreeUri = treeUri,
      destParentId = destParentId,
      destName = destName,
      overwrite = false,
      opId = null,
      op = op,
    )
    val destEntry = copied.first
    try {
      val deleted = DocumentsContract.deleteDocument(resolver, srcUri)
      if (!deleted && documentExists(tree, documentId)) {
        throw coded("incomplete_move", "same-tree move left the source in place", op, treeUri, documentId)
      }
    } catch (e: SafCodedException) {
      throw e
    } catch (_: Exception) {
      if (documentExists(tree, documentId)) {
        throw coded("incomplete_move", "same-tree move left the source in place", op, treeUri, documentId)
      }
    }
    if (documentExists(tree, documentId)) {
      throw coded("incomplete_move", "same-tree move left the source in place", op, treeUri, documentId)
    }
    return SafCodec.moveResult("copiedAndDeleted", destEntry)
  }

  fun materializeToCache(args: Map<String, Any?>): Map<String, Any?> {
    val op = "materializeToCache"
    val opId = SafCodec.requireOpId(args)
    val dest = File(cacheDir, SafCodec.cacheFileNameForOpId(opId))
    try {
      val (treeUri, tree) = requireTree(args, op)
      val documentId = requireDocId(args, "documentId")
      requireReadGrant(tree, treeUri, documentId, op)
      val meta = requireDocument(tree, documentId, treeUri, op)
      if (meta.isDirectory) {
        throw coded("invalid_arg", "expected a file", op, treeUri, documentId)
      }
      if (isCancelled(opId)) {
        deleteQuietly(dest)
        throw coded("cancelled", "cancelled", op, treeUri, documentId)
      }
      val sourceSize = documentByteLength(tree, documentId, treeUri, op)
      val srcUri = documentUri(tree, documentId)
      val input = resolver.openInputStream(srcUri)
        ?: throw coded("not_found", "materializeToCache failed", op, treeUri, documentId)
      try {
        dest.outputStream().use { output ->
          input.use { stream ->
            val buffer = ByteArray(SafCodec.COPY_BUFFER_BYTES)
            while (true) {
              if (isCancelled(opId)) {
                throw coded("cancelled", "cancelled", op, treeUri, documentId)
              }
              val n = stream.read(buffer)
              if (n < 0) break
              output.write(buffer, 0, n)
            }
            output.flush()
          }
        }
      } catch (e: SafCodedException) {
        deleteQuietly(dest)
        throw e
      } catch (t: Throwable) {
        deleteQuietly(dest)
        throw t
      }
      if (dest.length() != sourceSize) {
        deleteQuietly(dest)
        throw coded("io_failure", "cache size mismatch", op, treeUri, documentId)
      }
      val cachePath = dest.absolutePath
      if (cachePath.isEmpty() || cachePath.indexOf('\u0000') >= 0) {
        deleteQuietly(dest)
        throw coded("io_failure", "missing cachePath", op, treeUri, documentId)
      }
      return SafCodec.cacheResult(cachePath, sourceSize)
    } finally {
      cancelled.remove(opId)
    }
  }

  fun deleteCache(args: Map<String, Any?>): Map<String, Any?> {
    val op = "deleteCache"
    val cachePath = SafCodec.requireString(args, "cachePath")
    if (cachePath.isEmpty() || cachePath.indexOf('\u0000') >= 0) {
      throw coded("invalid_arg", "invalid cache path", op)
    }
    val target = try {
      File(cachePath).canonicalFile
    } catch (_: IOException) {
      throw coded("invalid_arg", "invalid cache path", op)
    }
    val root = try {
      cacheDir.canonicalFile
    } catch (_: IOException) {
      throw coded("io_failure", "cache dir unavailable", op)
    }
    if (!target.path.startsWith(root.path + File.separator)) {
      throw coded("invalid_arg", "invalid cache path", op)
    }
    if (!SafCodec.isIssuedCacheFileName(target.name)) {
      throw coded("invalid_arg", "invalid cache path", op)
    }
    if (!target.exists()) {
      return SafCodec.ok()
    }
    if (!target.isFile) {
      throw coded("invalid_arg", "invalid cache path", op)
    }
    target.delete()
    return SafCodec.ok()
  }

  fun cancel(args: Map<String, Any?>): Map<String, Any?> {
    val opId = SafCodec.requireOpId(args)
    cancelled.add(opId)
    return SafCodec.ok()
  }

  fun persistPickedTree(uri: Uri): Map<String, Any?> {
    val treeUri = uri.toString()
    persistGrant(uri, treeUri, "pickTree")
    val documentId = DocumentsContract.getTreeDocumentId(uri)
    val displayName = try {
      queryDisplayName(uri, documentId)
    } catch (_: Exception) {
      ""
    }
    return SafCodec.pickResult(treeUri, documentId, displayName, hasWriteGrant(uri))
  }

  private fun createChild(
    args: Map<String, Any?>,
    op: String,
    displayName: String,
    mimeType: String,
  ): Map<String, Any?> {
    val (treeUri, tree) = requireTree(args, op)
    val parentDocumentId = requireDocId(args, "parentDocumentId")
    requireWriteGrant(tree, treeUri, parentDocumentId, op)
    requireDocument(tree, parentDocumentId, treeUri, op)
    if (findChildByName(tree, parentDocumentId, displayName) != null) {
      throw coded("already_exists", "already exists", op, treeUri, parentDocumentId, displayName)
    }
    val created = try {
      DocumentsContract.createDocument(
        resolver,
        documentUri(tree, parentDocumentId),
        mimeType,
        displayName,
      )
    } catch (e: SecurityException) {
      throw e
    } catch (_: FileNotFoundException) {
      throwIfVerifiedInputGone(tree, parentDocumentId, treeUri, op)
      throw coded("io_failure", "$op failed", op, treeUri, parentDocumentId, displayName)
    } ?: throw coded("io_failure", "$op failed", op, treeUri, parentDocumentId, displayName)
    val createdId = DocumentsContract.getDocumentId(created)
    val meta = queryDocument(tree, createdId)
    if (meta == null) {
      DocumentsContract.deleteDocument(resolver, documentUri(tree, createdId))
      throw coded("io_failure", "$op failed", op, treeUri, createdId, displayName)
    }
    if (meta.displayName != displayName) {
      DocumentsContract.deleteDocument(resolver, documentUri(tree, createdId))
      throw coded("already_exists", "already exists", op, treeUri, parentDocumentId, displayName)
    }
    return SafCodec.childResult(meta.toEntry())
  }

  private fun copyInternal(
    srcTree: Uri,
    srcTreeUri: String,
    srcDocumentId: String,
    destTree: Uri,
    destTreeUri: String,
    destParentId: String,
    destName: String,
    overwrite: Boolean,
    opId: String?,
    op: String,
  ): Pair<Map<String, Any?>, Long> {
    val source = requireDocument(srcTree, srcDocumentId, srcTreeUri, op)
    if (source.isDirectory) {
      throw coded("invalid_arg", "expected a file", op, srcTreeUri, srcDocumentId)
    }
    requireDocument(destTree, destParentId, destTreeUri, op)
    val existing = findChildByName(destTree, destParentId, destName)
    if (existing != null && existing.isDirectory) {
      throw coded("already_exists", "destination exists", op, destTreeUri, existing.documentId, destName)
    }
    if (existing != null && !overwrite) {
      throw coded("already_exists", "destination exists", op, destTreeUri, existing.documentId, destName)
    }
    val sourceSize = documentByteLength(srcTree, srcDocumentId, srcTreeUri, op)
    val srcUri = documentUri(srcTree, srcDocumentId)
    if (existing == null) {
      val apiDest = tryCopyDocumentApi(
        srcTree = srcTree,
        srcTreeUri = srcTreeUri,
        srcDocumentId = srcDocumentId,
        destTree = destTree,
        destTreeUri = destTreeUri,
        srcUri = srcUri,
        destParentId = destParentId,
        destName = destName,
        op = op,
      )
      if (apiDest != null) {
        if (opId != null && isCancelled(opId)) {
          confirmRemoveApiCopyDestination(
            destTree = destTree,
            destTreeUri = destTreeUri,
            createdId = apiDest.createdId,
            destId = apiDest.destId,
            destName = destName,
            op = op,
          )
          throw coded("cancelled", "cancelled", op, srcTreeUri, srcDocumentId)
        }
        val verified = verifyCopied(
          destTree,
          apiDest.destId,
          sourceSize,
          destTreeUri,
          op,
          destName,
          createdHere = true,
        )
        return verified.toEntry() to sourceSize
      }
    }
    val destId: String
    val createdHere: Boolean
    if (existing != null) {
      destId = existing.documentId
      createdHere = false
    } else {
      val created = try {
        DocumentsContract.createDocument(
          resolver,
          documentUri(destTree, destParentId),
          source.mimeType.ifEmpty { "application/octet-stream" },
          destName,
        )
      } catch (e: SecurityException) {
        throw e
      } catch (_: FileNotFoundException) {
        throwIfVerifiedInputGone(destTree, destParentId, destTreeUri, op)
        throw coded("io_failure", "copy failed", op, destTreeUri, destParentId, destName)
      } ?: throw coded("io_failure", "copy failed", op, destTreeUri, destParentId, destName)
      destId = DocumentsContract.getDocumentId(created)
      val createdMeta = queryDocument(destTree, destId)
      if (createdMeta == null || createdMeta.displayName != destName) {
        DocumentsContract.deleteDocument(resolver, documentUri(destTree, destId))
        throw coded("already_exists", "already exists", op, destTreeUri, destParentId, destName)
      }
      createdHere = true
    }
    val destUri = documentUri(destTree, destId)
    val mode = if (existing != null) "wt" else "w"
    try {
      if (opId != null && isCancelled(opId)) {
        throw coded("cancelled", "cancelled", op, srcTreeUri, srcDocumentId)
      }
      streamCopy(srcUri, destUri, mode, opId, srcTreeUri, srcDocumentId, op)
      val verified = verifyCopied(destTree, destId, sourceSize, destTreeUri, op, destName, createdHere)
      return verified.toEntry() to sourceSize
    } catch (e: SafCodedException) {
      if (createdHere) {
        DocumentsContract.deleteDocument(resolver, destUri)
      }
      throw e
    } catch (t: Throwable) {
      if (createdHere) {
        DocumentsContract.deleteDocument(resolver, destUri)
      }
      throw t
    }
  }

  private fun tryCopyDocumentApi(
    srcTree: Uri,
    srcTreeUri: String,
    srcDocumentId: String,
    destTree: Uri,
    destTreeUri: String,
    srcUri: Uri,
    destParentId: String,
    destName: String,
    op: String,
  ): ApiCopyDestination? {
    if (Build.VERSION.SDK_INT < 24) return null
    val srcAuth = srcTree.authority ?: return null
    val destAuth = destTree.authority ?: return null
    if (!srcAuth.equals(destAuth, ignoreCase = true)) return null
    val copied = try {
      DocumentsContract.copyDocument(resolver, srcUri, documentUri(destTree, destParentId))
    } catch (e: SecurityException) {
      throw e
    } catch (_: FileNotFoundException) {
      throwIfVerifiedInputGone(srcTree, srcDocumentId, srcTreeUri, op)
      throwIfVerifiedInputGone(destTree, destParentId, destTreeUri, op)
      return null
    } catch (_: Exception) {
      return null
    } ?: return null
    val createdId = DocumentsContract.getDocumentId(copied)
    val destId = finalizeApiCopyDestination(
      destTree = destTree,
      destTreeUri = destTreeUri,
      createdId = createdId,
      destName = destName,
      op = op,
    ) ?: return null
    return ApiCopyDestination(createdId = createdId, destId = destId)
  }

  private fun finalizeApiCopyDestination(
    destTree: Uri,
    destTreeUri: String,
    createdId: String,
    destName: String,
    op: String,
  ): String? {
    var destId = createdId
    try {
      var meta = queryDocument(destTree, destId)
      if (meta == null) {
        confirmRemoveApiCopyDestination(destTree, destTreeUri, createdId, destId, destName, op)
        return null
      }
      if (meta.displayName != destName) {
        val renamed = try {
          DocumentsContract.renameDocument(resolver, documentUri(destTree, destId), destName)
        } catch (e: SecurityException) {
          throw e
        } catch (_: Exception) {
          confirmRemoveApiCopyDestination(destTree, destTreeUri, createdId, destId, destName, op)
          return null
        }
        if (renamed == null) {
          confirmRemoveApiCopyDestination(destTree, destTreeUri, createdId, destId, destName, op)
          return null
        }
        destId = DocumentsContract.getDocumentId(renamed)
        meta = queryDocument(destTree, destId)
      }
      if (meta == null || meta.displayName != destName) {
        confirmRemoveApiCopyDestination(destTree, destTreeUri, createdId, destId, destName, op)
        return null
      }
      return destId
    } catch (e: SecurityException) {
      throw e
    } catch (e: SafCodedException) {
      throw e
    } catch (_: Exception) {
      confirmRemoveApiCopyDestination(destTree, destTreeUri, createdId, destId, destName, op)
      return null
    }
  }

  private fun confirmRemoveApiCopyDestination(
    destTree: Uri,
    destTreeUri: String,
    createdId: String,
    destId: String,
    destName: String,
    op: String,
  ) {
    confirmRemoveApiCopyId(destTree, destTreeUri, destId, destName, op)
    if (createdId != destId) {
      confirmRemoveApiCopyId(destTree, destTreeUri, createdId, destName, op)
    }
  }

  private fun confirmRemoveApiCopyId(
    destTree: Uri,
    destTreeUri: String,
    documentId: String,
    destName: String,
    op: String,
  ) {
    try {
      val deleted = DocumentsContract.deleteDocument(resolver, documentUri(destTree, documentId))
      if (!deleted) {
        throw coded(
          "io_failure",
          "could not remove API copy destination",
          op,
          destTreeUri,
          documentId,
          destName,
        )
      }
    } catch (e: SecurityException) {
      throw e
    } catch (e: SafCodedException) {
      throw e
    } catch (_: Exception) {
      // Delete threw. A later definitive absent query may count as removed.
    }
    val remaining = try {
      queryDocument(destTree, documentId)
    } catch (e: SecurityException) {
      throw e
    } catch (_: Exception) {
      throw coded(
        "io_failure",
        "could not confirm API copy destination removal",
        op,
        destTreeUri,
        documentId,
        destName,
      )
    }
    if (remaining != null) {
      throw coded(
        "io_failure",
        "could not remove API copy destination",
        op,
        destTreeUri,
        documentId,
        destName,
      )
    }
  }

  private fun verifyCopied(
    destTree: Uri,
    destId: String,
    sourceSize: Long,
    destTreeUri: String,
    op: String,
    destName: String,
    createdHere: Boolean,
  ): DocumentMeta {
    val destSize = try {
      documentByteLength(destTree, destId, destTreeUri, op)
    } catch (e: SafCodedException) {
      if (createdHere) {
        DocumentsContract.deleteDocument(resolver, documentUri(destTree, destId))
      }
      throw e
    }
    val readable = isReadable(destTree, destId)
    if (destSize != sourceSize || !readable) {
      if (createdHere) {
        DocumentsContract.deleteDocument(resolver, documentUri(destTree, destId))
      }
      throw coded("io_failure", "copy verify failed", op, destTreeUri, destId, destName)
    }
    return queryDocument(destTree, destId)
      ?: throw coded("io_failure", "copy verify failed", op, destTreeUri, destId, destName)
  }

  private fun streamCopy(
    srcUri: Uri,
    destUri: Uri,
    mode: String,
    opId: String?,
    srcTreeUri: String,
    srcDocumentId: String,
    op: String,
  ) {
    val input = resolver.openInputStream(srcUri)
      ?: throw coded("not_found", "copy failed", op, srcTreeUri, srcDocumentId)
    val output = resolver.openOutputStream(destUri, mode)
      ?: throw coded("not_found", "copy failed", op, srcTreeUri, srcDocumentId)
    input.use { inStream ->
      output.use { outStream ->
        val buffer = ByteArray(SafCodec.COPY_BUFFER_BYTES)
        while (true) {
          if (opId != null && isCancelled(opId)) {
            throw coded("cancelled", "cancelled", op, srcTreeUri, srcDocumentId)
          }
          val n = inStream.read(buffer)
          if (n < 0) break
          outStream.write(buffer, 0, n)
        }
        outStream.flush()
      }
    }
  }

  private fun resolveSourceParentId(
    tree: Uri,
    treeUri: String,
    documentId: String,
    provided: String?,
    op: String,
  ): String? {
    if (!provided.isNullOrEmpty()) {
      return SafCodec.requireDocumentId(provided, "sourceParentId")
    }
    if (Build.VERSION.SDK_INT < 26) return null
    return try {
      val path = DocumentsContract.findDocumentPath(resolver, documentUri(tree, documentId))
      val ids = path?.path
      when {
        ids == null -> null
        ids.size < 2 -> throw coded("invalid_arg", "cannot move tree root", op, treeUri, documentId)
        else -> ids[ids.size - 2]
      }
    } catch (e: SafCodedException) {
      throw e
    } catch (e: java.io.FileNotFoundException) {
      throw e
    } catch (_: Exception) {
      null
    }
  }

  private fun readVirtualRange(
    uri: Uri,
    offset: Long,
    toRead: Int,
    treeUri: String,
    documentId: String,
    op: String,
  ): ByteArray {
    try {
      val afd = resolver.openTypedAssetFileDescriptor(uri, "*/*", null)
      if (afd != null) {
        afd.use { descriptor ->
          descriptor.createInputStream().use { stream ->
            skipFully(stream, offset, treeUri, documentId, op)
            return readFromStream(stream, toRead, treeUri, documentId, op)
          }
        }
      }
    } catch (e: SafCodedException) {
      throw e
    } catch (_: Exception) {
      // Try the regular descriptor next.
    }
    try {
      val pfd = resolver.openFileDescriptor(uri, "r")
      if (pfd != null) {
        return readRangeFromPfd(pfd, offset, toRead, treeUri, documentId, op)
      }
    } catch (_: Exception) {
      // Both virtual open paths failed.
    }
    throw coded("unsupported", "virtual document unreadable", op, treeUri, documentId)
  }

  private fun readRangeFromPfd(
    pfd: ParcelFileDescriptor,
    offset: Long,
    toRead: Int,
    treeUri: String,
    documentId: String,
    op: String,
  ): ByteArray {
    val stream = ParcelFileDescriptor.AutoCloseInputStream(pfd)
    stream.use { input ->
      val channel = input.channel
      var seeked = false
      try {
        channel.position(offset)
        seeked = true
      } catch (_: IOException) {
        seeked = false
      }
      return if (seeked) {
        readFromChannel(channel, toRead, treeUri, documentId, op)
      } else {
        skipFully(input, offset, treeUri, documentId, op)
        readFromStream(input, toRead, treeUri, documentId, op)
      }
    }
  }

  private fun readFromChannel(
    channel: FileChannel,
    toRead: Int,
    treeUri: String,
    documentId: String,
    op: String,
  ): ByteArray {
    val result = ByteArray(toRead)
    val scratch = ByteArray(SafCodec.COPY_BUFFER_BYTES)
    var filled = 0
    while (filled < toRead) {
      val want = minOf(scratch.size, toRead - filled)
      val n = channel.read(ByteBuffer.wrap(scratch, 0, want))
      if (n < 0) {
        return result.copyOf(filled)
      }
      if (n == 0) {
        throw coded("io_failure", "short read", op, treeUri, documentId)
      }
      System.arraycopy(scratch, 0, result, filled, n)
      filled += n
    }
    return result
  }

  private fun readFromStream(
    stream: java.io.InputStream,
    toRead: Int,
    treeUri: String,
    documentId: String,
    op: String,
  ): ByteArray {
    val result = ByteArray(toRead)
    val scratch = ByteArray(SafCodec.COPY_BUFFER_BYTES)
    var filled = 0
    while (filled < toRead) {
      val want = minOf(scratch.size, toRead - filled)
      val n = stream.read(scratch, 0, want)
      if (n < 0) {
        return result.copyOf(filled)
      }
      if (n == 0) {
        throw coded("io_failure", "short read", op, treeUri, documentId)
      }
      System.arraycopy(scratch, 0, result, filled, n)
      filled += n
    }
    return result
  }

  private fun skipFully(
    stream: java.io.InputStream,
    offset: Long,
    treeUri: String,
    documentId: String,
    op: String,
  ) {
    val scratch = ByteArray(SafCodec.COPY_BUFFER_BYTES)
    var skipped = 0L
    while (skipped < offset) {
      val want = minOf(scratch.size.toLong(), offset - skipped).toInt()
      val n = stream.read(scratch, 0, want)
      if (n < 0) {
        throw coded("io_failure", "short skip", op, treeUri, documentId)
      }
      skipped += n.toLong()
    }
  }

  private fun persistGrant(uri: Uri, treeUri: String, op: String) {
    try {
      resolver.takePersistableUriPermission(
        uri,
        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
      )
    } catch (_: SecurityException) {
      try {
        resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
      } catch (_: SecurityException) {
        throw coded("permission_denied", "persist failed", op, treeUri)
      }
    }
  }

  private fun findPersisted(tree: Uri): android.content.UriPermission? {
    return resolver.persistedUriPermissions.firstOrNull { permission ->
      isTreeUri(permission.uri) && samePersistedTree(permission.uri, tree)
    }
  }

  private fun hasWriteGrant(tree: Uri): Boolean {
    val persisted = findPersisted(tree) ?: return false
    return persisted.isWritePermission
  }

  private fun hasAnyGrant(tree: Uri): Boolean = findPersisted(tree) != null

  private fun samePersistedTree(a: Uri, b: Uri): Boolean {
    val authA = a.authority ?: return false
    val authB = b.authority ?: return false
    if (!authA.equals(authB, ignoreCase = true)) return false
    return try {
      DocumentsContract.getTreeDocumentId(a) == DocumentsContract.getTreeDocumentId(b)
    } catch (_: Exception) {
      false
    }
  }

  private fun requireReadGrant(tree: Uri, treeUri: String, documentId: String?, op: String) {
    if (!hasAnyGrant(tree)) {
      throw coded("permission_denied", "missing persistable grant", op, treeUri, documentId)
    }
  }

  private fun requireWriteGrant(tree: Uri, treeUri: String, documentId: String?, op: String) {
    if (!hasAnyGrant(tree)) {
      throw coded("permission_denied", "missing persistable grant", op, treeUri, documentId)
    }
    if (!hasWriteGrant(tree)) {
      throw coded("read_only", "tree is read-only", op, treeUri, documentId)
    }
  }

  private fun requireTree(
    args: Map<String, Any?>,
    op: String,
    key: String = "treeUri",
  ): Pair<String, Uri> {
    val raw = SafCodec.requireContentUriString(SafCodec.requireString(args, key), key)
    val uri = Uri.parse(raw)
    if (!isTreeUri(uri)) {
      throw SafCodedException(
        "not_a_tree",
        "not a tree uri",
        SafErrors.details(op, treeUri = raw),
      )
    }
    return raw to uri
  }

  private fun requireDocId(args: Map<String, Any?>, key: String): String =
    SafCodec.requireDocumentId(SafCodec.requireString(args, key), key)

  private fun isTreeUri(uri: Uri): Boolean {
    return if (Build.VERSION.SDK_INT >= 24) {
      DocumentsContract.isTreeUri(uri)
    } else {
      SafCodec.looksLikeTreeUri(uri.toString())
    }
  }

  private fun documentUri(tree: Uri, documentId: String): Uri =
    DocumentsContract.buildDocumentUriUsingTree(tree, documentId)

  private fun assertNotRoot(tree: Uri, documentId: String, treeUri: String, op: String) {
    val rootId = DocumentsContract.getTreeDocumentId(tree)
    if (documentId == rootId) {
      throw coded("invalid_arg", "cannot modify tree root", op, treeUri, documentId)
    }
  }

  private fun requireDocument(
    tree: Uri,
    documentId: String,
    treeUri: String,
    op: String,
  ): DocumentMeta {
    return queryDocument(tree, documentId)
      ?: throw coded("not_found", "$op failed", op, treeUri, documentId)
  }

  private fun documentExists(tree: Uri, documentId: String): Boolean =
    queryDocument(tree, documentId) != null

  private fun documentByteLength(tree: Uri, documentId: String, treeUri: String, op: String): Long {
    val meta = requireDocument(tree, documentId, treeUri, op)
    if (meta.isDirectory) {
      throw coded("invalid_arg", "expected a file", op, treeUri, documentId)
    }
    if (meta.size != null && meta.size >= 0L) {
      return meta.size
    }
    val pfd = resolver.openFileDescriptor(documentUri(tree, documentId), "r")
      ?: throw coded("not_found", "byteLength failed", op, treeUri, documentId)
    ParcelFileDescriptor.AutoCloseInputStream(pfd).use { stream ->
      return stream.channel.size()
    }
  }

  private fun isReadable(tree: Uri, documentId: String): Boolean {
    return try {
      val pfd = resolver.openFileDescriptor(documentUri(tree, documentId), "r") ?: return false
      pfd.close()
      true
    } catch (_: Exception) {
      false
    }
  }

  private fun findChildByName(tree: Uri, parentDocumentId: String, name: String): DocumentMeta? {
    val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentDocumentId)
    val cursor = queryWithRetry(childrenUri, FULL_PROJECTION) ?: return null
    cursor.use { rows ->
      while (rows.moveToNext()) {
        val meta = readMeta(rows) ?: continue
        if (meta.displayName == name) {
          return meta
        }
      }
    }
    return null
  }

  private fun queryDocument(tree: Uri, documentId: String): DocumentMeta? {
    val cursor = queryWithRetry(documentUri(tree, documentId), FULL_PROJECTION) ?: return null
    cursor.use { rows ->
      if (!rows.moveToFirst()) return null
      return readMeta(rows)
    }
  }

  private fun queryDisplayName(tree: Uri, documentId: String): String {
    val cursor = queryWithRetry(
      documentUri(tree, documentId),
      arrayOf(COL_NAME),
    ) ?: return ""
    cursor.use { rows ->
      if (!rows.moveToFirst()) return ""
      return stringCol(rows, COL_NAME) ?: ""
    }
  }

  private fun queryWithRetry(uri: Uri, projection: Array<String>): Cursor? {
    return try {
      resolver.query(uri, projection, null, null, null)
    } catch (_: IllegalArgumentException) {
      resolver.query(uri, MIN_PROJECTION, null, null, null)
    }
  }

  private fun readMeta(cursor: Cursor): DocumentMeta? {
    val idIdx = cursor.getColumnIndex(COL_ID)
    if (idIdx < 0 || cursor.isNull(idIdx)) return null
    val documentId = cursor.getString(idIdx) ?: return null
    if (documentId.isEmpty()) return null
    val displayName = stringCol(cursor, COL_NAME) ?: ""
    val mimeRaw = stringCol(cursor, COL_MIME)
    val mimeType = if (mimeRaw.isNullOrEmpty()) {
      "application/octet-stream"
    } else {
      mimeRaw
    }
    val isDirectory = mimeType == DocumentsContract.Document.MIME_TYPE_DIR
    return DocumentMeta(
      documentId = documentId,
      displayName = displayName,
      mimeType = mimeType,
      isDirectory = isDirectory,
      size = longColIfPresent(cursor, COL_SIZE),
      lastModified = longColIfPresent(cursor, COL_MOD),
      flags = intCol(cursor, COL_FLAGS) ?: 0,
    )
  }

  private fun stringCol(cursor: Cursor, column: String): String? {
    val idx = cursor.getColumnIndex(column)
    if (idx < 0 || cursor.isNull(idx)) return null
    return cursor.getString(idx)
  }

  private fun longColIfPresent(cursor: Cursor, column: String): Long? {
    val idx = cursor.getColumnIndex(column)
    if (idx < 0 || cursor.isNull(idx)) return null
    val value = cursor.getLong(idx)
    return if (value >= 0L) value else null
  }

  private fun intCol(cursor: Cursor, column: String): Int? {
    val idx = cursor.getColumnIndex(column)
    if (idx < 0 || cursor.isNull(idx)) return null
    return cursor.getInt(idx)
  }

  private fun isCancelled(opId: String): Boolean = cancelled.contains(opId)

  private fun deleteQuietly(file: File) {
    try {
      file.delete()
    } catch (_: Exception) {
      // Best-effort cleanup.
    }
  }

  private fun throwIfVerifiedInputGone(
    tree: Uri,
    documentId: String,
    treeUri: String,
    op: String,
  ) {
    if (queryDocument(tree, documentId) == null) {
      throw coded("not_found", "$op failed", op, treeUri, documentId)
    }
  }

  private fun coded(
    code: String,
    message: String,
    op: String,
    treeUri: String? = null,
    documentId: String? = null,
    displayName: String? = null,
  ): SafCodedException =
    SafCodedException(code, message, SafErrors.details(op, treeUri, documentId, displayName))

  companion object {
    private const val COL_ID = DocumentsContract.Document.COLUMN_DOCUMENT_ID
    private const val COL_NAME = DocumentsContract.Document.COLUMN_DISPLAY_NAME
    private const val COL_MIME = DocumentsContract.Document.COLUMN_MIME_TYPE
    private const val COL_SIZE = DocumentsContract.Document.COLUMN_SIZE
    private const val COL_MOD = DocumentsContract.Document.COLUMN_LAST_MODIFIED
    private const val COL_FLAGS = DocumentsContract.Document.COLUMN_FLAGS
    private val FULL_PROJECTION = arrayOf(COL_ID, COL_NAME, COL_MIME, COL_SIZE, COL_MOD, COL_FLAGS)
    private val MIN_PROJECTION = arrayOf(COL_ID, COL_NAME, COL_MIME)
  }
}
