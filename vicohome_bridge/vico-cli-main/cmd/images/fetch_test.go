package images

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var pngImage, _ = base64.StdEncoding.DecodeString("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgaPgPAAIDAYAkYfWXAAAAAElFTkSuQmCC")

func TestFetchSniffsImageDespiteGenericMIME(t *testing.T) {
	if _, err := png.Decode(bytes.NewReader(pngImage)); err != nil {
		t.Fatalf("invalid test image: %v", err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "binary/octet-stream")
		w.Write(pngImage)
	}))
	defer server.Close()
	output := filepath.Join(t.TempDir(), "snapshot")
	cmd := GetImagesCmd()
	var stdout bytes.Buffer
	cmd.SetIn(strings.NewReader(server.URL + "/bird?signature=SECRET"))
	cmd.SetOut(&stdout)
	cmd.SetArgs([]string{"fetch", "--output", output})
	if err := cmd.Execute(); err != nil {
		t.Fatal(err)
	}
	var meta Metadata
	if err := json.Unmarshal(stdout.Bytes(), &meta); err != nil {
		t.Fatal(err)
	}
	if meta.ContentType != "image/png" || meta.Bytes != len(pngImage) {
		t.Fatalf("metadata: %+v", meta)
	}
	data, _ := os.ReadFile(output)
	if !bytes.Equal(data, pngImage) {
		t.Fatal("image bytes changed")
	}
	if strings.Contains(stdout.String(), "SECRET") {
		t.Fatal("leaked signed URL")
	}
}

func TestFetchRejectsBadResponsesWithoutReplacingImage(t *testing.T) {
	for _, tt := range []struct {
		name   string
		status int
		body   []byte
	}{
		{"http error", 403, pngImage}, {"not an image", 200, []byte("<html>expired URL</html>")}, {"oversized", 200, append(append([]byte{}, pngImage...), bytes.Repeat([]byte{0}, maxImageBytes)...)}} {
		t.Run(tt.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(tt.status); w.Write(tt.body) }))
			defer server.Close()
			output := filepath.Join(t.TempDir(), "snapshot")
			os.WriteFile(output, []byte("previous image"), 0600)
			if _, err := fetchImage(server.URL+"?signature=SECRET", output); err == nil {
				t.Fatal("accepted failed download")
			} else if strings.Contains(err.Error(), "SECRET") {
				t.Fatal("leaked URL")
			}
			data, _ := os.ReadFile(output)
			if string(data) != "previous image" {
				t.Fatal("overwrote previous image")
			}
		})
	}
}
