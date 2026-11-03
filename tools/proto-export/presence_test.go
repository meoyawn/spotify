package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// This checks the generated cross-language contract at its file boundary. The
// expectations come from exact retained descriptors, including the optional
// declarations that Dart BuilderInfo loses, rather than from the classifier.
func TestDartPresencePreservesExplicitAndProto2Fields(t *testing.T) {
	output := filepath.Join(t.TempDir(), "presence.dart")
	if err := writeDartPresence("../..", output); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	text := string(raw)
	implicit, messages, found := strings.Cut(text, "const nativeProto3Messages = <String>{\n")
	if !found {
		t.Fatal("generated metadata must declare the complete exact proto3 message set")
	}
	for _, line := range []string{
		`  "spotify.clienttoken.data.v0.ConnectivitySdkData": <int>{2},`,
		`  "spotify.clienttoken.data.v0.NativeAndroidData": <int>{2, 3, 4, 5, 6, 7, 8, 9, 10},`,
		`  "spotify.connectivity.esperanto.proto.ForceOfflineResponse": <int>{1},`,
		`  "spotify.connectivity.esperanto.proto.GetStateResponse": <int>{1, 3},`,
		`  "spotify.connectivity.esperanto.proto.SetConnectionTypeResponse": <int>{1},`,
	} {
		if !strings.Contains(implicit, line+"\n") {
			t.Errorf("generated Dart must preserve native scalar presence: missing %s", line)
		}
	}
	for _, name := range []string{
		"spotify.clienttoken.data.v0.PlatformSpecificData",     // Message oneof only.
		"spotify.connectivity.esperanto.proto.PutRulesRequest", // Four optional bools.
	} {
		if strings.Contains(implicit, `"`+name) {
			t.Errorf("generated metadata must leave explicit or unestablished presence unchanged: %s", name)
		}
	}
	for _, name := range []string{
		"spotify.clienttoken.data.v0.ConnectivitySdkData",
		"spotify.clienttoken.data.v0.PlatformSpecificData",          // Oneof-only messages still have proto3 syntax.
		"spotify.connectivity.esperanto.proto.PutRulesRequest",      // Optional-only messages still have proto3 syntax.
		"spotify.connectivity.esperanto.proto.GetStateRequest",      // Empty top-level message.
		"spotify.player.esperanto.proto.SleepTimer.None",            // Empty nested message.
		"spotify.player.esperanto.proto.ContextTrack.MetadataEntry", // Nested map entry.
	} {
		if !strings.Contains(messages, `  "`+name+"\",\n") {
			t.Errorf("generated message syntax metadata must include %s", name)
		}
	}
	for _, name := range []string{
		"spotify.playlist4.proto.SelectedListContent", // Proto2 syntax remains explicit.
		"spotify.login5.", // Reconstructed inputs do not establish original proto3 declarations.
	} {
		if strings.Contains(text, `"`+name) {
			t.Errorf("generated exact metadata must exclude %s", name)
		}
	}
}
