package main

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/jhump/protoreflect/desc"
	"github.com/jhump/protoreflect/desc/protoprint"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/descriptorpb"
)

type liteInventory struct {
	SchemaVersion int           `json:"schemaVersion"`
	SourceSHA256  string        `json:"sourceExecutableSha256"`
	Limitations   []string      `json:"limitations"`
	Messages      []liteMessage `json:"messages"`
}

type liteMessage struct {
	Name          string      `json:"name"`
	TableAddress  string      `json:"tableAddress"`
	MetadataHash  string      `json:"relocatedMetadataSha256"`
	Fields        []liteField `json:"fields"`
}

type liteField struct {
	Number      int32  `json:"number"`
	Name        string `json:"retainedDiagnosticName"`
	Scalar      string `json:"scalarType"`
	Cardinality string `json:"memoryCardinality"`
	Kind        string `json:"kind"`
	TypeCard    string `json:"typeCard"`
	HasIndex    int32  `json:"hasIndex"`
	Submessage  string `json:"submessageType"`
	AuxRawHex   string `json:"auxRawHex"`
}

type liteReference struct {
	Repo   string `json:"repo"`
	Commit string `json:"commit"`
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	URL    string `json:"url,omitempty"`
}

type liteFieldProof struct {
	Number       int32  `json:"number"`
	Name         string `json:"name"`
	NameOrigin   string `json:"nameOrigin"`
	Type         string `json:"type"`
	NativeType   string `json:"nativeType"`
	Cardinality  string `json:"cardinality"`
	NativeLink   string `json:"nativeSubmessage,omitempty"`
	NativeAux    string `json:"nativeAux,omitempty"`
	LinkNote     string `json:"linkNote,omitempty"`
}

type liteMessageProof struct {
	Name         string           `json:"name"`
	File         string           `json:"file"`
	TableAddress string           `json:"tableAddress"`
	MetadataHash string           `json:"metadataSha256"`
	Fields       []liteFieldProof `json:"fields"`
}

type liteGap struct {
	Message string `json:"message"`
	Reason  string `json:"reason"`
}

type liteIssue struct {
	Message string `json:"message"`
	Field   int32  `json:"field,omitempty"`
	Check   string `json:"check"`
	Detail  string `json:"detail"`
}

type liteValidation struct {
	SchemaVersion       int         `json:"schemaVersion"`
	Classification      string      `json:"classification"`
	ProtocVersion       string      `json:"protocVersion"`
	ValidatedMessages   int         `json:"validatedMessages"`
	ValidatedFields     int         `json:"validatedFields"`
	RetainedNames       int         `json:"validatedRetainedNames"`
	PackingChecks       int         `json:"packingChecks"`
	OneofGroups         int         `json:"oneofGroups"`
	ValidatedEnums      int         `json:"validatedEnums"`
	ValidatedEnumValues int         `json:"validatedEnumValues"`
	Issues              []liteIssue `json:"issues"`
	NativeUnresolved    []liteIssue `json:"nativeUnresolvedLinks"`
}

type liteMemoryRegion struct {
	address uint64
	data    []byte
}

type liteNativeMemory []liteMemoryRegion

func (memory liteNativeMemory) read(address uint64, count int) ([]byte, error) {
	for _, region := range memory {
		if address >= region.address && address+uint64(count) <= region.address+uint64(len(region.data)) {
			return region.data[address-region.address : address-region.address+uint64(count)], nil
		}
	}
	return nil, fmt.Errorf("native metadata address %#x+%d is outside retained regions", address, count)
}

func (memory liteNativeMemory) word(address uint64) (uint64, error) {
	raw, err := memory.read(address, 8)
	if err != nil { return 0, err }
	return binary.LittleEndian.Uint64(raw), nil
}

func loadLiteNativeMemory(root, digest string) (liteNativeMemory, error) {
	var result liteNativeMemory
	for _, name := range []string{"rebased-dataconst", "rebased-data"} {
		var envelope struct {
			Structured struct {
				Subject struct { Digest struct { SHA256 string `json:"sha256"` } `json:"digest"` } `json:"subject"`
				Result struct { Address string `json:"address"`; BytesHex string `json:"bytes_hex"` } `json:"normalized_result"`
			} `json:"structuredContent"`
		}
		if err := readJSON(filepath.Join(root, ".local/rea-session", name+".json"), &envelope); err != nil { return nil, err }
		if envelope.Structured.Subject.Digest.SHA256 != digest { return nil, fmt.Errorf("metadata input %q source hash differs from %s", name, digest) }
		address, err := strconv.ParseUint(envelope.Structured.Result.Address, 0, 64)
		if err != nil { return nil, fmt.Errorf("parse metadata input %q address: %w", name, err) }
		data, err := hex.DecodeString(envelope.Structured.Result.BytesHex)
		if err != nil { return nil, fmt.Errorf("decode metadata input %q bytes: %w", name, err) }
		result = append(result, liteMemoryRegion{address: address, data: data})
	}
	return result, nil
}

