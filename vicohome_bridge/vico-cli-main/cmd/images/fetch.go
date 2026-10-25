// Package images downloads bounded snapshots without relying on cloud MIME headers.
package images

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/spf13/cobra"
)

const maxImageBytes = 8 * 1024 * 1024
const maxURLBytes = 16 * 1024

// Metadata describes the validated file without exposing its signed source URL.
type Metadata struct {
	ContentType string `json:"content_type"`
	Bytes       int    `json:"bytes"`
}

// GetImagesCmd creates the snapshot utility command. URLs arrive via stdin so
// signed query strings never appear in process arguments or shell history.
func GetImagesCmd() *cobra.Command {
	var output string
	root := &cobra.Command{Use: "images", Short: "Snapshot image utilities"}
	fetch := &cobra.Command{Use: "fetch", Short: "Download an image URL from stdin to a file", RunE: func(cmd *cobra.Command, args []string) error {
		input, err := io.ReadAll(io.LimitReader(cmd.InOrStdin(), maxURLBytes+1))
		if err != nil || len(input) > maxURLBytes {
			return fmt.Errorf("invalid image URL input")
		}
		meta, err := fetchImage(strings.TrimSpace(string(input)), output)
		if err != nil {
			return err
		}
		return json.NewEncoder(cmd.OutOrStdout()).Encode(meta)
	}}
	fetch.Flags().StringVar(&output, "output", "", "Output file path")
	fetch.MarkFlagRequired("output")
	root.AddCommand(fetch)
	return root
}

func fetchImage(source, output string) (Metadata, error) {
	var meta Metadata
	parsed, err := url.ParseRequestURI(source)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.User != nil {
		return meta, fmt.Errorf("image URL must use HTTP or HTTPS")
	}
	client := &http.Client{Timeout: 15 * time.Second}
	response, err := client.Get(source)
	if err != nil {
		return meta, fmt.Errorf("image download failed (connection, TLS, or timeout)")
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return meta, fmt.Errorf("image download returned HTTP %d", response.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, maxImageBytes+1))
	if err != nil {
		return meta, fmt.Errorf("could not read image response")
	}
	if len(data) > maxImageBytes {
		return meta, fmt.Errorf("image exceeds 8 MiB limit")
	}
	// Google Storage may return binary/octet-stream for a real JPEG. Determine
	// the type from the bytes, and reject HTML/error documents rather than retain them.
	meta = Metadata{ContentType: http.DetectContentType(data), Bytes: len(data)}
	if !strings.HasPrefix(meta.ContentType, "image/") {
		return Metadata{}, fmt.Errorf("downloaded response is not a supported image")
	}
	file, err := os.CreateTemp(filepath.Dir(output), ".snapshot-*")
	if err != nil {
		return Metadata{}, fmt.Errorf("could not create image file")
	}
	defer os.Remove(file.Name())
	if _, err = file.Write(data); err != nil {
		file.Close()
		return Metadata{}, fmt.Errorf("could not write image file")
	}
	if err = file.Close(); err != nil {
		return Metadata{}, fmt.Errorf("could not close image file")
	}
	if err = os.Rename(file.Name(), output); err != nil {
		return Metadata{}, fmt.Errorf("could not replace image file")
	}
	return meta, nil
}
