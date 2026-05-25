# Phase 1 — Repo Files: `oci-spec-analysis`

Everything below is ready to copy into
`https://github.com/random-expermients/oci-spec-analysis`.
No `.tekton/` files are included — those are Phase 2.

---

## Directory layout after Phase 1

```
oci-spec-analysis/
├── app/
│   ├── main.go
│   └── go.mod
├── Dockerfile
├── Makefile
├── docs/
│   └── oci-concepts.md
└── README.md
```

---

## `app/main.go`

```go
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
	App        string     `json:"app"`
	Version    string     `json:"version"`
	GitCommit  string     `json:"git_commit"`
	BuiltBy    string     `json:"built_by"`
	Registry   string     `json:"registry"`
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
	"Image Manifest":   "JSON document listing the config blob digest and the ordered layer blob digests. Identified by sha256 (manifest_digest above). Fetch with: crane manifest <image>",
	"Image Index":      "A manifest that points to other manifests — one per platform. Enables multi-arch. Fetch with: crane manifest <image> (top level)",
	"Config blob":      "JSON blob holding Entrypoint, Env, ExposedPorts, Labels, OS, Arch, and layer DiffIDs. Fetch with: crane config <image>",
	"Layer blob":       "gzipped tar archive of filesystem changes (delta from previous layer). This image has 2 layers. Inspect with: crane blob <image>@<layer-digest> | tar -tzf -",
	"Descriptor":       "{ mediaType, digest, size } pointer used inside manifests to reference blobs",
	"Digest":           "sha256 content address. Tags are mutable pointers to a digest. Digests are immutable.",
	"OCI Annotations":  "The LABEL instructions in the Dockerfile become .config.Labels in the config blob. See: crane config <image> | jq .config.Labels",
	"Referrers API":    "Registry endpoint listing artefacts attached to a digest (signatures, SBOMs, attestations). See: crane referrers <image>",
	"DSSE envelope":    "{ payloadType, payload (base64), signatures[] } — the JSON structure Tekton Chains produces when signing this image",
	"SLSA predicate":   "The decoded .payload inside the DSSE envelope — structured provenance claim describing builder, invocation, materials",
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
```

---

## `app/go.mod`

```
module github.com/random-expermients/oci-spec-analysis

go 1.22
```

> No external dependencies. The standard library `net/http` and `encoding/json`
> are sufficient. This keeps the image small and the layer diff minimal — which
> is the point.

---

## `Dockerfile`

