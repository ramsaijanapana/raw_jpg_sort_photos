package com.photosorter.photo_sorter

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class PhotoSorterSafPlugin :
  FlutterPlugin,
  MethodChannel.MethodCallHandler,
  ActivityAware,
  PluginRegistry.ActivityResultListener {

  private val cancelled = ConcurrentHashMap.newKeySet<String>()
  private val mainHandler = Handler(Looper.getMainLooper())

  private var channel: MethodChannel? = null
  private var executor: ExecutorService? = null
  private var ops: SafOperations? = null
  private var activity: Activity? = null
  private var activityBinding: ActivityPluginBinding? = null
  private var pendingPick: MethodChannel.Result? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    val context = binding.applicationContext
    ops = SafOperations(context.contentResolver, context.cacheDir, cancelled)
    val methodChannel = MethodChannel(binding.binaryMessenger, SafCodec.CHANNEL)
    methodChannel.setMethodCallHandler(this)
    channel = methodChannel
    executor = Executors.newSingleThreadExecutor { runnable ->
      Thread(runnable, "photo-sorter-saf").apply { isDaemon = true }
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel?.setMethodCallHandler(null)
    channel = null
    completePendingPickNull()
    executor?.shutdown()
    executor = null
    ops = null
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    attachActivity(binding)
  }

  override fun onDetachedFromActivityForConfigChanges() {
    detachActivity(completePending = false)
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    attachActivity(binding)
  }

  override fun onDetachedFromActivity() {
    detachActivity(completePending = true)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "cancel" -> handleOnPlatformThread(call, result)
      "pickTree" -> launchPick(call, result)
      "takePersistable",
      "releasePersistable",
      "persistedTrees",
      "hasPersisted",
      "listChildren",
      "childByName",
      "createDirectory",
      "createFile",
      "delete",
      "move",
      "copyTo",
      "readRange",
      "byteLength",
      "writeBytes",
      "materializeToCache",
      "deleteCache" -> runIo(call, result)
      else -> mainHandler.post { result.notImplemented() }
    }
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    if (requestCode != REQ_PICK_TREE) return false
    val pending = pendingPick ?: return false
    pendingPick = null
    if (resultCode != Activity.RESULT_OK || data == null) {
      postSuccess(pending, null)
      return true
    }
    val uri = data.data
    if (uri == null) {
      postError(pending, SafCodedException("io_failure", "pickTree failed", SafErrors.details("pickTree")))
      return true
    }
    val operations = ops
    val exec = executor
    if (operations == null || exec == null) {
      postSuccess(pending, null)
      return true
    }
    exec.execute {
      try {
        postSuccess(pending, operations.persistPickedTree(uri))
      } catch (t: Throwable) {
        postError(pending, SafErrors.mapThrowable(t, "pickTree"))
      }
    }
    return true
  }

  private fun launchPick(call: MethodCall, result: MethodChannel.Result) {
    try {
      if (pendingPick != null) {
        throw SafCodedException("invalid_arg", "pick already pending", SafErrors.details("pickTree"))
      }
      val host = activity
        ?: throw SafCodedException("invalid_arg", "no activity", SafErrors.details("pickTree"))
      val args = SafCodec.asArgMap(call.arguments)
      val title = SafCodec.optionalString(args, "title")
      val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        if (!title.isNullOrEmpty()) {
          putExtra(Intent.EXTRA_TITLE, title)
        }
      }
      pendingPick = result
      @Suppress("DEPRECATION")
      host.startActivityForResult(intent, REQ_PICK_TREE)
    } catch (e: ActivityNotFoundException) {
      if (pendingPick === result) {
        pendingPick = null
      }
      postError(
        result,
        SafCodedException("unsupported", e.message ?: "no document picker", SafErrors.details("pickTree")),
      )
    } catch (t: Throwable) {
      if (pendingPick === result) {
        pendingPick = null
      }
      postError(result, SafErrors.mapThrowable(t, "pickTree"))
    }
  }

  private fun runIo(call: MethodCall, result: MethodChannel.Result) {
    val exec = executor
    if (exec == null) {
      postError(result, SafCodedException("io_failure", "plugin detached", SafErrors.details(call.method)))
      return
    }
    exec.execute {
      try {
        postSuccess(result, dispatch(call))
      } catch (t: Throwable) {
        postError(result, SafErrors.mapThrowable(t, call.method))
      }
    }
  }

  private fun handleOnPlatformThread(call: MethodCall, result: MethodChannel.Result) {
    try {
      postSuccess(result, dispatch(call))
    } catch (t: Throwable) {
      postError(result, SafErrors.mapThrowable(t, call.method))
    }
  }

  private fun dispatch(call: MethodCall): Any? {
    val operations = ops ?: throw SafCodedException("io_failure", "plugin detached", SafErrors.details(call.method))
    val args = argsFor(call)
    return when (call.method) {
      "takePersistable" -> operations.takePersistable(args)
      "releasePersistable" -> operations.releasePersistable(args)
      "persistedTrees" -> operations.persistedTrees()
      "hasPersisted" -> operations.hasPersisted(args)
      "listChildren" -> operations.listChildren(args)
      "childByName" -> operations.childByName(args)
      "createDirectory" -> operations.createDirectory(args)
      "createFile" -> operations.createFile(args)
      "delete" -> operations.delete(args)
      "move" -> operations.move(args)
      "copyTo" -> operations.copyTo(args)
      "readRange" -> operations.readRange(args)
      "byteLength" -> operations.byteLength(args)
      "writeBytes" -> operations.writeBytes(args)
      "materializeToCache" -> operations.materializeToCache(args)
      "deleteCache" -> operations.deleteCache(args)
      "cancel" -> operations.cancel(args)
      else -> throw SafCodedException("unsupported", "unknown method", SafErrors.details(call.method))
    }
  }

  private fun argsFor(call: MethodCall): Map<String, Any?> {
    if (call.arguments == null && call.method != "pickTree" && call.method != "persistedTrees") {
      throw SafCodedException("invalid_arg", "missing arguments", SafErrors.details(call.method))
    }
    return SafCodec.asArgMap(call.arguments)
  }

  private fun attachActivity(binding: ActivityPluginBinding) {
    activityBinding = binding
    activity = binding.activity
    binding.addActivityResultListener(this)
  }

  private fun detachActivity(completePending: Boolean) {
    activityBinding?.removeActivityResultListener(this)
    activityBinding = null
    activity = null
    if (completePending) {
      completePendingPickNull()
    }
  }

  private fun completePendingPickNull() {
    val pending = pendingPick
    pendingPick = null
    if (pending != null) {
      postSuccess(pending, null)
    }
  }

  private fun postSuccess(result: MethodChannel.Result, value: Any?) {
    mainHandler.post { result.success(value) }
  }

  private fun postError(result: MethodChannel.Result, error: SafCodedException) {
    mainHandler.post { result.error(error.code, error.message, error.details) }
  }

  companion object {
    const val REQ_PICK_TREE = 0x50534631
  }
}
