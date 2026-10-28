#!/bin/sh
# Bootstraps lakehouse storage on every `up` (idempotent):
#   lakehouse    Delta tables + least-privilege service account used by Trino and delta-sink
#   raw-docs     raw layer: original operational logs (bitácoras), versioned, uploaded only when
#                their SHA-256 changes, tagged with their SAP coordinates (Año/Mes/RCNTR) and
#                cataloged in Unity Catalog as EXTERNAL volumes
# The MinIO image ships no grep/sed/awk: string checks use sh `case` patterns.
set -eu

mc alias set lake http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null

# ── Lakehouse bucket + service account (the root account is reserved for administration) ──
mc mb --ignore-existing lake/lakehouse

cat > /tmp/lakehouse-rw.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"],
      "Resource": ["arn:aws:s3:::lakehouse"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject",
                 "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::lakehouse/*"]
    }
  ]
}
EOF
mc admin policy create lake lakehouse-rw /tmp/lakehouse-rw.json
mc admin user add lake "$LAKEHOUSE_S3_ACCESS_KEY" "$LAKEHOUSE_S3_SECRET_KEY"
case "$(mc admin user info lake "$LAKEHOUSE_S3_ACCESS_KEY" --json)" in
  *lakehouse-rw*) ;;
  *) mc admin policy attach lake lakehouse-rw --user "$LAKEHOUSE_S3_ACCESS_KEY" ;;
esac
echo "[minio-init] bucket 'lakehouse' + service account '$LAKEHOUSE_S3_ACCESS_KEY' (policy lakehouse-rw) ready"

# ── Raw layer: original documents (Markdown/PDF) mounted from knowledge/raw-docs/<source>/ ──
front_matter() {  # value of KEY ($1) in the YAML front matter of a Markdown file ($2)
  while IFS= read -r line; do
    case "$line" in "$1: "*) printf '%s' "${line#"$1": }"; return ;; esac
  done < "$2"
}

mc mb --ignore-existing lake/raw-docs
mc version enable lake/raw-docs >/dev/null
uploaded=0
unchanged=0
for file in /seed/raw-docs/*/*; do
  key=${file#/seed/raw-docs/}
  set -- $(sha256sum "$file")
  sha=$1
  case "$(mc stat --json "lake/raw-docs/$key" 2>/dev/null)" in
    *"$sha"*) unchanged=$((unchanged + 1)); continue ;;
  esac
  classification="" language="" rcntr="" gjahr="" monat=""
  case "$file" in
    *.md)  content_type=text/markdown
           classification=$(front_matter classification "$file")
           language=$(front_matter language "$file")
           rcntr=$(front_matter rcntr "$file")
           gjahr=$(front_matter gjahr "$file")
           monat=$(front_matter monat "$file") ;;
    *.pdf) content_type=application/pdf ;;
    *)     content_type=text/plain ;;
  esac
  mc cp --quiet --attr "Content-Type=$content_type;Sha256=$sha;Classification=${classification:-UNCLASSIFIED};Language=${language:-und};Rcntr=${rcntr:-none};Gjahr=${gjahr:-none};Monat=${monat:-none}" \
     "$file" "lake/raw-docs/$key" >/dev/null
  uploaded=$((uploaded + 1))
done
echo "[minio-init] bucket 'raw-docs' (versioned): $uploaded uploaded, $unchanged unchanged (SHA-256)"

# ── Governance: one EXTERNAL Unity Catalog volume per source prefix (nodara.raw.docs_<source>) ──
uc_create() {  # idempotent: *_ALREADY_EXISTS counts as success
  response=$(curl -s -X POST -H 'Content-Type: application/json' -d "$2" -w ' HTTP_%{http_code}' "$UC_API$1")
  case "$response" in
    *HTTP_200 | *HTTP_201 | *ALREADY_EXISTS*) ;;
    *) echo "[minio-init] WARNING Unity Catalog $1: $response" >&2; return 1 ;;
  esac
}

uc_create /catalogs '{"name":"nodara","comment":"Nodara Rolling Forecast lakehouse (MinIO + Delta Lake)"}' || true
uc_create /schemas '{"name":"raw","catalog_name":"nodara","comment":"Raw layer: original unstructured source files"}' || true
for dir in /seed/raw-docs/*/; do
  source=${dir%/}
  source=${source##*/}
  uc_create /volumes "{\"catalog_name\":\"nodara\",\"schema_name\":\"raw\",\"name\":\"docs_$source\",\"volume_type\":\"EXTERNAL\",\"storage_location\":\"s3://raw-docs/$source\",\"comment\":\"Original operational documents ($source), versioned raw layer\"}" \
    && echo "[minio-init] Unity Catalog volume nodara.raw.docs_$source -> s3://raw-docs/$source" || true
done