```dockerfile
# syntax=docker/dockerfile:1

# =============================================================================
# OCI Spec Analysis — Dockerfile
#
# This Dockerfile is written as a TEACHING DOCUMENT. Every decision maps to a
# concept in the OCI Image Spec. Comments explain *why* each instruction exists
# in OCI terms, not just what it does.
#
# OCI Image Spec reference: https://github.com/opencontainers/image-spec
# =============================================================================


# -----------------------------------------------------------------------------
# Stage 1 — builder
#
# OCI concept: Multi-stage builds
#   This stage produces the binary but its layers are NEVER included in the
#   final image manifest. In OCI terms: the builder image's layer blobs exist
#   only in the build cache — they are not referenced by the final manifest's
#   .layers[] array and are never pushed to the registry.
#
# After the build, run:
#   crane manifest quay.io/random-expermients/oci-spec-analysis | jq '.layers | length'
# You will see 2, not the ~10+ layers that golang:1.22-alpine would produce.
# -----------------------------------------------------------------------------
FROM golang:1.22-alpine AS builder

# -----------------------------------------------------------------------------
# Build args — injected by Kaniko (or docker build --build-arg).
#
# OCI concept: Image Labels / Annotations
#   ARG values flow into the LABEL instructions in Stage 2. Labels end up in
#   the image *config blob* under .config.Labels — readable with:
#     crane config <image> | jq '.config.Labels'
#
#   They also get compiled into the binary via -ldflags so the running
#   container can report its own OCI metadata at GET /oci-info.
# -----------------------------------------------------------------------------
ARG GIT_COMMIT=unknown
ARG VERSION=0.1.0
ARG BUILD_DATE=unknown
ARG MANIFEST_DIGEST=unknown
ARG CONFIG_DIGEST=unknown
ARG LAYER_COUNT=2

WORKDIR /src
COPY app/ .

RUN go mod download

# CGO_ENABLED=0 produces a fully static binary — no libc dependency.
# This is what makes the distroless base image viable.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags=" \
      -X main.gitCommit=${GIT_COMMIT} \
      -X main.version=${VERSION} \
      -X main.manifestDigest=${MANIFEST_DIGEST} \
      -X main.configDigest=${CONFIG_DIGEST} \
      -X main.layerCountStr=${LAYER_COUNT} \
    " \
    -o /out/oci-spec-analysis \
    .


# -----------------------------------------------------------------------------
# Stage 2 — final image
#
# OCI concept: Base image layers and content-addressability
#   distroless/static:nonroot is referenced here BY TAG, but the registry
#   resolves it to a specific digest. That digest's layer blobs are listed
#   first in our manifest's .layers[] array — they are SHARED with every
#   other image that uses this same base.
#
#   Why distroless?
#   - Produces exactly TWO layers in our final manifest:
#       Layer 1 — the distroless base layer (pulled from gcr.io by digest)
#       Layer 2 — the COPY layer containing only our binary
#   - Two layers = a manifest.layers[] array you can read in 30 seconds.
#   - No shell, no package manager → smaller attack surface.
#
#   Verify the layer count after pushing:
#     crane manifest --platform linux/amd64 quay.io/random-expermients/oci-spec-analysis \
#       | jq '.layers | length'
# -----------------------------------------------------------------------------
FROM gcr.io/distroless/static:nonroot

# -----------------------------------------------------------------------------
# OCI standard image annotations (opencontainers/image-spec §Annotations)
#
# These LABEL instructions become key-value pairs in the image config blob
# under .config.Labels. They follow the org.opencontainers.image.* namespace
# defined in the OCI Image Spec.
#
# Verify with:
#   crane config quay.io/random-expermients/oci-spec-analysis \
#     | jq '.config.Labels'
#
# You should see:
#   "org.opencontainers.image.revision": "<GIT_COMMIT>",
#   "org.opencontainers.image.version":  "0.1.0",
#   etc.
# -----------------------------------------------------------------------------
LABEL org.opencontainers.image.title="oci-spec-analysis" \
      org.opencontainers.image.description="Minimal Go app for OCI Image Spec learning" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="https://github.com/random-expermients/oci-spec-analysis" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.base.name="gcr.io/distroless/static:nonroot"

# -----------------------------------------------------------------------------
# OCI concept: Layer creation
#
# Every COPY, RUN, or ADD in the final stage creates a new layer blob.
# This single COPY instruction creates Layer 2 — a gzipped tar containing
# only /oci-spec-analysis.
#
# Inspect it with:
#   LAYER=$(crane manifest --platform linux/amd64 <image> | jq -r '.layers[-1].digest')
#   crane blob <image>@$LAYER | tar -tzf -
# You will see exactly one file: ./oci-spec-analysis
# -----------------------------------------------------------------------------
COPY --from=builder /out/oci-spec-analysis /oci-spec-analysis

# -----------------------------------------------------------------------------
# OCI concept: Image config blob fields
#
# USER   → .config.User        in the config blob
# EXPOSE → .config.ExposedPorts in the config blob
# ENTRYPOINT → .config.Entrypoint in the config blob
#
# Verify all three:
#   crane config <image> | jq '.config | {User, ExposedPorts, Entrypoint}'
# -----------------------------------------------------------------------------
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/oci-spec-analysis"]
```

---

## `Makefile`