func reconstructLogin5(repo string) error {
	root, err := filepath.Abs(repo)
	if err != nil { return fmt.Errorf("resolve reconstruction repository %q: %w", repo, err) }
	base := filepath.Join(root, "proto/reconstructed/login5")
	if err := os.MkdirAll(base, 0755); err != nil { return fmt.Errorf("create reconstructed output %q: %w", base, err) }
	var inventory liteInventory
	inventoryPath := filepath.Join(root, "reverse-engineering/evidence/login5-lite-tables.json")
	if err := readJSON(inventoryPath, &inventory); err != nil { return err }
	var exact sourceEvidence
	if err := readJSON(filepath.Join(root, "reverse-engineering/evidence/protocol-descriptors.json"), &exact); err != nil { return err }
	if exact.SHA256 != inventory.SourceSHA256 { return fmt.Errorf("lite/exact source hashes disagree: %s versus %s", inventory.SourceSHA256, exact.SHA256) }
	image, err := os.ReadFile(exact.Source)
	if err != nil { return fmt.Errorf("read original executable %q: %w", exact.Source, err) }
	if hashBytes(image) != inventory.SourceSHA256 { return fmt.Errorf("original executable hash differs from lite inventory %s", inventory.SourceSHA256) }
	memory, err := loadLiteNativeMemory(root, inventory.SourceSHA256)
	if err != nil { return err }
	resolvedLinks, durationProof, err := nativeDuration(image, memory, exact.Records)
	if err != nil { return err }
	var references []liteReference
	referencePath := filepath.Join(root, ".local/reference/login5-schemas/manifest.json")
	if err := readJSON(referencePath, &references); err != nil { return err }
	var referenceFiles []string
	var referenceProof []liteReference
	for _, reference := range references {
		if reference.Repo != "librespot-org/librespot" { continue }
		if reference.Commit != "99b6088bf3ea028f90192676ac1a337fa4b2ed12" { return fmt.Errorf("unapproved reference commit %q", reference.Commit) }
		path := filepath.Join(root, ".local/reference/login5-schemas/librespot-org--librespot", reference.Path)
		digest, err := hashFile(path)
		if err != nil { return err }
		if digest != reference.SHA256 { return fmt.Errorf("reference %q hash %s differs from pin %s", reference.Path, digest, reference.SHA256) }
		referenceFiles = append(referenceFiles, strings.TrimPrefix(reference.Path, "protocol/proto/"))
		reference.URL = "https://github.com/" + reference.Repo + "/blob/" + reference.Commit + "/" + reference.Path
		referenceProof = append(referenceProof, reference)
	}
	if len(referenceFiles) != 7 { return fmt.Errorf("pinned v3 reference set has %d files; require 7", len(referenceFiles)) }
	sort.Strings(referenceFiles)
	temporary, err := os.MkdirTemp("", "spotify-login5-reconstruction-")
	if err != nil { return fmt.Errorf("create Login5 compiler directory: %w", err) }
	defer os.RemoveAll(temporary)
	referenceSet, version, err := compileLite(root, filepath.Join(root, ".local/reference/login5-schemas/librespot-org--librespot/protocol/proto"), referenceFiles, filepath.Join(temporary, "reference.pbdesc"))
	if err != nil { return err }
	byNative := map[string]liteMessage{}
	for _, message := range inventory.Messages { byNative[message.Name] = message }
	byReference, _ := indexLiteDescriptors(referenceSet)
	var deltas []liteIssue
	var files []*descriptorpb.FileDescriptorProto
	for _, original := range referenceSet.File {
		if !strings.HasPrefix(original.GetPackage(), "spotify.login5.v3") { files = append(files, proto.Clone(original).(*descriptorpb.FileDescriptorProto)); continue }
		file := proto.Clone(original).(*descriptorpb.FileDescriptorProto)
		file.Options, file.SourceCodeInfo = nil, nil
		for _, message := range file.MessageType {
			fullName := file.GetPackage() + "." + message.GetName()
			facts, exists := byNative[fullName]
			if !exists { return fmt.Errorf("reference message %q has no native lite inventory", fullName) }
			message.Options = nil
			var retained []*descriptorpb.FieldDescriptorProto
			for _, field := range message.Field {
				found := false
				for _, fact := range facts.Fields { if fact.Number == field.GetNumber() { found = true; break } }
				if !found {
					deltas = append(deltas, liteIssue{Message: fullName, Field: field.GetNumber(), Check: "reference-field-absent-native", Detail: "removed pinned reference field " + field.GetName()})
					continue
				}
				field.Options = nil
				retained = append(retained, field)
			}
			message.Field = retained
		}
		files = append(files, file)
	}
	errorValues, enumProof, err := nativeLoginError(image, memory)
	if err != nil { return err }
	for _, file := range files {
		if file.GetPackage() != "spotify.login5.v3" { continue }
		for _, enumeration := range file.EnumType {
			if enumeration.GetName() != "LoginError" { continue }
			for _, value := range enumeration.Value {
				number, exists := errorValues[value.GetName()]
				if !exists || number != value.GetNumber() { return fmt.Errorf("pinned LoginError value %s=%d disagrees with native enum data", value.GetName(), value.GetNumber()) }
			}
			enumeration.Value = append(enumeration.Value, &descriptorpb.EnumValueDescriptorProto{Name: proto.String("NOT_ALLOWED"), Number: proto.Int32(errorValues["NOT_ALLOWED"])})
		}
	}
	v4Files, gaps := reconstructV4(inventory, byReference, resolvedLinks)
	files = append(files, v4Files...)
	set := &descriptorpb.FileDescriptorSet{File: files}
	linked, err := desc.CreateFileDescriptorsFromSet(set)
	if err != nil { return fmt.Errorf("link reconstructed Login5 descriptors: %w", err) }
	sourceRoot := filepath.Join(base, "source")
	printer := protoprint.Printer{ForceFullyQualifiedNames: true}
	var names []string
	var sourceArtifacts []artifact
	for _, file := range files {
		if !strings.HasPrefix(file.GetPackage(), "spotify.login5.") { continue }
		text, err := printer.PrintProtoToString(linked[file.GetName()])
		if err != nil { return fmt.Errorf("print reconstructed source %q: %w", file.GetName(), err) }
		data := []byte("// RECONSTRUCTED Login5 schema; not an extracted original descriptor.\n// Native wire facts: reverse-engineering/evidence/login5-lite-tables.json.\n// Per-field provenance: proto/reconstructed/login5/manifest.json.\n// Original filenames/source options/optional declarations remain unestablished.\n\n" + text)
		target := filepath.Join(sourceRoot, filepath.FromSlash(file.GetName()))
		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil { return fmt.Errorf("create source parent for %q: %w", file.GetName(), err) }
		if err := os.WriteFile(target, data, 0644); err != nil { return fmt.Errorf("write reconstructed source %q: %w", file.GetName(), err) }
		names = append(names, file.GetName())
		relative, _ := filepath.Rel(root, target)
		sourceArtifacts = append(sourceArtifacts, artifact{Path: filepath.ToSlash(relative), SHA256: hashBytes(data)})
	}
	sort.Strings(names)
	compiledPath := filepath.Join(base, "reconstructed.pbdesc")
	compiled, _, err := compileLite(root, sourceRoot, names, compiledPath)
	if err != nil { return err }
	report, proofs := validateLite(compiled, inventory, referenceSet, resolvedLinks, version)
	if err := writeJSON(filepath.Join(base, "validation.json"), report); err != nil { return err }
	if len(report.Issues) != 0 { return fmt.Errorf("reconstructed Login5 has %d native-fact mismatches; inspect proto/reconstructed/login5/validation.json", len(report.Issues)) }
	compiledHash, err := hashFile(compiledPath)
	if err != nil { return err }
	inventoryHash, err := hashFile(inventoryPath)
	if err != nil { return err }
	output := map[string]any{
		"schemaVersion": 1, "classification": "reconstructed-not-extracted",
		"sourceExecutableSha256": inventory.SourceSHA256,
		"nativeInventory": artifact{Path: "reverse-engineering/evidence/login5-lite-tables.json", SHA256: inventoryHash},
		"referencePins": referenceProof, "ignoredReference": "hazycora flat login5.proto is not a schema authority; it omits Duration and mis-types v4 fields",
		"descriptorSet": artifact{Path: "proto/reconstructed/login5/reconstructed.pbdesc", SHA256: compiledHash},
		"sourceFiles": sourceArtifacts, "roots": names, "messages": proofs, "excludedMessages": gaps,
		"referenceDeltas": deltas, "nativeLoginError": enumProof,
		"nativeSubmessageProof": durationProof,
		"enumProvenance": reconstructedEnumProof(compiled),
		"limitations": []string{"These are reconstructed schemas, not original embedded descriptors", "Original source filenames, source options and proto3 optional declarations are not recovered", "All older Windows reference source options are discarded", "Unretained field/oneof names use pinned v3 analogue or explicitly synthetic names", "V4 enum-dependent closures remain excluded rather than inventing enum types or replacing them with int32", "Other v3 enum labels follow the pinned public reference, not retained current native label tables", "Standard google.protobuf.Duration is tied through native Full ClassData and its exact descriptor hash", "No account-tier gates, live Spotify requests or profile data"},
	}
	if err := writeJSON(filepath.Join(base, "manifest.json"), output); err != nil { return err }
	fmt.Printf("Reconstructed Login5: %d messages, %d fields, %d retained names, %d source files; %d explicit gaps, %d unresolved native links.\n", report.ValidatedMessages, report.ValidatedFields, report.RetainedNames, len(names), len(gaps), len(report.NativeUnresolved))
	return nil
}

