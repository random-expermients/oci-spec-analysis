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
