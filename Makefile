# =============================================================================
# Makefile — oci-spec-analysis
#
# Targets are grouped by phase:
#   local-*   : build and run without Docker / Kaniko
#   image-*   : build and inspect the container image locally
#   inspect-* : OCI spec inspection commands (requires crane, cosign, jq)
# =============================================================================

IMAGE       ?= quay.io/random-experiments/oci-spec-analysis
VERSION     ?= 0.1.0
GIT_COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE  ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
PORT        ?= 8080

.PHONY: help local-run local-build image-build image-run image-login image-push \
        inspect-manifest inspect-config inspect-layers inspect-all clean

# ── Default ──────────────────────────────────────────────────────────────────

help:
	@echo ""
	@echo "  local-build       compile the binary locally"
	@echo "  local-run         run the binary locally on :$(PORT)"
	@echo "  image-build       docker build with OCI build-args"
	@echo "  image-run         run the image locally"
	@echo "  image-login       docker login to quay.io (reads QUAY_USER / QUAY_PASSWORD)"
	@echo "  image-push        push :VERSION and :latest tags to quay.io"
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

# Login to quay.io.
# Supply credentials via environment variables to avoid storing them in shell
# history.  Example:
#   export QUAY_USER=myuser QUAY_PASSWORD=mytoken
#   make image-login
image-login:
	@echo "→ logging in to quay.io as $${QUAY_USER}"
	@echo "$${QUAY_PASSWORD}" | docker login quay.io -u "$${QUAY_USER}" --password-stdin

# Push both the versioned tag and :latest to quay.io.
# Depends on image-build so a fresh local build is always pushed.
# Run image-login first if you are not already authenticated.
image-push: image-build
	@echo "→ pushing $(IMAGE):$(VERSION)"
	docker push $(IMAGE):$(VERSION)
	@echo "→ pushing $(IMAGE):latest"
	docker push $(IMAGE):latest
	@echo "→ pushed. Pinned digest:"
	docker inspect --format='{{index .RepoDigests 0}}' $(IMAGE):latest

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