func compileLite(root, sources string, names []string, output string) (*descriptorpb.FileDescriptorSet, string, error) {
	compiler, err := exec.LookPath("protoc")
	if err != nil { return nil, "", fmt.Errorf("locate standard protoc: %w", err) }
	version, err := exec.Command(compiler, "--version").Output()
	if err != nil { return nil, "", fmt.Errorf("query protoc version: %w", err) }
	args := append([]string{"-I", sources, "-I", filepath.Join(root, "proto/source"), "--include_imports", "--descriptor_set_out=" + output}, names...)
	if diagnostic, err := exec.Command(compiler, args...).CombinedOutput(); err != nil { return nil, "", fmt.Errorf("compile reconstructed inputs with protoc: %w\n%s", err, diagnostic) }
	raw, err := os.ReadFile(output)
	if err != nil { return nil, "", fmt.Errorf("read compiled reconstruction %q: %w", output, err) }
	set := &descriptorpb.FileDescriptorSet{}
	if err := proto.Unmarshal(raw, set); err != nil { return nil, "", fmt.Errorf("decode compiled reconstruction %q: %w", output, err) }
	return set, strings.TrimSpace(string(version)), nil
}

func nativeLoginError(image []byte, memory liteNativeMemory) (map[string]int32, map[string]any, error) {
	labels := []string{"BAD_REQUEST", "INVALID_CREDENTIALS", "INVALID_PHONENUMBER", "NOT_ALLOWED", "TIMEOUT", "TOO_MANY_ATTEMPTS", "TRY_AGAIN_LATER", "UNKNOWN_ERROR", "UNKNOWN_IDENTIFIER", "UNSUPPORTED_LOGIN_PROTOCOL"}
	const blob = 0x22a8177
	const indices = 0x22a8230
	joined := []byte(strings.Join(labels, ""))
	if !bytes.Equal(image[blob:blob+len(joined)], joined) { return nil, nil, fmt.Errorf("native LoginError name blob at %#x differs from evidenced labels", blob) }
	values := map[string]int32{}
	var tables []map[string]any
	for _, address := range []uint64{0x102645270, 0x102646bb0} {
		raw, err := memory.read(address, 10*24)
		if err != nil { return nil, nil, err }
		var entries []map[string]any
		for index, label := range labels {
			pointer := binary.LittleEndian.Uint64(raw[index*24:])
			length := binary.LittleEndian.Uint64(raw[index*24+8:])
			number := int32(binary.LittleEndian.Uint32(raw[index*24+16:]))
			offset := pointer - 0x100000000
			if offset+length > uint64(len(image)) || string(image[offset:offset+length]) != label { return nil, nil, fmt.Errorf("native LoginError entry %#x/%d label differs from %q", address, index, label) }
			if prior, exists := values[label]; exists && prior != number { return nil, nil, fmt.Errorf("v3/v4 LoginError table member %s disagrees: %d versus %d", label, prior, number) }
			values[label] = number
			entries = append(entries, map[string]any{"name": label, "number": number, "nameAddress": fmt.Sprintf("%#x", pointer), "length": length})
		}
		tables = append(tables, map[string]any{"address": fmt.Sprintf("%#x", address), "relocatedSha256": hashBytes(raw), "entryStride": 24, "entries": entries})
	}
	var ordinals []uint32
	for ordinal := range labels {
		index := binary.LittleEndian.Uint32(image[indices+ordinal*4:])
		if int(index) >= len(labels) { return nil, nil, fmt.Errorf("native LoginError ordinal %d has invalid sorted index %d", ordinal, index) }
		if values[labels[index]] != int32(ordinal) { return nil, nil, fmt.Errorf("native LoginError ordinal %d disagrees with entry-table member %s=%d", ordinal, labels[index], values[labels[index]]) }
		ordinals = append(ordinals, index)
	}
	return values, map[string]any{"sortedNameBlobFileOffset": blob, "ordinalToSortedIndexFileOffset": indices, "sortedNames": labels, "ordinalToSortedIndex": ordinals, "values": values, "nativeEntryTables": tables, "v3TableReferences": []string{"0x1018d2b20", "0x1018d2bb0"}, "v4TableReferences": []string{"0x1018df628", "0x1018df6b8"}, "generatedNameWrapper": "0x1018df604", "note": "Current native v3/v4 entry tables and shared count-10 ordinal index; no protobuf runtime decompilation"}, nil
}

