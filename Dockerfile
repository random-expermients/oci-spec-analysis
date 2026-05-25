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
#   crane manifest quay.io/random-experiments/oci-spec-analysis | jq '.layers | length'
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
#     crane manifest --platform linux/amd64 quay.io/random-experiments/oci-spec-analysis \
#       | jq '.layers | length'
# -----------------------------------------------------------------------------
FROM gcr.io/distroless/static:nonroot

# Re-declare ARGs after the second FROM so they are in scope for the LABEL
# instructions below. In multi-stage builds each stage has its own ARG scope.
ARG GIT_COMMIT=unknown
ARG VERSION=0.1.0
ARG BUILD_DATE=unknown

# -----------------------------------------------------------------------------
# OCI standard image annotations (opencontainers/image-spec §Annotations)
#
# These LABEL instructions become key-value pairs in the image config blob
# under .config.Labels. They follow the org.opencontainers.image.* namespace
# defined in the OCI Image Spec.
#
# Verify with:
#   crane config quay.io/random-experiments/oci-spec-analysis \
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
      org.opencontainers.image.source="https://github.com/random-experiments/oci-spec-analysis" \
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