```makefile
# =============================================================================
# Makefile — oci-spec-analysis
#
# Targets are grouped by phase:
#   local-*   : build and run without Docker / Kaniko
#   image-*   : build and inspect the container image locally
#   inspect-* : OCI spec inspection commands (requires crane, cosign, jq)
# =============================================================================

IMAGE       ?= quay.io/random-expermients/oci-spec-analysis
VERSION     ?= 0.1.0
GIT_COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE  ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
PORT        ?= 8080

.PHONY: help local-run local-build image-build image-run inspect-manifest \
        inspect-config inspect-layers inspect-all clean

# ── Default ──────────────────────────────────────────────────────────────────

help:
	@echo ""
	@echo "  local-build       compile the binary locally"
	@echo "  local-run         run the binary locally on :$(PORT)"
	@echo "  image-build       docker build with OCI build-args"
	@echo "  image-run         run the image locally"
	@echo "  inspect-manifest  crane manifest \$$IMAGE | jq ."
	@echo "  inspect-config    crane config \$$IMAGE | jq .config"
	@echo "  inspect-layers    list all layer digests + sizes"
	@echo "  inspect-all       run all inspect-* targets in sequence"
	@echo "  clean             remove local build artefacts"
	@echo ""

# ── Local (no Docker) ────────────────────────────────────────────────────────

local-build:
	@echo "→ compiling binary"
	cd app && CGO_ENABLED=0 GOOS=linux go build \
	  -ldflags="-X main.gitCommit=$(GIT_COMMIT) -X main.version=$(VERSION)" \
	  -o ../bin/oci-spec-analysis .

local-run: local-build
	@echo "→ running on :$(PORT)  (GET /oci-info  GET /healthz)"
	./bin/oci-spec-analysis

# ── Image ────────────────────────────────────────────────────────────────────

image-build:
	@echo "→ docker build  IMAGE=$(IMAGE)  COMMIT=$(GIT_COMMIT)"
	docker build \
	  --build-arg GIT_COMMIT=$(GIT_COMMIT) \
	  --build-arg VERSION=$(VERSION) \
	  --build-arg BUILD_DATE=$(BUILD_DATE) \
	  -t $(IMAGE):$(VERSION) \
	  -t $(IMAGE):latest \
	  .

image-run: image-build
	@echo "→ running image on :$(PORT)"
	docker run --rm -p $(PORT):8080 $(IMAGE):latest

# ── OCI Inspection ───────────────────────────────────────────────────────────
# These targets demonstrate OCI spec concepts by inspecting the real image.
# They require: crane  jq  cosign

inspect-manifest:
	@echo "\n=== Image Index (multi-arch wrapper) ==="
	crane manifest $(IMAGE):latest | jq .
	@echo "\n=== Platform manifest (linux/amd64) ==="
	crane manifest --platform linux/amd64 $(IMAGE):latest | jq .

inspect-config:
	@echo "\n=== Full config blob ==="
	crane config $(IMAGE):latest | jq .
	@echo "\n=== OCI annotations (from LABEL instructions) ==="
	crane config $(IMAGE):latest | jq '.config.Labels'
	@echo "\n=== Runtime config (Entrypoint / Env / User / ExposedPorts) ==="
	crane config $(IMAGE):latest | jq '.config | {Entrypoint, Env, User, ExposedPorts}'

inspect-layers:
	@echo "\n=== Layers (digest + size) ==="
	crane manifest --platform linux/amd64 $(IMAGE):latest \
	  | jq '.layers[] | {digest: .digest, size_kb: (.size/1024|floor), mediaType}'
	@echo "\n=== Contents of the final layer (our binary) ==="
	@LAYER=$$(crane manifest --platform linux/amd64 $(IMAGE):latest | jq -r '.layers[-1].digest'); \
	crane blob $(IMAGE):latest@$$LAYER | tar -tzf -

inspect-referrers:
	@echo "\n=== Referrers (signatures / attestations attached by Chains) ==="
	crane referrers $(IMAGE):latest

inspect-attestation:
	@echo "\n=== Raw DSSE envelope from Tekton Chains ==="
	cosign download attestation $(IMAGE):latest | jq .
	@echo "\n=== Decoded in-toto SLSA payload ==="
	cosign download attestation $(IMAGE):latest \
	  | jq -r '.payload' | base64 -d | jq .

inspect-all: inspect-manifest inspect-config inspect-layers inspect-referrers

# ── Clean ─────────────────────────────────────────────────────────────────────

clean:
	rm -rf bin/
```