func nativeDuration(image []byte, memory liteNativeMemory, records []descriptorRecord) (map[string]string, map[string]any, error) {
	const table = uint64(0x1027e37a8)
	class, err := memory.word(table + 32)
	if err != nil { return nil, nil, err }
	classBytes, err := memory.read(class, 80)
	if err != nil { return nil, nil, err }
	if classBytes[60] != 0 { return nil, nil, fmt.Errorf("Duration class metadata %#x is not Full ClassData", class) }
	prototype := binary.LittleEndian.Uint64(classBytes)
	descriptorTable := binary.LittleEndian.Uint64(classBytes[72:])
	descriptorBytes, err := memory.read(descriptorTable, 64)
	if err != nil { return nil, nil, err }
	length := binary.LittleEndian.Uint32(descriptorBytes[4:])
	descriptorPointer := binary.LittleEndian.Uint64(descriptorBytes[8:])
	filenamePointer := binary.LittleEndian.Uint64(descriptorBytes[16:])
	messageCount := binary.LittleEndian.Uint32(descriptorBytes[44:])
	instances := binary.LittleEndian.Uint64(descriptorBytes[56:])
	instance, err := memory.word(instances)
	if err != nil { return nil, nil, err }
	filenameOffset, descriptorOffset := filenamePointer-0x100000000, descriptorPointer-0x100000000
	filename := "google/protobuf/duration.proto"
	if messageCount != 1 || instance != prototype || filenameOffset+uint64(len(filename)) > uint64(len(image)) || string(image[filenameOffset:filenameOffset+uint64(len(filename))]) != filename { return nil, nil, fmt.Errorf("Duration native descriptor-table/prototype linkage differs from retained proof") }
	if descriptorOffset+uint64(length) > uint64(len(image)) { return nil, nil, fmt.Errorf("Duration descriptor %#x+%d exceeds original image", descriptorPointer, length) }
	digest := hashBytes(image[descriptorOffset:descriptorOffset+uint64(length)])
	matched := false
	for _, record := range records { if record.File == filename && record.SHA256 == digest && record.Length == int(length) { matched = true } }
	if !matched { return nil, nil, fmt.Errorf("Duration native descriptor hash %s is absent from exact descriptor inventory", digest) }
	proof := map[string]any{"type": "google.protobuf.Duration", "parseTable": fmt.Sprintf("%#x", table), "classData": fmt.Sprintf("%#x", class), "classDataIsLite": false, "descriptorTable": fmt.Sprintf("%#x", descriptorTable), "filenameAddress": fmt.Sprintf("%#x", filenamePointer), "filename": filename, "rawDescriptorAddress": fmt.Sprintf("%#x", descriptorPointer), "rawDescriptorLength": length, "rawDescriptorSha256": digest, "prototype": fmt.Sprintf("%#x", prototype), "messageCount": messageCount}
	return map[string]string{"a8377e0201000000": "google.protobuf.Duration"}, proof, nil
}

