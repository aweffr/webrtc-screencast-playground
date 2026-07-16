package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
	"unicode"
)

const (
	ProtocolVersion       = 1
	MaxMessageIDLength    = 64
	MaxSDPLength          = 128 * 1024
	MaxICECandidateLength = 16 * 1024
	MaxReasonLength       = 256
	PairingCodeLength     = 8
)

type MessageType string

const (
	TypeReceiverRegister   MessageType = "receiver.register"
	TypeReceiverRegistered MessageType = "receiver.registered"
	TypeSenderJoin         MessageType = "sender.join"
	TypeSessionPaired      MessageType = "session.paired"
	TypeSDPOffer           MessageType = "sdp.offer"
	TypeSDPAnswer          MessageType = "sdp.answer"
	TypeICECandidate       MessageType = "ice.candidate"
	TypeICEComplete        MessageType = "ice.complete"
	TypeSessionHangup      MessageType = "session.hangup"
	TypeError              MessageType = "error"
)

type Role string

const (
	RoleReceiver Role = "receiver"
	RoleSender   Role = "sender"
)

type Envelope struct {
	Version   int             `json:"version"`
	MessageID string          `json:"message_id"`
	Type      MessageType     `json:"type"`
	Payload   json.RawMessage `json:"payload"`
}

type ReceiverRegisterPayload struct{}

type ReceiverRegisteredPayload struct {
	SessionID   string    `json:"session_id"`
	PairingCode string    `json:"pairing_code"`
	ExpiresAt   time.Time `json:"expires_at"`
}

type SenderJoinPayload struct {
	PairingCode string `json:"pairing_code"`
}

type SessionPairedPayload struct {
	SessionID string `json:"session_id"`
	Role      Role   `json:"role"`
}

type SDPPayload struct {
	SDP string `json:"sdp"`
}

type ICECandidatePayload struct {
	Candidate     string `json:"candidate"`
	SDPMid        string `json:"sdp_mid"`
	SDPMLineIndex int32  `json:"sdp_mline_index"`
}

type ICECompletePayload struct{}

type SessionHangupPayload struct {
	Reason string `json:"reason,omitempty"`
}

type ErrorPayload struct {
	Code             string `json:"code"`
	Message          string `json:"message"`
	RelatedMessageID string `json:"related_message_id,omitempty"`
}

var (
	ErrInvalidEnvelope = errors.New("invalid signaling envelope")
	ErrInvalidPayload  = errors.New("invalid signaling payload")
	ErrInvalidCode     = errors.New("invalid pairing code")
)

func NormalizePairingCode(input string) (string, error) {
	var builder strings.Builder
	for _, r := range strings.ToUpper(input) {
		if r == '-' || unicode.IsSpace(r) {
			continue
		}
		builder.WriteRune(r)
	}
	code := builder.String()
	if len(code) != PairingCodeLength {
		return "", ErrInvalidCode
	}
	const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
	for _, r := range code {
		if !strings.ContainsRune(alphabet, r) {
			return "", ErrInvalidCode
		}
	}
	return code, nil
}

func Encode(messageID string, typ MessageType, payload any) ([]byte, error) {
	rawPayload, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("%w: encode payload: %v", ErrInvalidPayload, err)
	}
	rawEnvelope, err := json.Marshal(Envelope{
		Version:   ProtocolVersion,
		MessageID: messageID,
		Type:      typ,
		Payload:   rawPayload,
	})
	if err != nil {
		return nil, fmt.Errorf("%w: encode envelope: %v", ErrInvalidEnvelope, err)
	}
	if _, _, err := Decode(rawEnvelope); err != nil {
		return nil, err
	}
	return rawEnvelope, nil
}

