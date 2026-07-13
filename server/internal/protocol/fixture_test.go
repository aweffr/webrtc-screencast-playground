package protocol

import (
	"os"
	"path/filepath"
	"testing"
)

func TestProtocolV1FixturesDecode(t *testing.T) {
	t.Parallel()

	paths, err := filepath.Glob(filepath.Join("..", "..", "testdata", "protocol-v1", "*.json"))
	if err != nil {
		t.Fatalf("glob fixtures: %v", err)
	}
	if len(paths) != 10 {
		t.Fatalf("fixture count = %d, want 10", len(paths))
	}
	for _, path := range paths {
		path := path
		t.Run(filepath.Base(path), func(t *testing.T) {
			t.Parallel()
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read fixture: %v", err)
			}
			if _, _, err := Decode(data); err != nil {
				t.Fatalf("Decode fixture: %v", err)
			}
		})
	}
}
