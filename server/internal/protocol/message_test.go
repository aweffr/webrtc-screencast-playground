package protocol

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestNormalizePairingCode(t *testing.T) {
	t.Parallel()

	code, err := NormalizePairingCode(" 01ab-cd23 ")
	if err != nil {
		t.Fatalf("NormalizePairingCode returned error: %v", err)
	}
	if code != "01ABCD23" {
		t.Fatalf("code = %q, want %q", code, "01ABCD23")
	}
}

func TestNormalizePairingCodeRejectsAmbiguousOrWrongLength(t *testing.T) {
	t.Parallel()

	for _, input := range []string{"0123456", "012345678", "01234O67", "01234I67", "01234L67", "01234U67", "01234!67"} {
		if _, err := NormalizePairingCode(input); err == nil {
			t.Errorf("NormalizePairingCode(%q) unexpectedly succeeded", input)
		}
	}
}

func TestDecodeRegisterReceiver(t *testing.T) {
	t.Parallel()

	envelope, payload, err := Decode([]byte(`{"version":1,"message_id":"m-1","type":"receiver.register","payload":{}}`))
	if err != nil {
		t.Fatalf("Decode returned error: %v", err)
	}
	if envelope.Type != TypeReceiverRegister || envelope.MessageID != "m-1" {
		t.Fatalf("unexpected envelope: %#v", envelope)
	}
	if _, ok := payload.(ReceiverRegisterPayload); !ok {
		t.Fatalf("payload type = %T, want ReceiverRegisterPayload", payload)
	}
}

func TestEncodeDecodeRegisteredPayload(t *testing.T) {
	t.Parallel()

	want := ReceiverRegisteredPayload{
		SessionID:   "session-1",
		PairingCode: "01ABCD23",
		ExpiresAt:   time.Date(2026, 7, 14, 1, 2, 3, 0, time.UTC),
	}
	encoded, err := Encode("server-1", TypeReceiverRegistered, want)
	if err != nil {
		t.Fatalf("Encode returned error: %v", err)
	}
	envelope, decoded, err := Decode(encoded)
	if err != nil {
		t.Fatalf("Decode returned error: %v", err)
	}
	if envelope.Version != ProtocolVersion || envelope.MessageID != "server-1" {
		t.Fatalf("unexpected envelope: %#v", envelope)
	}
	got, ok := decoded.(ReceiverRegisteredPayload)
	if !ok {
		t.Fatalf("payload type = %T, want ReceiverRegisteredPayload", decoded)
	}
	if got != want {
		t.Fatalf("payload = %#v, want %#v", got, want)
	}
}

func TestDecodeRejectsInvalidEnvelope(t *testing.T) {
	t.Parallel()

	tests := map[string]string{
		"unsupported version": `{"version":2,"message_id":"m","type":"receiver.register","payload":{}}`,
		"missing message id":  `{"version":1,"message_id":"","type":"receiver.register","payload":{}}`,
		"long message id":     `{"version":1,"message_id":"` + strings.Repeat("x", MaxMessageIDLength+1) + `","type":"receiver.register","payload":{}}`,
		"unknown type":        `{"version":1,"message_id":"m","type":"room.join","payload":{}}`,
		"unknown field":       `{"version":1,"message_id":"m","type":"receiver.register","payload":{},"secret":"x"}`,
		"trailing json":       `{"version":1,"message_id":"m","type":"receiver.register","payload":{}} {}`,
	}
	for name, input := range tests {
		input := input
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if _, _, err := Decode([]byte(input)); err == nil {
				t.Fatal("Decode unexpectedly succeeded")
			}
		})
	}
}

func TestDecodeRejectsUnknownPayloadField(t *testing.T) {
	t.Parallel()

	input := `{"version":1,"message_id":"m","type":"sender.join","payload":{"pairing_code":"01ABCD23","admin":true}}`
	if _, _, err := Decode([]byte(input)); err == nil {
		t.Fatal("Decode unexpectedly succeeded")
	}
}

func TestDecodeRejectsOversizedSDPAndCandidate(t *testing.T) {
	t.Parallel()

	for name, test := range map[string]struct {
		typ     MessageType
		payload any
	}{
		"sdp":       {TypeSDPOffer, SDPPayload{SDP: strings.Repeat("s", MaxSDPLength+1)}},
		"candidate": {TypeICECandidate, ICECandidatePayload{Candidate: strings.Repeat("c", MaxICECandidateLength+1), SDPMid: "0", SDPMLineIndex: 0}},
	} {
		name, test := name, test
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			rawPayload, err := json.Marshal(test.payload)
			if err != nil {
				t.Fatal(err)
			}
			rawEnvelope, err := json.Marshal(Envelope{Version: 1, MessageID: "m", Type: test.typ, Payload: rawPayload})
			if err != nil {
				t.Fatal(err)
			}
			if _, _, err := Decode(rawEnvelope); err == nil {
				t.Fatal("Decode unexpectedly succeeded")
			}
		})
	}
}

func TestDecodeEveryMessageType(t *testing.T) {
	t.Parallel()

	tests := []struct {
		typ     MessageType
		payload any
	}{
		{TypeReceiverRegister, ReceiverRegisterPayload{}},
		{TypeReceiverRegistered, ReceiverRegisteredPayload{SessionID: "s", PairingCode: "01ABCD23", ExpiresAt: time.Now().UTC().Round(0)}},
		{TypeSenderJoin, SenderJoinPayload{PairingCode: "01ABCD23"}},
		{TypeSessionPaired, SessionPairedPayload{SessionID: "s", Role: RoleSender}},
		{TypeSDPOffer, SDPPayload{SDP: "v=0\r\n"}},
		{TypeSDPAnswer, SDPPayload{SDP: "v=0\r\n"}},
		{TypeICECandidate, ICECandidatePayload{Candidate: "candidate:1", SDPMid: "0", SDPMLineIndex: 0}},
		{TypeICEComplete, ICECompletePayload{}},
		{TypeSessionHangup, SessionHangupPayload{Reason: "done"}},
		{TypeError, ErrorPayload{Code: "invalid_message", Message: "invalid message", RelatedMessageID: "m"}},
	}

	for _, test := range tests {
		test := test
		t.Run(string(test.typ), func(t *testing.T) {
			t.Parallel()
			encoded, err := Encode("m", test.typ, test.payload)
			if err != nil {
				t.Fatalf("Encode returned error: %v", err)
			}
			if _, _, err := Decode(encoded); err != nil {
				t.Fatalf("Decode returned error: %v", err)
			}
		})
	}
}