---

## `docs/oci-concepts.md`

```markdown
# OCI Image Spec — Concepts in This Image

This document maps every OCI Image Spec term to something you can directly
observe in `quay.io/random-expermients/oci-spec-analysis`.

Run the commands below after the image is pushed to Quay.

```bash
IMAGE=quay.io/random-expermients/oci-spec-analysis
```

---

## 1. Blob

A blob is any content stored in a registry, identified by its SHA-256 digest.
There are three kinds of blobs in an OCI image: the manifest, the config, and
each layer. Nothing is stored by name — only by hash.

```bash
# The manifest IS a blob — its digest is the image's stable identity
crane digest $IMAGE
```

---

## 2. Image Manifest

The manifest is a JSON document that ties one config blob to an ordered list
of layer blobs. It is the single thing you fetch when you `docker pull`.

```bash
# Fetch the manifest for linux/amd64
crane manifest --platform linux/amd64 $IMAGE | jq .
```

What you will see:

| Field | Meaning |
|---|---|
| `schemaVersion` | Always 2 for OCI / Docker v2 |
| `mediaType` | `application/vnd.oci.image.manifest.v1+json` |
| `config.digest` | sha256 of the config blob |
| `config.size` | byte size of the config blob |
| `layers[]` | Ordered array of layer descriptors — **2 entries** for this image |
| `layers[].digest` | sha256 of that layer's gzipped tar |
| `layers[].mediaType` | `application/vnd.oci.image.layer.v1.tar+gzip` |

---

## 3. Image Index

An image index is a manifest that points to *other* manifests — one per
platform. It is what you get when you run `docker manifest inspect` on a
multi-arch image.

```bash
# Fetch the top-level index (no --platform flag)
crane manifest $IMAGE | jq .
```

The index itself has no layers — only a `manifests[]` array of platform
descriptors. Each entry has a `digest` pointing to a platform-specific
manifest, and a `platform` object with `os` and `architecture`.

---

## 4. Config Blob

The config blob is a JSON object that holds everything the container runtime
needs to run the image: Entrypoint, Cmd, Env, ExposedPorts, User, and the
`rootfs.diff_ids` (uncompressed layer sha256s used by the runtime to verify
the layer stack).

```bash
# Full config
crane config $IMAGE | jq .

# Just the runtime config (maps directly to Dockerfile instructions)
crane config $IMAGE | jq '.config | {Entrypoint, Env, User, ExposedPorts}'

# OCI annotations — these come from the LABEL instructions in the Dockerfile
crane config $IMAGE | jq '.config.Labels'
```

**Dockerfile → config blob mapping:**

| Dockerfile instruction | Config blob field |
|---|---|
| `ENTRYPOINT ["/oci-spec-analysis"]` | `.config.Entrypoint` |
| `EXPOSE 8080` | `.config.ExposedPorts` |
| `USER nonroot:nonroot` | `.config.User` |
| `LABEL org.opencontainers.image.*` | `.config.Labels` |
| `ENV KEY=VAL` | `.config.Env` |

---

## 5. Layer Blobs

Each layer is a gzipped tar archive of the *delta* from the previous layer.
This image has exactly **2 layers**:

| Layer | What it contains | Origin |
|---|---|---|
| Layer 1 | The distroless/static:nonroot filesystem | Pulled from gcr.io by digest — shared with all images using this base |
| Layer 2 | `/oci-spec-analysis` binary only | Created by the `COPY --from=builder` instruction |

```bash
# List layers with digest + size
crane manifest --platform linux/amd64 $IMAGE \
  | jq '.layers[] | {digest: .digest, size_kb: (.size/1024|floor)}'

# Inspect the contents of the final layer (should show only our binary)
LAYER=$(crane manifest --platform linux/amd64 $IMAGE | jq -r '.layers[-1].digest')
crane blob $IMAGE@$LAYER | tar -tzf -
```

---

## 6. Content-Addressability

Tags (`latest`, `0.1.0`) are mutable pointers. The digest is the immutable
identity. Two images with identical content produce identical digests.

```bash
# The digest never changes unless the image content changes
crane digest $IMAGE:latest
crane digest $IMAGE:0.1.0

