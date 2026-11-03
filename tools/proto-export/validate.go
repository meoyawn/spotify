package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/google/go-cmp/cmp"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/testing/protocmp"
	"google.golang.org/protobuf/types/descriptorpb"
)

type descriptorDifference struct {
	File string `json:"file"`
	Diff string `json:"diff"`
}

type dartDifference struct {
	Path             string `json:"path"`
	OriginalSHA256   string `json:"originalSha256"`
	RecompiledSHA256 string `json:"recompiledSha256"`
}

type validationReport struct {
	SchemaVersion           int                    `json:"schemaVersion"`
	DescriptorSetSHA256     string                 `json:"descriptorSetSha256"`
	ProtocVersion           string                 `json:"protocVersion"`
	DescriptorCount         int                    `json:"descriptorCount"`
	EqualDescriptors        int                    `json:"equalDescriptors"`
	DescriptorDifferences   []descriptorDifference `json:"descriptorDifferences"`
	DartGeneratedFileCount  int                    `json:"dartGeneratedFileCount,omitempty"`
	DartDifferences         []dartDifference       `json:"dartDifferences"`
	OriginalDartSHA256      map[string]string      `json:"originalDartSha256,omitempty"`
	DartGeneratorExecutable string                 `json:"dartGeneratorExecutable,omitempty"`
	DartGeneratorSHA256     string                 `json:"dartGeneratorSha256,omitempty"`
}

func validateSources(root string, original *descriptorpb.FileDescriptorSet, input manifest, dartPlugin string) error {
	protoc, err := exec.LookPath("protoc")
	if err != nil {
		return fmt.Errorf("locate protoc for source validation: %w", err)
	}
	version, err := exec.Command(protoc, "--version").Output()
	if err != nil {
		return fmt.Errorf("query protoc %q version: %w", protoc, err)
	}
	temporary, err := os.MkdirTemp("", "spotify-proto-export-")
	if err != nil {
		return fmt.Errorf("create temporary compiler directory: %w", err)
	}
	defer os.RemoveAll(temporary)
	names := make([]string, 0, len(input.Files))
	for _, file := range input.Files {
		names = append(names, file.File)
	}
	recompiledPath := filepath.Join(temporary, "recompiled.pbdesc")
	args := append([]string{"-I", filepath.Join(root, "proto/source"), "--include_imports", "--descriptor_set_out=" + recompiledPath}, names...)
	if output, err := exec.Command(protoc, args...).CombinedOutput(); err != nil {
		return fmt.Errorf("compile selected printed schemas: %w\n%s", err, output)
	}
	raw, err := os.ReadFile(recompiledPath)
	if err != nil {
		return fmt.Errorf("read recompiled descriptor set %q: %w", recompiledPath, err)
	}
	var compiled descriptorpb.FileDescriptorSet
	if err := proto.Unmarshal(raw, &compiled); err != nil {
		return fmt.Errorf("decode recompiled descriptor set: %w", err)
	}
	if len(compiled.File) != len(original.File) {
		return fmt.Errorf("recompiled closure has %d files; require %d selected descriptors", len(compiled.File), len(original.File))
	}
	byName := map[string]*descriptorpb.FileDescriptorProto{}
	for _, file := range compiled.File {
		byName[file.GetName()] = file
	}
	report := validationReport{SchemaVersion: 1, DescriptorSetSHA256: input.DescriptorSet.SHA256,
		ProtocVersion: strings.TrimSpace(string(version)), DescriptorCount: len(original.File),
		DescriptorDifferences: []descriptorDifference{}}
	for _, file := range original.File {
		other := byName[file.GetName()]
		if proto.Equal(file, other) {
			report.EqualDescriptors++
			continue
		}
		report.DescriptorDifferences = append(report.DescriptorDifferences, descriptorDifference{
			File: file.GetName(), Diff: cmp.Diff(file, other, protocmp.Transform())})
	}
	if dartPlugin != "" {
		report.DartDifferences = []dartDifference{}
		plugin, err := filepath.Abs(dartPlugin)
		if err != nil {
			return fmt.Errorf("resolve Dart plugin %q: %w", dartPlugin, err)
		}
		report.DartGeneratorExecutable = filepath.Base(plugin)
		report.DartGeneratorSHA256, err = hashFile(plugin)
		if err != nil {
			return err
		}
		originalOutput := filepath.Join(temporary, "original-dart")
		compiledOutput := filepath.Join(temporary, "compiled-dart")
		if err := generateDart(protoc, plugin, filepath.Join(root, input.DescriptorSet.Path), originalOutput, names); err != nil {
			return err
		}
		if err := generateDart(protoc, plugin, recompiledPath, compiledOutput, names); err != nil {
			return err
		}
		originalHashes, err := hashTree(originalOutput)
		if err != nil {
			return err
		}
		compiledHashes, err := hashTree(compiledOutput)
		if err != nil {
			return err
		}
		report.OriginalDartSHA256 = originalHashes
		report.DartGeneratedFileCount = len(originalHashes)
		paths := make([]string, 0, len(originalHashes))
		for path := range originalHashes {
			paths = append(paths, path)
		}
		sort.Strings(paths)
		for _, path := range paths {
			if originalHashes[path] != compiledHashes[path] {
				report.DartDifferences = append(report.DartDifferences, dartDifference{
					Path: path, OriginalSHA256: originalHashes[path], RecompiledSHA256: compiledHashes[path]})
			}
		}
		for path := range compiledHashes {
			if _, exists := originalHashes[path]; !exists {
				return fmt.Errorf("recompiled schemas generated unexpected Dart file %q", path)
			}
		}
	}
	reportPath := filepath.Join(root, "reverse-engineering/protobuf/validation.json")
	if err := writeJSON(reportPath, report); err != nil {
		return err
	}
	fmt.Printf("Recompiled schemas: %d/%d equal descriptors.\n", report.EqualDescriptors, report.DescriptorCount)
	if dartPlugin != "" {
		fmt.Printf("Dart comparison: %d generated files; %d differences.\n", report.DartGeneratedFileCount, len(report.DartDifferences))
	}
	if len(report.DescriptorDifferences) != 0 || len(report.DartDifferences) != 0 {
		return fmt.Errorf("source round-trip is not exact; inspect %q; raw descriptor set remains authoritative", reportPath)
	}
	return nil
}

func generateDart(protoc, plugin, descriptorSet, target string, names []string) error {
	if err := os.MkdirAll(target, 0755); err != nil {
		return fmt.Errorf("create temporary Dart output %q: %w", target, err)
	}
	args := append([]string{"--descriptor_set_in=" + descriptorSet, "--plugin=protoc-gen-dart=" + plugin, "--dart_out=" + target}, names...)
	if output, err := exec.Command(protoc, args...).CombinedOutput(); err != nil {
		return fmt.Errorf("generate Dart from descriptor set %q: %w\n%s", descriptorSet, err, output)
	}
	return nil
}

func hashTree(root string) (map[string]string, error) {
	result := map[string]string{}
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		digest, err := hashFile(path)
		if err != nil {
			return err
		}
		result[filepath.ToSlash(relative)] = digest
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("hash generated Dart directory %q: %w", root, err)
	}
	return result, nil
}
