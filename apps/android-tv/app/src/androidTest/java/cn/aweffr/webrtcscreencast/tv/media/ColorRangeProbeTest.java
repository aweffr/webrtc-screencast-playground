package cn.aweffr.webrtcscreencast.tv.media;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import android.content.Context;
import android.graphics.ImageFormat;
import android.media.Image;
import android.media.ImageReader;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.SystemClock;
import android.util.Log;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.security.MessageDigest;
import java.util.Arrays;
import org.junit.Test;
import org.junit.runner.RunWith;

@RunWith(AndroidJUnit4.class)
public final class ColorRangeProbeTest {
  private static final String TAG = "ColorRangeProbe";
  private static final int WIDTH = 448;
  private static final int HEIGHT = 256;
  private static final int[] VIDEO_CODES = {
    16, 17, 29, 30, 31, 43, 71, 126, 171, 204, 218, 222, 234, 235
  };

  @Test
  public void videoRangeStreamsAreStableAcrossHardwareDecoderSurfaces() throws Exception {
    probe("h264_420v", "video/avc", VIDEO_CODES, VIDEO_CODES);
    probe("hevc_420v", "video/hevc", VIDEO_CODES, VIDEO_CODES);
  }

  private static void probe(
      String identifier, String mime, int[] sourceCodes, int[] expectedSurfaceCodes)
      throws Exception {
    byte[] stream = readAsset("color-range/" + identifier + ".annexb");
    ImageReader reader = ImageReader.newInstance(WIDTH, HEIGHT, ImageFormat.YUV_420_888, 2);
    MediaCodec codec = MediaCodec.createDecoderByType(mime);
    MediaFormat requested = MediaFormat.createVideoFormat(mime, WIDTH, HEIGHT);
    MediaFormat outputFormat = null;
    Image image = null;
    try {
      codec.configure(requested, reader.getSurface(), null, 0);
      codec.start();
      int inputIndex = codec.dequeueInputBuffer(5_000_000);
      assertTrue("decoder did not expose an input buffer", inputIndex >= 0);
      ByteBuffer input = codec.getInputBuffer(inputIndex);
      assertNotNull(input);
      assertTrue("encoded fixture exceeds decoder input capacity", input.capacity() >= stream.length);
      input.put(stream);
      codec.queueInputBuffer(inputIndex, 0, stream.length, 0, MediaCodec.BUFFER_FLAG_KEY_FRAME);

      MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
      long deadline = SystemClock.elapsedRealtime() + 10_000;
      while (SystemClock.elapsedRealtime() < deadline && image == null) {
        int outputIndex = codec.dequeueOutputBuffer(info, 250_000);
        if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
          outputFormat = codec.getOutputFormat();
        } else if (outputIndex >= 0) {
          codec.releaseOutputBuffer(outputIndex, true);
          image = awaitImage(reader, deadline);
        }
      }
      assertNotNull("decoder produced no YUV surface image for " + identifier, image);
      if (outputFormat == null) {
        outputFormat = codec.getOutputFormat();
      }
      int[] actual = samplePatchMedians(image, expectedSurfaceCodes.length);
      Log.i(
          TAG,
          identifier
              + " codec="
              + codec.getName()
              + " sha256="
              + sha256(stream)
              + " colorRange="
              + integerOrNull(outputFormat, MediaFormat.KEY_COLOR_RANGE)
              + " colorStandard="
              + integerOrNull(outputFormat, MediaFormat.KEY_COLOR_STANDARD)
              + " colorTransfer="
              + integerOrNull(outputFormat, MediaFormat.KEY_COLOR_TRANSFER)
              + " source="
              + Arrays.toString(sourceCodes)
              + " expectedSurface="
              + Arrays.toString(expectedSurfaceCodes)
              + " actual="
              + Arrays.toString(actual));
      for (int index = 0; index < expectedSurfaceCodes.length; ++index) {
        assertEquals(
            identifier + " patch " + index,
            expectedSurfaceCodes[index],
            actual[index],
            2);
      }
    } finally {
      if (image != null) {
        image.close();
      }
      try {
        codec.stop();
      } finally {
        codec.release();
        reader.close();
      }
    }
  }

  private static Image awaitImage(ImageReader reader, long deadline) {
    Image image;
    while ((image = reader.acquireLatestImage()) == null
        && SystemClock.elapsedRealtime() < deadline) {
      SystemClock.sleep(10);
    }
    return image;
  }

  private static int[] samplePatchMedians(Image image, int patchCount) {
    Image.Plane yPlane = image.getPlanes()[0];
    ByteBuffer y = yPlane.getBuffer();
    int rowStride = yPlane.getRowStride();
    int pixelStride = yPlane.getPixelStride();
    int patchWidth = WIDTH / patchCount;
    int[] result = new int[patchCount];
    for (int patch = 0; patch < patchCount; ++patch) {
      int[] samples = new int[64];
      int sample = 0;
      int centerX = patch * patchWidth + patchWidth / 2;
      int centerY = HEIGHT / 2;
      for (int row = -4; row < 4; ++row) {
        for (int column = -4; column < 4; ++column) {
          int offset = (centerY + row) * rowStride + (centerX + column) * pixelStride;
          samples[sample++] = y.get(offset) & 0xff;
        }
      }
      Arrays.sort(samples);
      result[patch] = (samples[31] + samples[32] + 1) / 2;
    }
    return result;
  }

  private static Integer integerOrNull(MediaFormat format, String key) {
    return format.containsKey(key) ? format.getInteger(key) : null;
  }

  private static byte[] readAsset(String path) throws Exception {
    Context context = InstrumentationRegistry.getInstrumentation().getContext();
    try (InputStream input = context.getAssets().open(path);
        ByteArrayOutputStream output = new ByteArrayOutputStream()) {
      byte[] buffer = new byte[4096];
      int count;
      while ((count = input.read(buffer)) != -1) {
        output.write(buffer, 0, count);
      }
      return output.toByteArray();
    }
  }

  private static String sha256(byte[] value) throws Exception {
    byte[] digest = MessageDigest.getInstance("SHA-256").digest(value);
    StringBuilder result = new StringBuilder(digest.length * 2);
    for (byte item : digest) {
      result.append(String.format("%02x", item));
    }
    return result.toString();
  }
}
