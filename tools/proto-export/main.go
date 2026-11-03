package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"

	"github.com/jhump/protoreflect/desc"
	"github.com/jhump/protoreflect/desc/protoprint"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/descriptorpb"
)

type roots struct {
	Protocol []string `json:"protocol"`
	Playback []string `json:"playback"`
	Library  []string `json:"library"`
	Entities []string `json:"entities"`
}

type descriptorRecord struct {
	File         string   `json:"file"`
	Offset       int64    `json:"offset"`
	Length       int      `json:"length"`
	SHA256       string   `json:"sha256"`
	Package      string   `json:"package"`
	Dependencies []string `json:"dependencies"`
}

type sourceEvidence struct {
	Source  string             `json:"source"`
	SHA256  string             `json:"sha256"`
	Records []descriptorRecord `json:"records"`
}

type fileManifest struct {
	descriptorRecord
	DescriptorSetOffset int    `json:"descriptorSetOffset"`
	SourcePath          string `json:"sourcePath"`
	SourceSHA256        string `json:"sourceSha256,omitempty"`
	Syntax              string `json:"syntax"`
}

type artifact struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
}

type manifest struct {
	SchemaVersion          int            `json:"schemaVersion"`
	SourceExecutable       string         `json:"sourceExecutable"`
	SourceExecutableSHA256 string         `json:"sourceExecutableSha256"`
	DescriptorSet          artifact       `json:"descriptorSet"`
	Roots                  roots          `json:"roots"`
	Files                  []fileManifest `json:"files"`
	Printer                string         `json:"printer"`
}