func indexLiteDescriptors(set *descriptorpb.FileDescriptorSet) (map[string]*descriptorpb.DescriptorProto, map[string]string) {
	messages, files := map[string]*descriptorpb.DescriptorProto{}, map[string]string{}
	var walk func(string, string, []*descriptorpb.DescriptorProto)
	walk = func(prefix, file string, entries []*descriptorpb.DescriptorProto) {
		for _, message := range entries {
			name := prefix + "." + message.GetName()
			messages[name], files[name] = message, file
			walk(name, file, message.NestedType)
		}
	}
	for _, file := range set.File { walk(file.GetPackage(), file.GetName(), file.MessageType) }
	return messages, files
}

func reconstructV4(inventory liteInventory, reference map[string]*descriptorpb.DescriptorProto, resolved map[string]string) ([]*descriptorpb.FileDescriptorProto, []liteGap) {
	eligible := map[string]bool{}
	reasons := map[string]string{}
	for _, message := range inventory.Messages {
		if !strings.HasPrefix(message.Name, "spotify.login5.v4.") { continue }
		eligible[message.Name] = true
		for _, field := range message.Fields {
			if field.Scalar == "enum" { eligible[message.Name] = false; reasons[message.Name] = "native enum field identity/labels/range not established by an authoritative v4 reference" }
		}
	}
	for changed := true; changed; {
		changed = false
		for _, message := range inventory.Messages {
			if !eligible[message.Name] { continue }
			if strings.HasPrefix(message.Name, "spotify.login5.v4.Interaction.") && !eligible["spotify.login5.v4.Interaction"] {
				eligible[message.Name] = false; reasons[message.Name] = "nested parent Interaction is unresolved; no incomplete namespace-carrier message is emitted"; changed = true; continue
			}
			for _, field := range message.Fields {
				if field.Kind != "message" { continue }
				if field.Submessage == "" && resolved[field.AuxRawHex] != "" { continue }
				if !eligible[field.Submessage] { eligible[message.Name] = false; reasons[message.Name] = "depends on unresolved native message " + field.Submessage; changed = true; break }
			}
		}
	}
	byPackage := map[string]*descriptorpb.FileDescriptorProto{}
	messageFiles := map[string]string{}
	var gaps []liteGap
	for _, message := range inventory.Messages {
		if !strings.HasPrefix(message.Name, "spotify.login5.v4.") { continue }
		if !eligible[message.Name] { gaps = append(gaps, liteGap{Message: message.Name, Reason: reasons[message.Name]}); continue }
		separator := strings.LastIndex(message.Name, ".")
		pkg := message.Name[:separator]
		name := strings.ReplaceAll(pkg, ".", "/") + "/reconstructed.proto"
		messageFiles[message.Name] = name
		if byPackage[pkg] == nil { byPackage[pkg] = &descriptorpb.FileDescriptorProto{Name: proto.String(name), Package: proto.String(pkg), Syntax: proto.String("proto3")} }
	}
	for _, message := range inventory.Messages {
		if !eligible[message.Name] { continue }
		separator := strings.LastIndex(message.Name, ".")
		file := byPackage[message.Name[:separator]]
		entry := &descriptorpb.DescriptorProto{Name: proto.String(message.Name[separator+1:])}
		groups := map[int32]int32{}
		for _, fact := range message.Fields {
			kind := liteType(fact)
			field := &descriptorpb.FieldDescriptorProto{Name: proto.String(liteFieldName(message.Name, fact, reference)), Number: proto.Int32(fact.Number), Type: kind.Enum(), Label: descriptorpb.FieldDescriptorProto_LABEL_OPTIONAL.Enum()}
			if fact.Cardinality == "repeated" { field.Label = descriptorpb.FieldDescriptorProto_LABEL_REPEATED.Enum() }
			if fact.Cardinality == "oneof" {
				index, exists := groups[fact.HasIndex]
				if !exists { index = int32(len(groups)); groups[fact.HasIndex] = index; entry.OneofDecl = append(entry.OneofDecl, &descriptorpb.OneofDescriptorProto{Name: proto.String("group_" + strconv.Itoa(int(fact.HasIndex)))}) }
				field.OneofIndex = proto.Int32(index)
			}
			if fact.Kind == "packedVarint" || fact.Kind == "packedFixed" { field.Options = &descriptorpb.FieldOptions{Packed: proto.Bool(true)} }
			if fact.Kind == "message" {
				target := fact.Submessage
				dependency := messageFiles[target]
				if target == "" && resolved[fact.AuxRawHex] != "" { target, dependency = resolved[fact.AuxRawHex], "google/protobuf/duration.proto" }
				field.TypeName = proto.String("." + target)
				if dependency != file.GetName() && !containsString(file.Dependency, dependency) { file.Dependency = append(file.Dependency, dependency) }
			}
			entry.Field = append(entry.Field, field)
		}
		file.MessageType = append(file.MessageType, entry)
	}
	var files []*descriptorpb.FileDescriptorProto
	for _, file := range byPackage { sort.Strings(file.Dependency); files = append(files, file) }
	sort.Slice(files, func(i, j int) bool { return files[i].GetName() < files[j].GetName() })
	return files, gaps
}

