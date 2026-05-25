package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
)

// ---------------------------------------------------------------------------
// Build-time variables — injected via -ldflags by the Dockerfile.
// Each variable maps to a concept in the OCI Image Spec:
//
//   gitCommit   → stored in the image config blob under .config.Labels
//                 (org.opencontainers.image.revision)
//   version     → stored in the image config blob under .config.Labels
//                 (org.opencontainers.image.version)
//   manifestDigest → the sha256 of the Image Manifest itself; passed in as a
//                 build-arg so the running container can report it
//   configDigest  → the sha256 of the config blob
//   layerCount    → number of layers in the manifest .layers[] array
// ---------------------------------------------------------------------------
var (
	gitCommit      = "unknown"
	version        = "0.1.0"
	manifestDigest = "unknown" // set via --build-arg MANIFEST_DIGEST (post-push, or left unknown for first build)
	configDigest   = "unknown" // set via --build-arg CONFIG_DIGEST
	layerCountStr  = "2"       // set via --build-arg LAYER_COUNT; distroless gives us exactly 2
	registry       = "quay.io/random-expermients/oci-spec-analysis"
	baseImage      = "gcr.io/distroless/static:nonroot"
	builtBy        = "kaniko"
)

// ---------------------------------------------------------------------------
// OCIInfo is the JSON structure served on GET /oci-info.
// Every field is a teaching anchor — it maps to a concrete OCI spec concept.
// ---------------------------------------------------------------------------
type OCIInfo struct {
	App         string      `json:"app"`
	Version     string      `json:"version"`
	GitCommit   string      `json:"git_commit"`
	BuiltBy     string      `json:"built_by"`
	Registry    string      `json:"registry"`
	OCIConcepts OCIConcepts `json:"oci_concepts"`
}

// OCIConcepts surfaces the OCI Image Spec vocabulary directly in the API response.
// Each field corresponds to something you can independently verify with `crane` or `curl`.
type OCIConcepts struct {
	// ManifestDigest is the sha256 of the Image Manifest JSON blob in the registry.
	// Verify: crane digest quay.io/random-expermients/oci-spec-analysis
	ManifestDigest string `json:"manifest_digest"`

	// ConfigDigest is the sha256 of the image config blob.
	// The config blob holds Entrypoint, Env, Labels, and the ordered DiffIDs of layers.
	// Verify: crane manifest ... | jq .config.digest
	ConfigDigest string `json:"config_digest"`

	// LayerCount is the length of the .layers[] array in the Image Manifest.
	// For this image it is always 2: the distroless base layer + our COPY layer.
	// Verify: crane manifest ... | jq '.layers | length'
	LayerCount int `json:"layer_count"`

	// BaseImage is the FROM image used in the final Dockerfile stage.
	// Its layers are referenced by digest in our manifest — they are shared
	// across all images built on distroless/static:nonroot.
	BaseImage string `json:"base_image"`

	// ConceptMap explains each OCI term encountered when inspecting this image.
	ConceptMap map[string]string `json:"concept_map"`
}

var conceptMap = map[string]string{
	"Image Manifest":  "JSON document listing the config blob digest and the ordered layer blob digests. Identified by sha256 (manifest_digest above). Fetch with: crane manifest <image>",
	"Image Index":     "A manifest that points to other manifests — one per platform. Enables multi-arch. Fetch with: crane manifest <image> (top level)",
	"Config blob":     "JSON blob holding Entrypoint, Env, ExposedPorts, Labels, OS, Arch, and layer DiffIDs. Fetch with: crane config <image>",
	"Layer blob":      "gzipped tar archive of filesystem changes (delta from previous layer). This image has 2 layers. Inspect with: crane blob <image>@<layer-digest> | tar -tzf -",
	"Descriptor":      "{ mediaType, digest, size } pointer used inside manifests to reference blobs",
	"Digest":          "sha256 content address. Tags are mutable pointers to a digest. Digests are immutable.",
	"OCI Annotations": "The LABEL instructions in the Dockerfile become .config.Labels in the config blob. See: crane config <image> | jq .config.Labels",
	"Referrers API":   "Registry endpoint listing artefacts attached to a digest (signatures, SBOMs, attestations). See: crane referrers <image>",
	"DSSE envelope":   "{ payloadType, payload (base64), signatures[] } — the JSON structure Tekton Chains produces when signing this image",
	"SLSA predicate":  "The decoded .payload inside the DSSE envelope — structured provenance claim describing builder, invocation, materials",
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

func ociInfoHandler(w http.ResponseWriter, r *http.Request) {
	lc, err := strconv.Atoi(layerCountStr)
	if err != nil {
		lc = 2
	}

	info := OCIInfo{
		App:       "oci-spec-analysis",
		Version:   version,
		GitCommit: gitCommit,
		BuiltBy:   builtBy,
		Registry:  registry,
		OCIConcepts: OCIConcepts{
			ManifestDigest: manifestDigest,
			ConfigDigest:   configDigest,
			LayerCount:     lc,
			BaseImage:      baseImage,
			ConceptMap:     conceptMap,
		},
	}

	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	if err := enc.Encode(info); err != nil {
		http.Error(w, "encode error", http.StatusInternalServerError)
	}
}

func healthzHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintln(w, `{"status":"ok"}`)
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s %s", r.Method, r.URL.Path)
		next.ServeHTTP(w, r)
	})
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/oci-info", ociInfoHandler)
	mux.HandleFunc("/healthz", healthzHandler)

	addr := fmt.Sprintf(":%s", port)
	log.Printf("oci-spec-analysis %s (commit=%s) listening on %s", version, gitCommit, addr)
	log.Printf("OCI learning endpoints:")
	log.Printf("  GET /oci-info  — image metadata + OCI concept map")
	log.Printf("  GET /healthz   — liveness probe")

	if err := http.ListenAndServe(addr, loggingMiddleware(mux)); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