func Decode(data []byte) (Envelope, any, error) {
	var envelope Envelope
	if err := decodeStrict(data, &envelope); err != nil {
		return Envelope{}, nil, fmt.Errorf("%w: %v", ErrInvalidEnvelope, err)
	}
	if envelope.Version != ProtocolVersion {
		return Envelope{}, nil, fmt.Errorf("%w: unsupported version", ErrInvalidEnvelope)
	}
	if len(envelope.MessageID) == 0 || len(envelope.MessageID) > MaxMessageIDLength {
		return Envelope{}, nil, fmt.Errorf("%w: invalid message_id", ErrInvalidEnvelope)
	}
	if len(envelope.Payload) == 0 {
		return Envelope{}, nil, fmt.Errorf("%w: payload is required", ErrInvalidEnvelope)
	}

	payload, err := decodePayload(envelope.Type, envelope.Payload)
	if err != nil {
		return Envelope{}, nil, err
	}
	return envelope, payload, nil
}

func decodePayload(typ MessageType, data []byte) (any, error) {
	switch typ {
	case TypeReceiverRegister:
		return decodeAndValidate[ReceiverRegisterPayload](data, func(ReceiverRegisterPayload) error { return nil })
	case TypeReceiverRegistered:
		return decodeAndValidate[ReceiverRegisteredPayload](data, func(payload ReceiverRegisteredPayload) error {
			if payload.SessionID == "" || payload.ExpiresAt.IsZero() {
				return errors.New("session_id and expires_at are required")
			}
			_, err := NormalizePairingCode(payload.PairingCode)
			return err
		})
	case TypeSenderJoin:
		return decodeAndValidate[SenderJoinPayload](data, func(payload SenderJoinPayload) error {
			_, err := NormalizePairingCode(payload.PairingCode)
			return err
		})
	case TypeSessionPaired:
		return decodeAndValidate[SessionPairedPayload](data, func(payload SessionPairedPayload) error {
			if payload.SessionID == "" || (payload.Role != RoleReceiver && payload.Role != RoleSender) {
				return errors.New("session_id and valid role are required")
			}
			return nil
		})
	case TypeSDPOffer, TypeSDPAnswer:
		return decodeAndValidate[SDPPayload](data, func(payload SDPPayload) error {
			if payload.SDP == "" || len(payload.SDP) > MaxSDPLength {
				return errors.New("sdp is empty or too large")
			}
			return nil
		})
	case TypeICECandidate:
		return decodeAndValidate[ICECandidatePayload](data, func(payload ICECandidatePayload) error {
			if payload.Candidate == "" || len(payload.Candidate) > MaxICECandidateLength {
				return errors.New("candidate is empty or too large")
			}
			if len(payload.SDPMid) > 256 || payload.SDPMLineIndex < 0 {
				return errors.New("invalid candidate location")
			}
			return nil
		})
	case TypeICEComplete:
		return decodeAndValidate[ICECompletePayload](data, func(ICECompletePayload) error { return nil })
	case TypeSessionHangup:
		return decodeAndValidate[SessionHangupPayload](data, func(payload SessionHangupPayload) error {
			if len(payload.Reason) > MaxReasonLength {
				return errors.New("hangup reason is too large")
			}
			return nil
		})
	case TypeError:
		return decodeAndValidate[ErrorPayload](data, func(payload ErrorPayload) error {
			if payload.Code == "" || payload.Message == "" || len(payload.Code) > 64 || len(payload.Message) > 512 || len(payload.RelatedMessageID) > MaxMessageIDLength {
				return errors.New("invalid error payload")
			}
			return nil
		})
	default:
		return nil, fmt.Errorf("%w: unsupported type", ErrInvalidEnvelope)
	}
}

func decodeAndValidate[T any](data []byte, validate func(T) error) (any, error) {
	var payload T
	if err := decodeStrict(data, &payload); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidPayload, err)
	}
	if err := validate(payload); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidPayload, err)
	}
	return payload, nil
}

func decodeStrict(data []byte, destination any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple JSON values")
		}
		return err
	}
	return nil
}