func containsString(values []string, value string) bool { for _, item := range values { if item == value { return true } }; return false }

func liteType(field liteField) descriptorpb.FieldDescriptorProto_Type {
	if field.Kind == "message" { return descriptorpb.FieldDescriptorProto_TYPE_MESSAGE }
	return map[string]descriptorpb.FieldDescriptorProto_Type{"string": descriptorpb.FieldDescriptorProto_TYPE_STRING, "bytes": descriptorpb.FieldDescriptorProto_TYPE_BYTES, "bool": descriptorpb.FieldDescriptorProto_TYPE_BOOL, "int32": descriptorpb.FieldDescriptorProto_TYPE_INT32, "int64": descriptorpb.FieldDescriptorProto_TYPE_INT64, "uint32": descriptorpb.FieldDescriptorProto_TYPE_UINT32, "uint64": descriptorpb.FieldDescriptorProto_TYPE_UINT64, "enum": descriptorpb.FieldDescriptorProto_TYPE_ENUM}[field.Scalar]
}

func liteFieldName(message string, fact liteField, reference map[string]*descriptorpb.DescriptorProto) string {
	if fact.Name != "" { return fact.Name }
	analogue := strings.Replace(message, ".v4.", ".v3.", 1)
	if strings.HasSuffix(analogue, ".NativePassword") { analogue = strings.TrimSuffix(analogue, "NativePassword") + "Password" }
	if other := reference[analogue]; other != nil {
		for _, field := range other.Field {
			if field.GetNumber() == fact.Number && field.GetType() == liteType(fact) { return field.GetName() }
		}
	}
	return "field_" + strconv.Itoa(int(fact.Number))
}