func main() {
	repo := flag.String("repo", "../..", "repository root")
	extract := flag.Bool("extract", false, "re-extract exact selected descriptors from the installed executable")
	printSources := flag.Bool("print", false, "write readable schema sources from the portable descriptor set")
	validate := flag.Bool("validate", false, "recompile sources and compare descriptors and Dart output")
	dartPlugin := flag.String("dart-plugin", "", "optional existing protoc-gen-dart executable for validation")
	reconstructLite := flag.Bool("reconstruct-lite", false, "reconstruct separately labelled Login5 schemas from lite metadata and pinned references")
	dartPresence := flag.Bool("dart-presence", false, "emit exact-descriptor-confirmed Dart proto3 syntax and scalar presence metadata")
	presenceOutput := flag.String("presence-out", "", "Dart presence output path; stdout when empty")
	flag.Parse()
	if *dartPresence {
		if *reconstructLite {
			fmt.Fprintln(os.Stderr, "-dart-presence and -reconstruct-lite are separate operations")
			os.Exit(1)
		}
		if err := writeDartPresence(*repo, *presenceOutput); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if *reconstructLite {
		if err := reconstructLogin5(*repo); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if err := run(*repo, *extract, *printSources, *validate, *dartPlugin); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(repo string, extract, printSources, validate bool, dartPlugin string) error {
	root, err := filepath.Abs(repo)
	if err != nil {
		return fmt.Errorf("resolve repository %q: %w", repo, err)
	}
	manifestPath := filepath.Join(root, "proto/manifest.json")
	if extract {
		if err := extractDescriptors(root, manifestPath); err != nil {
			return err
		}
	}
	var input manifest
	if err := readJSON(manifestPath, &input); err != nil {
		return err
	}
	set, err := verifyPortable(root, input, !printSources)
	if err != nil {
		return err
	}
	if printSources {
		if err := writeSources(root, set, &input); err != nil {
			return err
		}
		if err := writeJSON(manifestPath, input); err != nil {
			return err
		}
	}
	if validate {
		if err := validateSources(root, set, input, dartPlugin); err != nil {
			return err
		}
	}
	fmt.Printf("Verified %d exact portable descriptors (%s).\n", len(set.File), input.DescriptorSet.SHA256)
	return nil
}

func extractDescriptors(root, manifestPath string) error {
	var evidence sourceEvidence
	if err := readJSON(filepath.Join(root, "reverse-engineering/evidence/protocol-descriptors.json"), &evidence); err != nil {
		return err
	}
	var selectedRoots roots
	if err := readJSON(filepath.Join(root, "tools/proto-export/roots.json"), &selectedRoots); err != nil {
		return err
	}
	digest, err := hashFile(evidence.Source)
	if err != nil {
		return err
	}
	if digest != evidence.SHA256 {
		return fmt.Errorf("executable %q SHA-256 is %s; require %s", evidence.Source, digest, evidence.SHA256)
	}
	executable, err := os.Open(evidence.Source)
	if err != nil {
		return fmt.Errorf("open executable %q: %w", evidence.Source, err)
	}
	defer executable.Close()
	records := make(map[string]descriptorRecord, len(evidence.Records))
	for _, record := range evidence.Records {
		records[record.File] = record
	}
	rawFiles := map[string][]byte{}
	descriptors := map[string]*descriptorpb.FileDescriptorProto{}
	var visit func(string) error
	visit = func(name string) error {
		if rawFiles[name] != nil {
			return nil
		}
		record, ok := records[name]
		if !ok || record.Offset < 0 || record.Length <= 0 {
			return fmt.Errorf("descriptor record %q is missing or invalid", name)
		}
		if err := validName(name); err != nil {
			return err
		}
		raw := make([]byte, record.Length)
		if _, err := executable.ReadAt(raw, record.Offset); err != nil {
			return fmt.Errorf("read descriptor %q at %d: %w", name, record.Offset, err)
		}
		if digest := hashBytes(raw); digest != record.SHA256 {
			return fmt.Errorf("descriptor %q SHA-256 is %s; require %s", name, digest, record.SHA256)
		}
		var file descriptorpb.FileDescriptorProto
		if err := proto.Unmarshal(raw, &file); err != nil {
			return fmt.Errorf("decode descriptor %q: %w", name, err)
		}
		if file.GetName() != name || !slices.Equal(file.Dependency, record.Dependencies) {
			return fmt.Errorf("descriptor %q name/dependencies disagree with static evidence", name)
		}
		rawFiles[name], descriptors[name] = raw, &file
		for _, dependency := range file.Dependency {
			if err := visit(dependency); err != nil {
				return err
			}
		}
		return nil
	}
	for _, name := range slices.Concat(selectedRoots.Protocol, selectedRoots.Playback, selectedRoots.Library, selectedRoots.Entities) {
		if err := visit(name); err != nil {
			return err
		}
	}
	if len(rawFiles) != 115 {
		return fmt.Errorf("selected closure has %d files; require the selected 115-file protocol, playback, library and entity scope", len(rawFiles))
	}
	names := make([]string, 0, len(rawFiles))
	for name := range rawFiles {
		names = append(names, name)
	}
	sort.Strings(names)
	output := manifest{SchemaVersion: 1, SourceExecutable: evidence.Source,
		SourceExecutableSHA256: evidence.SHA256, Roots: selectedRoots,
		DescriptorSet: artifact{Path: "reverse-engineering/protobuf/original.pbdesc"},
		Printer:       "github.com/jhump/protoreflect/desc/protoprint v1.18.0"}
	var encoded []byte
	for _, name := range names {
		raw := rawFiles[name]
		encoded = protowire.AppendTag(encoded, 1, protowire.BytesType)
		encoded = protowire.AppendVarint(encoded, uint64(len(raw)))
		syntax := descriptors[name].GetSyntax()
		if syntax == "" {
			syntax = "proto2"
		}
		output.Files = append(output.Files, fileManifest{descriptorRecord: records[name],
			DescriptorSetOffset: len(encoded), SourcePath: "proto/source/" + name, Syntax: syntax})
		encoded = append(encoded, raw...)
	}
	output.DescriptorSet.SHA256 = hashBytes(encoded)
	if err := os.MkdirAll(filepath.Join(root, "proto"), 0755); err != nil {
		return fmt.Errorf("create proto directory: %w", err)
	}
	if err := os.WriteFile(filepath.Join(root, output.DescriptorSet.Path), encoded, 0644); err != nil {
		return fmt.Errorf("write exact descriptor set: %w", err)
	}
	return writeJSON(manifestPath, output)
}

func verifyPortable(root string, input manifest, verifyPrintedSources bool) (*descriptorpb.FileDescriptorSet, error) {
	if input.SchemaVersion != 1 {
		return nil, fmt.Errorf("manifest schemaVersion %d is unsupported", input.SchemaVersion)
	}
	if input.DescriptorSet.Path != "reverse-engineering/protobuf/original.pbdesc" {
		return nil, fmt.Errorf("descriptor set path %q is outside the selected artifact location", input.DescriptorSet.Path)
	}
	raw, err := os.ReadFile(filepath.Join(root, input.DescriptorSet.Path))
	if err != nil {
		return nil, fmt.Errorf("read descriptor set %q: %w", input.DescriptorSet.Path, err)
	}
	if digest := hashBytes(raw); digest != input.DescriptorSet.SHA256 {
		return nil, fmt.Errorf("descriptor set SHA-256 is %s; require %s", digest, input.DescriptorSet.SHA256)
	}
	var set descriptorpb.FileDescriptorSet
	if err := proto.Unmarshal(raw, &set); err != nil {
		return nil, fmt.Errorf("decode portable descriptor set: %w", err)
	}
	if len(set.File) != len(input.Files) {
		return nil, fmt.Errorf("descriptor set has %d files; manifest has %d", len(set.File), len(input.Files))
	}
	for index, record := range input.Files {
		if err := validName(record.File); err != nil {
			return nil, err
		}
		if record.SourcePath != "proto/source/"+record.File {
			return nil, fmt.Errorf("source path %q does not match descriptor %q", record.SourcePath, record.File)
		}
		start, end := record.DescriptorSetOffset, record.DescriptorSetOffset+record.Length
		if start < 0 || end < start || end > len(raw) || hashBytes(raw[start:end]) != record.SHA256 {
			return nil, fmt.Errorf("descriptor %q raw-byte digest or set offset is invalid", record.File)
		}
		file := set.File[index]
		if file.GetName() != record.File || file.GetPackage() != record.Package || !slices.Equal(file.Dependency, record.Dependencies) {
			return nil, fmt.Errorf("descriptor %q metadata disagrees with manifest", record.File)
		}
		if verifyPrintedSources && record.SourceSHA256 != "" {
			digest, err := hashFile(filepath.Join(root, record.SourcePath))
			if err != nil {
				return nil, err
			}
			if digest != record.SourceSHA256 {
				return nil, fmt.Errorf("printed source %q digest is %s; require %s", record.SourcePath, digest, record.SourceSHA256)
			}
		}
	}
	return &set, nil
}

func writeSources(root string, set *descriptorpb.FileDescriptorSet, input *manifest) error {
	files, err := desc.CreateFileDescriptorsFromSet(set)
	if err != nil {
		return fmt.Errorf("link original descriptor set: %w", err)
	}
	printer := protoprint.Printer{ForceFullyQualifiedNames: true}
	for index := range input.Files {
		record := &input.Files[index]
		if err := validName(record.File); err != nil {
			return err
		}
		text, err := printer.PrintProtoToString(files[record.File])
		if err != nil {
			return fmt.Errorf("print source %q: %w", record.File, err)
		}
		header := fmt.Sprintf("// Reconstructed from Spotify 1.3.6.1921 embedded descriptors.\n// Authoritative descriptor SHA-256: %s\n\n", record.SHA256)
		raw := []byte(header + text)
		target := filepath.Join(root, record.SourcePath)
		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return fmt.Errorf("create source directory for %q: %w", record.File, err)
		}
		if err := os.WriteFile(target, raw, 0644); err != nil {
			return fmt.Errorf("write source %q: %w", record.File, err)
		}
		record.SourceSHA256 = hashBytes(raw)
	}
	return nil
}

func validName(name string) error {
	clean := filepath.Clean(filepath.FromSlash(name))
	if filepath.IsAbs(clean) || clean == "." || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return fmt.Errorf("descriptor file name %q is not a relative schema path", name)
	}
	return nil
}

func readJSON(path string, target any) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read JSON %q: %w", path, err)
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return fmt.Errorf("decode JSON %q: %w", path, err)
	}
	return nil
}

func writeJSON(path string, value any) error {
	raw, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return fmt.Errorf("encode JSON %q: %w", path, err)
	}
	if err := os.WriteFile(path, append(raw, '\n'), 0644); err != nil {
		return fmt.Errorf("write JSON %q: %w", path, err)
	}
	return nil
}

func hashBytes(raw []byte) string {
	digest := sha256.Sum256(raw)
	return hex.EncodeToString(digest[:])
}

func hashFile(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("open hash input %q: %w", path, err)
	}
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return "", fmt.Errorf("hash input %q: %w", path, err)
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}
