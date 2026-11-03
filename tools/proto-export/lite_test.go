package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/descriptorpb"
)

func TestLiteValidatorRejectsNativeContractMismatches(t *testing.T) {
	root, err := filepath.Abs("../..")
	if err != nil { t.Fatal(err) }
	var inventory liteInventory
	if err := readJSON(filepath.Join(root, "reverse-engineering/evidence/login5-lite-tables.json"), &inventory); err != nil { t.Fatal(err) }
	raw, err := os.ReadFile(filepath.Join(root, "proto/reconstructed/login5/reconstructed.pbdesc"))
	if err != nil { t.Fatal(err) }
	compiled := &descriptorpb.FileDescriptorSet{}
	if err := proto.Unmarshal(raw, compiled); err != nil { t.Fatal(err) }
	var pins []liteReference
	if err := readJSON(filepath.Join(root, ".local/reference/login5-schemas/manifest.json"), &pins); err != nil { t.Fatal(err) }
	var names []string
	for _, pin := range pins {
		if pin.Repo == "librespot-org/librespot" { names = append(names, strings.TrimPrefix(pin.Path, "protocol/proto/")) }
	}
	reference, version, err := compileLite(root, filepath.Join(root, ".local/reference/login5-schemas/librespot-org--librespot/protocol/proto"), names, filepath.Join(t.TempDir(), "reference.pbdesc"))
	if err != nil { t.Fatal(err) }
	resolved := map[string]string{"a8377e0201000000": "google.protobuf.Duration"}
	baseline, _ := validateLite(compiled, inventory, reference, resolved, version)
	if len(baseline.Issues) != 0 || len(baseline.NativeUnresolved) != 0 { t.Fatalf("compiled reconstruction fails native contract: %+v / %+v", baseline.Issues, baseline.NativeUnresolved) }
	field := func(set *descriptorpb.FileDescriptorSet, message string, number int32) *descriptorpb.FieldDescriptorProto {
		messages, _ := indexLiteDescriptors(set)
		for _, candidate := range messages[message].Field {
			if candidate.GetNumber() == number { return candidate }
		}
		t.Fatalf("fixture message %q lacks field %d", message, number)
		return nil
	}
	cases := []struct {
		name   string
		check  string
		mutate func(*descriptorpb.FileDescriptorSet)
	}{
		{name: "wrong scalar wire type", check: "type", mutate: func(set *descriptorpb.FileDescriptorSet) {
			field(set, "spotify.login5.v3.ClientInfo", 1).Type = descriptorpb.FieldDescriptorProto_TYPE_BYTES.Enum()
		}},
		{name: "wrong retained name", check: "retained-name", mutate: func(set *descriptorpb.FileDescriptorSet) {
			field(set, "spotify.login5.v3.ClientInfo", 1).Name = proto.String("client_identifier")
		}},
		{name: "different enum identity with same wire kind", check: "enum-identity", mutate: func(set *descriptorpb.FileDescriptorSet) {
			field(set, "spotify.login5.v3.challenges.CodeChallenge", 1).TypeName = proto.String(".spotify.login5.v3.UserInfo.Gender")
		}},
		{name: "enum replaced with int32", check: "type", mutate: func(set *descriptorpb.FileDescriptorSet) {
			field(set, "spotify.login5.v3.LoginResponse", 2).Type = descriptorpb.FieldDescriptorProto_TYPE_INT32.Enum()
		}},
		{name: "packed repeated enum made unpacked", check: "packing", mutate: func(set *descriptorpb.FileDescriptorSet) {
			field(set, "spotify.login5.v3.LoginResponse", 4).Options = &descriptorpb.FieldOptions{Packed: proto.Bool(false)}
		}},
		{name: "oneof field moved outside its group", check: "oneof", mutate: func(set *descriptorpb.FileDescriptorSet) {
			field(set, "spotify.login5.v3.LoginRequest", 100).OneofIndex = nil
		}},
		{name: "resolved Duration type changed", check: "submessage", mutate: func(set *descriptorpb.FileDescriptorSet) {
			field(set, "spotify.login5.v3.challenges.HashcashSolution", 2).TypeName = proto.String(".google.protobuf.Timestamp")
		}},
		{name: "removed Samsung field resurrected from old reference", check: "field-count", mutate: func(set *descriptorpb.FileDescriptorSet) {
			messages, _ := indexLiteDescriptors(set)
			messages["spotify.login5.v3.credentials.SamsungSignInCredential"].Field = append(messages["spotify.login5.v3.credentials.SamsungSignInCredential"].Field,
				&descriptorpb.FieldDescriptorProto{Name: proto.String("id_token"), Number: proto.Int32(3), Type: descriptorpb.FieldDescriptorProto_TYPE_STRING.Enum(), Label: descriptorpb.FieldDescriptorProto_LABEL_OPTIONAL.Enum()})
		}},
		{name: "native NOT_ALLOWED enum ordinal changed", check: "enum-values", mutate: func(set *descriptorpb.FileDescriptorSet) {
			for _, value := range liteEnums(set)["spotify.login5.v3.LoginError"].Value {
				if value.GetName() == "NOT_ALLOWED" { value.Number = proto.Int32(8) }
			}
		}},
	}
	for _, scenario := range cases {
		t.Run(scenario.name, func(t *testing.T) {
			mutated := proto.Clone(compiled).(*descriptorpb.FileDescriptorSet)
			scenario.mutate(mutated)
			report, _ := validateLite(mutated, inventory, reference, resolved, version)
			for _, issue := range report.Issues { if issue.Check == scenario.check { return } }
			t.Fatalf("mutation must report %q; got %+v", scenario.check, report.Issues)
		})
	}
}