func validateLite(set *descriptorpb.FileDescriptorSet, inventory liteInventory, referenceSet *descriptorpb.FileDescriptorSet, resolved map[string]string, version string) (liteValidation, []liteMessageProof) {
	report := liteValidation{SchemaVersion: 1, Classification: "reconstructed-not-extracted", ProtocVersion: version, Issues: []liteIssue{}, NativeUnresolved: []liteIssue{}}
	messages, files := indexLiteDescriptors(set)
	references, _ := indexLiteDescriptors(referenceSet)
	syntax := map[string]string{}
	for _, file := range set.File { syntax[file.GetName()] = file.GetSyntax() }
	var proofs []liteMessageProof
	for _, facts := range inventory.Messages {
		message := messages[facts.Name]
		if message == nil { continue }
		report.ValidatedMessages++
		proof := liteMessageProof{Name: facts.Name, File: files[facts.Name], TableAddress: facts.TableAddress, MetadataHash: facts.MetadataHash, Fields: []liteFieldProof{}}
		if len(message.Field) != len(facts.Fields) { report.Issues = append(report.Issues, liteIssue{Message: facts.Name, Check: "field-count", Detail: fmt.Sprintf("compiled %d versus native %d", len(message.Field), len(facts.Fields))}) }
		byNumber := map[int32]*descriptorpb.FieldDescriptorProto{}
		for _, field := range message.Field { byNumber[field.GetNumber()] = field }
		groups := map[int32]int32{}
		inverseGroups := map[int32]int32{}
		for _, fact := range facts.Fields {
			field := byNumber[fact.Number]
			if field == nil { report.Issues = append(report.Issues, liteIssue{Message: facts.Name, Field: fact.Number, Check: "number", Detail: "native field missing"}); continue }
			report.ValidatedFields++
			if field.GetType() != liteType(fact) { report.Issues = append(report.Issues, liteIssue{Message: facts.Name, Field: fact.Number, Check: "type", Detail: fmt.Sprintf("compiled %s versus native %s/%s", field.GetType(), fact.Kind, fact.Scalar)}) }
			nameOrigin := "pinned-public-v3-reference"
			if fact.Name != "" {
				report.RetainedNames++
				nameOrigin = "native-retained-diagnostic-name"
				if field.GetName() != fact.Name { report.Issues = append(report.Issues, liteIssue{Message: facts.Name, Field: fact.Number, Check: "retained-name", Detail: field.GetName() + " versus " + fact.Name}) }
			} else if strings.Contains(facts.Name, ".v4.") {
				nameOrigin = "pinned-public-v3-analogue-name"
				if strings.HasPrefix(field.GetName(), "field_") { nameOrigin = "synthetic-number-based-name" }
			}
			entry := liteFieldProof{Number: fact.Number, Name: field.GetName(), NameOrigin: nameOrigin, Type: field.GetType().String(), NativeType: fact.TypeCard, Cardinality: fact.Cardinality, NativeLink: fact.Submessage, NativeAux: fact.AuxRawHex}
			if fact.Scalar == "enum" {
				entry.Type = strings.TrimPrefix(field.GetTypeName(), ".")
				expected := ""
				if original := references[facts.Name]; original != nil {
					for _, candidate := range original.Field { if candidate.GetNumber() == fact.Number { expected = candidate.GetTypeName(); break } }
				}
				if expected == "" || field.GetTypeName() != expected { report.Issues = append(report.Issues, liteIssue{Message: facts.Name, Field: fact.Number, Check: "enum-identity", Detail: field.GetTypeName() + " versus pinned type " + expected}) }
			}
			if fact.Kind == "message" {
				entry.Type = strings.TrimPrefix(field.GetTypeName(), ".")
				if fact.Submessage != "" && entry.Type != fact.Submessage { report.Issues = append(report.Issues, liteIssue{Message: facts.Name, Field: fact.Number, Check: "submessage", Detail: entry.Type + " versus " + fact.Submessage}) }
				if fact.Submessage == "" {
					if nativeType := resolved[fact.AuxRawHex]; nativeType != "" {
						entry.LinkNote = "native Full ClassData/DescriptorTable and exact original descriptor hash resolve " + nativeType
						if entry.Type != nativeType { report.Issues = append(report.Issues, liteIssue{Message: facts.Name, Field: fact.Number, Check: "submessage", Detail: entry.Type + " versus resolved native " + nativeType}) }
					} else { entry.LinkNote = "native auxiliary pointer unresolved; type identity supplied by pinned v3 schema"; report.NativeUnresolved = append(report.NativeUnresolved, liteIssue{Message: facts.Name, Field: fact.Number, Check: "unresolved-native-link", Detail: fact.AuxRawHex + "; reconstructed type " + entry.Type}) }
				}
			}
			if fact.Cardinality == "repeated" {
				if field.GetLabel() != descriptorpb.FieldDescriptorProto_LABEL_REPEATED { report.Issues = append(report.Issues, liteIssue{Message: facts.Name, Field: fact.Number, Check: "cardinality", Detail: "native repeated field compiled singular"}) }
				if field.GetType() != descriptorpb.FieldDescriptorProto_TYPE_STRING && field.GetType() != descriptorpb.FieldDescriptorProto_TYPE_BYTES && field.GetType() != descriptorpb.FieldDescriptorProto_TYPE_MESSAGE {
					report.PackingChecks++
					packed := syntax[files[facts.Name]] == "proto3"
					if field.Options != nil && field.Options.Packed != nil { packed = field.GetOptions().GetPacked() }
					if packed != strings.HasPrefix(fact.Kind, "packed") { report.Issues = append(report.Issues, liteIssue{Message: facts.Name, Field: fact.Number, Check: "packing", Detail: "compiled repeated packing differs from native kind " + fact.Kind}) }
				}
			} else if field.GetLabel() == descriptorpb.FieldDescriptorProto_LABEL_REPEATED { report.Issues = append(report.Issues, liteIssue{Message: facts.Name, Field: fact.Number, Check: "cardinality", Detail: "native singular field compiled repeated"}) }
			if fact.Cardinality == "oneof" {
				if field.OneofIndex == nil { report.Issues = append(report.Issues, liteIssue{Message: facts.Name, Field: fact.Number, Check: "oneof", Detail: "native oneof field compiled outside oneof"}) } else if other, exists := groups[fact.HasIndex]; exists && other != field.GetOneofIndex() { report.Issues = append(report.Issues, liteIssue{Message: facts.Name, Field: fact.Number, Check: "oneof-group", Detail: "native shared case offset compiled into distinct groups"}) } else { groups[fact.HasIndex] = field.GetOneofIndex() }
				if field.OneofIndex != nil {
					if nativeOffset, exists := inverseGroups[field.GetOneofIndex()]; exists && nativeOffset != fact.HasIndex { report.Issues = append(report.Issues, liteIssue{Message: facts.Name, Field: fact.Number, Check: "oneof-group", Detail: "distinct native case offsets merged into one compiled group"}) }
					inverseGroups[field.GetOneofIndex()] = fact.HasIndex
				}
			} else if field.OneofIndex != nil { report.Issues = append(report.Issues, liteIssue{Message: facts.Name, Field: fact.Number, Check: "oneof", Detail: "native non-oneof field compiled inside oneof"}) }
			proof.Fields = append(proof.Fields, entry)
		}
		report.OneofGroups += len(groups)
		proofs = append(proofs, proof)
	}
	actualEnums := liteEnums(set)
	for name, original := range liteEnums(referenceSet) {
		if !strings.HasPrefix(name, "spotify.login5.v3.") { continue }
		actual := actualEnums[name]
		if actual == nil { report.Issues = append(report.Issues, liteIssue{Message: name, Check: "enum", Detail: "pinned enum omitted from compiled reconstruction"}); continue }
		report.ValidatedEnums++
		expected := map[string]int32{}
		for _, value := range original.Value { expected[value.GetName()] = value.GetNumber() }
		if name == "spotify.login5.v3.LoginError" { expected["NOT_ALLOWED"] = 9 }
		if len(actual.Value) != len(expected) { report.Issues = append(report.Issues, liteIssue{Message: name, Check: "enum-values", Detail: fmt.Sprintf("compiled %d members versus evidenced %d", len(actual.Value), len(expected))}) }
		for _, value := range actual.Value {
			number, exists := expected[value.GetName()]
			if !exists || number != value.GetNumber() { report.Issues = append(report.Issues, liteIssue{Message: name, Check: "enum-values", Detail: fmt.Sprintf("member %s=%d differs from evidenced mapping", value.GetName(), value.GetNumber())}) } else { report.ValidatedEnumValues++ }
		}
	}
	return report, proofs
}