# Pin to a specific digest for reproducible pulls
docker pull $IMAGE@sha256:<digest>
```

---

## 7. OCI Annotations

The OCI Image Spec defines a standard namespace for image labels:
`org.opencontainers.image.*`. These are written into the config blob and are
readable without running the container.

```bash
crane config $IMAGE | jq '.config.Labels'
```

Expected output:

```json
{
  "org.opencontainers.image.title":       "oci-spec-analysis",
  "org.opencontainers.image.version":     "0.1.0",
  "org.opencontainers.image.revision":    "<git-commit>",
  "org.opencontainers.image.created":     "2025-...",
  "org.opencontainers.image.source":      "https://github.com/random-expermients/oci-spec-analysis",
  "org.opencontainers.image.licenses":    "Apache-2.0",
  "org.opencontainers.image.base.name":   "gcr.io/distroless/static:nonroot"
}
```

---

## 8. Descriptor

A descriptor is the pointer type used inside manifests to reference blobs:

```json
{
  "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
  "digest":    "sha256:abc123...",
  "size":      3408609
}
```

Every entry in `layers[]`, the `config` field, and the `manifests[]` of an
index is a descriptor. Nothing in OCI is referenced by name — only by
`mediaType` + `digest` + `size`.

---

## 9. Referrers API

The Referrers API (`GET /v2/<name>/referrers/<digest>`) lists all OCI
artefacts whose manifest contains a `subject` field pointing at a given digest.
This is how Tekton Chains attaches a provenance attestation to the image
without modifying the image manifest itself.

```bash
# After Tekton Chains runs, this should list the attestation blob
crane referrers $IMAGE
```

---

## 10. DSSE Envelope (Tekton Chains output)

When Tekton Chains signs the image it produces a **DSSE (Dead Simple Signing
Envelope)** — a JSON structure wrapping the SLSA provenance payload:

```json
{
  "payloadType": "application/vnd.in-toto+json",
  "payload":     "<base64-encoded in-toto statement>",
  "signatures":  [{ "keyid": "...", "sig": "<base64-ECDSA>" }]
}
```

This envelope is stored as an OCI artefact in the same registry, attached to
the image digest via the Referrers API.

```bash
# See the raw envelope
cosign download attestation $IMAGE | jq .

# Decode the payload to read the SLSA provenance
cosign download attestation $IMAGE \
  | jq -r '.payload' | base64 -d | jq .
```

The decoded payload is an **in-toto statement** whose `predicate` field
contains the SLSA provenance: builder identity, build invocation, source
materials (git commit + repo URL).

---

## Summary: what each `crane` command shows you

| Command | OCI concept revealed |
|---|---|
| `crane digest $IMAGE` | Content-addressability — the immutable identity of the manifest |
| `crane manifest $IMAGE` | Image Index — multi-arch manifest list |
| `crane manifest --platform linux/amd64 $IMAGE` | Image Manifest — config + layers descriptors |
| `crane config $IMAGE` | Config blob — runtime metadata + labels |
| `crane config $IMAGE \| jq '.config.Labels'` | OCI annotations from LABEL instructions |
| `crane manifest … \| jq '.layers[]'` | Layer descriptors — digest, size, mediaType |
| `crane blob $IMAGE@<digest> \| tar -tzf -` | Layer blob contents — the actual filesystem delta |
| `crane referrers $IMAGE` | Referrers API — attestations / signatures attached by Chains |
| `cosign download attestation $IMAGE` | DSSE envelope structure |
| `… \| jq -r '.payload' \| base64 -d \| jq .` | in-toto SLSA predicate — the provenance claim |
```

---

## `README.md`

