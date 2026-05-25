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
