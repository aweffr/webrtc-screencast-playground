package cn.aweffr.webrtcscreencast.tv.observability;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;
import org.junit.Test;

public final class ReceiverAutomationChannelTest {
  @Test
  public void exposesOnlyTheCurrentCodeAndDeletesItAfterPairing() throws Exception {
    Path root = Files.createTempDirectory("receiver-automation");
    ReceiverAutomationChannel channel = new ReceiverAutomationChannel(root.toFile());

    channel.publishPairingCode("session-1", "AB12CD34");
    channel.publishPairingCode("session-2", "EF56GH78");

    Path file = root.resolve("automation.jsonl");
    assertTrue(Files.isRegularFile(file));
    JSONObject record = new JSONObject(
        new String(Files.readAllBytes(file), StandardCharsets.UTF_8).trim());
    assertEquals("receiver_registered", record.getString("event"));
    assertEquals("session-2", record.getString("session_id"));
    assertEquals("EF56GH78", record.getString("pairing_code"));
    assertEquals(1, Files.readAllLines(file).size());

    channel.clear();

    assertFalse(Files.exists(file));
  }

  @Test
  public void rejectsValuesThatCannotBeUsedByThePairingProtocol() throws Exception {
    Path root = Files.createTempDirectory("receiver-automation");
    ReceiverAutomationChannel channel = new ReceiverAutomationChannel(root.toFile());

    assertThrows(IllegalArgumentException.class,
        () -> channel.publishPairingCode("", "AB12CD34"));
    assertThrows(IllegalArgumentException.class,
        () -> channel.publishPairingCode("session-1", "contains-I"));
  }
}