```markdown
# oci-spec-analysis

A minimal Go HTTP server built to make the **OCI Image Spec** tangible.
Every file in this repo is a teaching artefact. The app, the Dockerfile, and
the Makefile are all annotated to map source-code concepts to OCI spec
terminology.

## What this repo demonstrates

| OCI concept | Where you see it |
|---|---|
| Image Manifest | `make inspect-manifest` |
| Image Index (multi-arch) | `crane manifest quay.io/random-expermients/oci-spec-analysis` |
| Config blob | `make inspect-config` |
| Layer blobs (exactly 2) | `make inspect-layers` |
| OCI Annotations | `crane config … \| jq '.config.Labels'` |
| Content-addressability | `crane digest …` |
| Referrers API | `make inspect-referrers` (after Tekton Chains runs) |
| DSSE envelope | `make inspect-attestation` (after Tekton Chains runs) |
| SLSA provenance | decoded payload from the DSSE envelope |

## Repository layout

```
oci-spec-analysis/
├── app/
│   ├── main.go          # Go HTTP server; GET /oci-info returns its own OCI metadata
│   └── go.mod
├── Dockerfile           # multi-stage, commented as an OCI spec teaching doc
├── Makefile             # local build + OCI inspection targets
├── docs/
│   └── oci-concepts.md  # full OCI term reference mapped to this image
└── README.md
```

## Quick start

### Prerequisites

```bash
# Required for local binary build
go 1.22+

# Required for image build
docker

# Required for OCI inspection
brew install crane cosign jq   # or equivalent
```

### Run locally (no container)

```bash
make local-run
# GET http://localhost:8080/oci-info
# GET http://localhost:8080/healthz
```

### Build the image locally

```bash
make image-build IMAGE=quay.io/random-expermients/oci-spec-analysis
make image-run
```

### Inspect the OCI spec (after push)

```bash
export IMAGE=quay.io/random-expermients/oci-spec-analysis

# See the Image Index and platform manifest
make inspect-manifest

# See the config blob — labels, entrypoint, env
make inspect-config

# See the 2 layers and their contents
make inspect-layers

# After Tekton Chains runs — see the DSSE attestation
make inspect-attestation
```

## The app — `GET /oci-info`

The app serves a single JSON endpoint that reports its own OCI metadata,
compiled in at build time via `-ldflags`:

```json
{
  "app": "oci-spec-analysis",
  "version": "0.1.0",
  "git_commit": "abc1234",
  "built_by": "kaniko",
  "registry": "quay.io/random-expermients/oci-spec-analysis",
  "oci_concepts": {
    "manifest_digest": "sha256:...",
    "config_digest":   "sha256:...",
    "layer_count":     2,
    "base_image":      "gcr.io/distroless/static:nonroot",
    "concept_map":     { "...": "..." }
  }
}
```

The `concept_map` field explains each OCI term inline — making the running
container itself a reference document.

## Why distroless + 2 layers

`gcr.io/distroless/static:nonroot` was chosen as the base image because:

- The final manifest has exactly **2 layers**: the distroless base layer and
  the single `COPY` layer containing the binary.
- Two layers means the `layers[]` array in the manifest is short and fully
  inspectable in under a minute.
- No shell or package manager means no additional filesystem deltas.

Verify this claim after pushing:

```bash
crane manifest --platform linux/amd64 $IMAGE | jq '.layers | length'
# → 2
```

## Phase 2 — Tekton Chains (coming next)

Phase 2 adds `.tekton/kaniko-taskrun.yaml` to build and push this image via
Kaniko inside Tekton, and configure Tekton Chains to produce a signed SLSA
provenance attestation attached to the image digest.

Bootstrap script: https://gist.github.com/anithapriyanatarajan/9b9e5a0575f570d2b978f1e6b2083bde

Full OCI + Chains concept reference: `docs/oci-concepts.md`

## Licence

Apache-2.0
```

---

## File checklist

| File | Status |
|---|---|
| `app/main.go` | ✅ ready to copy |
| `app/go.mod` | ✅ ready to copy |
| `Dockerfile` | ✅ ready to copy |
| `Makefile` | ✅ ready to copy |
| `docs/oci-concepts.md` | ✅ ready to copy |
| `README.md` | ✅ ready to copy |
| `.tekton/` | ⏳ Phase 2 |