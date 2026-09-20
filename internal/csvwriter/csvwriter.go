// Package csvwriter provides concurrency-safe CSV output for benchmark samples.
package csvwriter

import (
	"encoding/csv"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

type Writer struct {
	mu     sync.Mutex
	file   *os.File
	writer *csv.Writer
}

func New(path string, header []string) (*Writer, error) {
	if path == "" {
		return &Writer{}, nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, fmt.Errorf("create output directory: %w", err)
	}
	file, err := os.Create(path)
	if err != nil {
		return nil, fmt.Errorf("create CSV output: %w", err)
	}
	writer := csv.NewWriter(file)
	if err := writer.Write(header); err != nil {
		file.Close()
		return nil, fmt.Errorf("write CSV header: %w", err)
	}
	writer.Flush()
	if err := writer.Error(); err != nil {
		file.Close()
		return nil, fmt.Errorf("flush CSV header: %w", err)
	}
	return &Writer{file: file, writer: writer}, nil
}

func (w *Writer) Write(record []string) error {
	if w.writer == nil {
		return nil
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if err := w.writer.Write(record); err != nil {
		return err
	}
	w.writer.Flush()
	return w.writer.Error()
}

func (w *Writer) Close() error {
	if w.file == nil {
		return nil
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	w.writer.Flush()
	if err := w.writer.Error(); err != nil {
		w.file.Close()
		return err
	}
	return w.file.Close()
}
