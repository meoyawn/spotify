package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"google.golang.org/protobuf/types/descriptorpb"
)

// proto3Presence uses full standard descriptors, because Dart BuilderInfo
// does not retain synthetic oneof/proto3_optional metadata for every field.
func proto3Presence(set *descriptorpb.FileDescriptorSet) ([]string, map[string][]int32) {
	var messageNames []string
	result := map[string][]int32{}
	var visit func(string, []*descriptorpb.DescriptorProto)
	visit = func(prefix string, messages []*descriptorpb.DescriptorProto) {
		for _, message := range messages {
			name := message.GetName()
			if prefix != "" {
				name = prefix + "." + name
			}
			messageNames = append(messageNames, name)
			var numbers []int32
			for _, field := range message.Field {
				if field.GetLabel() == descriptorpb.FieldDescriptorProto_LABEL_REPEATED ||
					field.OneofIndex != nil || field.GetProto3Optional() ||
					field.GetType() == descriptorpb.FieldDescriptorProto_TYPE_MESSAGE ||
					field.GetType() == descriptorpb.FieldDescriptorProto_TYPE_GROUP {
					continue
				}
				numbers = append(numbers, field.GetNumber())
			}
			if len(numbers) != 0 {
				sort.Slice(numbers, func(i, j int) bool { return numbers[i] < numbers[j] })
				result[name] = numbers
			}
			visit(name, message.NestedType)
		}
	}
	for _, file := range set.File {
		if file.GetSyntax() == "proto3" {
			visit(file.GetPackage(), file.MessageType)
		}
	}
	sort.Strings(messageNames)
	return messageNames, result
}

func writeDartPresence(repo, output string) error {
	root, err := filepath.Abs(repo)
	if err != nil {
		return fmt.Errorf("resolve presence repository %q: %w", repo, err)
	}
	var input manifest
	if err := readJSON(filepath.Join(root, "proto/manifest.json"), &input); err != nil {
		return err
	}
	set, err := verifyPortable(root, input, true)
	if err != nil {
		return err
	}
	messageNames, fields := proto3Presence(set)
	names := make([]string, 0, len(fields))
	for name := range fields {
		names = append(names, name)
	}
	sort.Strings(names)
	var data bytes.Buffer
	fmt.Fprintln(&data, "// Generated code. Do not modify.")
	fmt.Fprintln(&data, "// Descriptor-confirmed proto3 syntax and scalar presence from exact schemas.")
	fmt.Fprintf(&data, "// Exact descriptor set SHA-256: %s\n", input.DescriptorSet.SHA256)
	fmt.Fprintln(&data, "// Reconstructed schemas and proto2 fields are deliberately unlisted.")
	fmt.Fprintln(&data, "// Implicit scalar fields exclude repeated, message/group, oneof and proto3_optional.")
	fmt.Fprintln(&data, "const nativeProto3ImplicitScalars = <String, Set<int>>{")
	for _, name := range names {
		fmt.Fprintf(&data, "  %q: <int>{", name)
		for index, number := range fields[name] {
			if index != 0 {
				fmt.Fprint(&data, ", ")
			}
			fmt.Fprint(&data, number)
		}
		fmt.Fprintln(&data, "},")
	}
	fmt.Fprintln(&data, "};")
	fmt.Fprintln(&data)
	fmt.Fprintln(&data, "const nativeProto3Messages = <String>{")
	for _, name := range messageNames {
		fmt.Fprintf(&data, "  %q,\n", name)
	}
	fmt.Fprintln(&data, "};")
	if output == "" {
		if _, err := os.Stdout.Write(data.Bytes()); err != nil {
			return fmt.Errorf("write Dart presence metadata to stdout: %w", err)
		}
		return nil
	}
	if err := os.WriteFile(output, data.Bytes(), 0644); err != nil {
		return fmt.Errorf("write Dart presence output %q: %w", output, err)
	}
	return nil
}