func liteEnums(set *descriptorpb.FileDescriptorSet) map[string]*descriptorpb.EnumDescriptorProto {
	result := map[string]*descriptorpb.EnumDescriptorProto{}
	var walk func(string, []*descriptorpb.DescriptorProto)
	walk = func(prefix string, messages []*descriptorpb.DescriptorProto) {
		for _, message := range messages {
			fullName := prefix + "." + message.GetName()
			for _, enumeration := range message.EnumType { result[fullName+"."+enumeration.GetName()] = enumeration }
			walk(fullName, message.NestedType)
		}
	}
	for _, file := range set.File {
		for _, enumeration := range file.EnumType { result[file.GetPackage()+"."+enumeration.GetName()] = enumeration }
		walk(file.GetPackage(), file.MessageType)
	}
	return result
}

func reconstructedEnumProof(set *descriptorpb.FileDescriptorSet) []map[string]any {
	var names []string
	values := liteEnums(set)
	for name := range values { if strings.HasPrefix(name, "spotify.login5.") { names = append(names, name) } }
	sort.Strings(names)
	var result []map[string]any
	for _, name := range names {
		members := map[string]int32{}
		for _, value := range values[name].Value { members[value.GetName()] = value.GetNumber() }
		origin := "pinned public v3 schema; current native labels not retained"
		if name == "spotify.login5.v3.LoginError" { origin = "pinned public v3 enum identity plus current native sorted-name/index mapping including NOT_ALLOWED=9" }
		result = append(result, map[string]any{"name": name, "origin": origin, "values": members})
	}
	return result
}
