package com.mrousavy.camera.utils.outputs

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.util.Log
import android.util.Size
import android.view.Surface
import com.mrousavy.camera.CameraQueues
import com.mrousavy.camera.extensions.closestToOrMax
import com.mrousavy.camera.extensions.getPreviewSize
import com.mrousavy.camera.frameprocessor.Frame
import com.mrousavy.camera.frameprocessor.FrameProcessor
import com.mrousavy.camera.parsers.Orientation
import java.io.Closeable
import java.lang.IllegalStateException

class CameraOutputs(val cameraId: String,
                    cameraManager: CameraManager,
                    val preview: PreviewOutput? = null,
                    val photo: PhotoOutput? = null,
                    val video: VideoOutput? = null,
                    val callback: Callback): Closeable {
  companion object {
    private const val TAG = "CameraOutputs"
    const val VIDEO_OUTPUT_BUFFER_SIZE = 3
    const val PHOTO_OUTPUT_BUFFER_SIZE = 3
  }

  data class PreviewOutput(val surface: Surface)
  data class PhotoOutput(val targetSize: Size? = null,
                         val format: Int = ImageFormat.JPEG)
  data class VideoOutput(val targetSize: Size? = null,
                         val enableRecording: Boolean = false,
                         val frameProcessor: FrameProcessor? = null,
                         val format: Int = ImageFormat.PRIVATE,
                         val hdrProfile: Long? = null /* DynamicRangeProfiles */)

  interface Callback {
    fun onPhotoCaptured(image: Image)
    fun onVideoFrameCaptured(image: Image)
  }

  var previewOutput: SurfaceOutput? = null
    private set
  var photoOutput: ImageReaderOutput? = null
    private set
  var videoOutput: SurfaceOutput? = null
    private set

  val size: Int
    get() {
      var size = 0
      if (previewOutput != null) size++
      if (photoOutput != null) size++
      if (videoOutput != null) size++
      return size
    }

  override fun equals(other: Any?): Boolean {
    if (other !is CameraOutputs) return false
    return this.cameraId == other.cameraId
      && (this.preview == null) == (other.preview == null)
      && this.photo?.targetSize == other.photo?.targetSize
      && this.photo?.format == other.photo?.format
      && this.video?.enableRecording == other.video?.enableRecording
      && this.video?.targetSize == other.video?.targetSize
      && this.video?.format == other.video?.format
  }

  override fun hashCode(): Int {
    var result = cameraId.hashCode()
    result += (preview?.hashCode() ?: 0)
    result += (photo?.hashCode() ?: 0)
    result += (video?.hashCode() ?: 0)
    return result
  }

  override fun close() {
    photoOutput?.close()
    videoOutput?.close()
  }

  override fun toString(): String {
    val strings = arrayListOf<String>()
    previewOutput?.let { strings.add(it.toString()) }
    photoOutput?.let { strings.add(it.toString()) }
    videoOutput?.let { strings.add(it.toString()) }
    return strings.joinToString(", ", "[", "]")
  }

  init {
    val characteristics = cameraManager.getCameraCharacteristics(cameraId)
    val config = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)!!

    Log.i(TAG, "Preparing Outputs for Camera $cameraId...")

    // Preview output: Low resolution repeating images (SurfaceView)
    if (preview != null) {
      Log.i(TAG, "Adding native preview view output.")
      previewOutput = SurfaceOutput(preview.surface, characteristics.getPreviewSize(), SurfaceOutput.OutputType.PREVIEW)
    }

    // Photo output: High quality still images (takePhoto())
    if (photo != null) {
      val size = config.getOutputSizes(photo.format).closestToOrMax(photo.targetSize)

      val imageReader = ImageReader.newInstance(size.width, size.height, photo.format, PHOTO_OUTPUT_BUFFER_SIZE)
      imageReader.setOnImageAvailableListener({ reader ->
        val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
        callback.onPhotoCaptured(image)
      }, CameraQueues.cameraQueue.handler)

      Log.i(TAG, "Adding ${size.width}x${size.height} photo output. (Format: ${photo.format})")
      photoOutput = ImageReaderOutput(imageReader, SurfaceOutput.OutputType.PHOTO)
    }

    // Video output: High resolution repeating images (startRecording() or useFrameProcessor())
    if (video != null) {
      val size = config.getOutputSizes(video.format).closestToOrMax(video.targetSize)

      val flags = HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_VIDEO_ENCODE
      val imageReader = ImageReader.newInstance(size.width, size.height, video.format, VIDEO_OUTPUT_BUFFER_SIZE, flags)
      imageReader.setOnImageAvailableListener({ reader ->
        try {
          val image = reader.acquireNextImage() ?: return@setOnImageAvailableListener
          callback.onVideoFrameCaptured(image)
        } catch (e: IllegalStateException) {
          Log.e(TAG, "Failed to acquire a new Image, dropping a Frame.. The Frame Processor cannot keep up with the Camera's FPS!", e)
        }
      }, CameraQueues.videoQueue.handler)

      Log.i(TAG, "Adding ${size.width}x${size.height} video output. (Format: ${video.format} | HDR: ${video.hdrProfile})")
      videoOutput = ImageReaderOutput(imageReader, SurfaceOutput.OutputType.VIDEO)
    }

    Log.i(TAG, "Prepared $size Outputs for Camera $cameraId!")
  }
}