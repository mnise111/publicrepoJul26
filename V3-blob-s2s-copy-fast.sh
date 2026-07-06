#!/usr/bin/env bash
# v3-blob-s2s-copy-fast.sh
# FAST server-side blob copy into a private storage account using the VM's managed identity.
#
# v2 used `az storage blob copy start` (the async Copy Blob API). That is server-side,
# but cross-account async copies run as low-priority background jobs with NO throughput
# guarantee - a 1 TB copy can crawl for hours.
#
# v3 uses AzCopy's SYNCHRONOUS server-side copy instead: AzCopy fires hundreds of
# parallel Put Page From URL / Put Block From URL calls, and the destination storage
# service pulls each chunk directly from the source over the Azure backbone. Data
# still never touches this VM - only API calls do - but throughput now saturates the
# storage account limits instead of waiting in a background queue. For page-blob VHDs,
# AzCopy also queries the source's allocated page ranges first and copies ONLY the
# used ranges, so a sparse 1 TB VHD with 120 GB written copies as 120 GB.
#
# Usage:
#   ./v3-blob-s2s-copy-fast.sh <dest_storage_account> <dest_container> <dest_blob_name> "<source_uri_with_sas>"
#
# Example:
#   ./v3-blob-s2s-copy-fast.sh myprivateblobsa11 copied myVM-image.vhd \
#     "https://mypublicsrcsa11.blob.core.windows.net/source/myVM-image.vhd?sv=...&sig=..."
#
# Tunables (env vars):
#   AZCOPY_MSI_CLIENT_ID   client ID of a USER-ASSIGNED identity (leave unset for system-assigned)
#   CONCURRENCY            AzCopy parallelism; default AUTO (self-tunes upward until throttled)
#   BLOCK_SIZE_MB          chunk size for block-blob copies; unset = AzCopy auto-sizes.
#                          (Page blobs are capped at 4 MiB per call by the service; ignored for them.)

set -euo pipefail

if [ $# -ne 4 ]; then
  echo "Usage: $0 <dest_storage_account> <dest_container> <dest_blob_name> <source_uri_with_sas>" >&2
  exit 1
fi

DEST_SA="$1"
DEST_CONTAINER="$2"
DEST_BLOB="$3"
SOURCE_URI="$4"
DEST_URL="https://${DEST_SA}.blob.core.windows.net/${DEST_CONTAINER}/${DEST_BLOB}"

START_TS=$(date +%s)
echo "=============================================================="
echo "[$(date '+%F %T')] Fast server-side blob copy starting (AzCopy sync S2S)"
echo "  Destination : ${DEST_URL}"
echo "  Source      : ${SOURCE_URI%%\?*}   (SAS token hidden)"
echo "=============================================================="

# --- 0. Preflight: azcopy must be installed --------------------------------
if ! command -v azcopy >/dev/null 2>&1; then
  echo "[$(date '+%F %T')] ERROR: azcopy not found on PATH." >&2
  echo "  Install (Linux x64):" >&2
  echo "    curl -sL https://aka.ms/downloadazcopy-v10-linux | tar -xz --strip-components=1 -C /usr/local/bin --wildcards '*/azcopy'" >&2
  exit 3
fi
echo "[$(date '+%F %T')] Using $(azcopy --version)"

# --- 1. Authenticate as the VM's managed identity ---------------------------
# az CLI login is still used for container creation + final verification.
echo "[$(date '+%F %T')] Logging in with the VM's managed identity (az CLI)..."
az login --identity --output none

# AzCopy authenticates to the DESTINATION with the same managed identity via IMDS.
# The SOURCE is authorized by the SAS embedded in its URL - no login needed for it.
export AZCOPY_AUTO_LOGIN_TYPE=MSI
[ -n "${AZCOPY_MSI_CLIENT_ID:-}" ] && echo "[$(date '+%F %T')] Using user-assigned identity ${AZCOPY_MSI_CLIENT_ID}"

# --- 2. Speed tuning ---------------------------------------------------------
# AUTO lets AzCopy raise its own concurrency until the storage service starts
# throttling (503s), which is the practical ingress ceiling of the account.
export AZCOPY_CONCURRENCY_VALUE="${CONCURRENCY:-AUTO}"
# Keep logs/job plans on local disk with predictable paths (useful for resume).
export AZCOPY_LOG_LOCATION="${AZCOPY_LOG_LOCATION:-$HOME/.azcopy/logs}"
export AZCOPY_JOB_PLAN_LOCATION="${AZCOPY_JOB_PLAN_LOCATION:-$HOME/.azcopy/plans}"
mkdir -p "$AZCOPY_LOG_LOCATION" "$AZCOPY_JOB_PLAN_LOCATION"

AZCOPY_EXTRA_FLAGS=()
if [ -n "${BLOCK_SIZE_MB:-}" ]; then
  AZCOPY_EXTRA_FLAGS+=(--block-size-mb "$BLOCK_SIZE_MB")
fi

# Sanity check: confirm the destination resolves to a PRIVATE IP (private endpoint)
RESOLVED_IP=$(getent hosts "${DEST_SA}.blob.core.windows.net" | awk '{print $1; exit}')
echo "[$(date '+%F %T')] ${DEST_SA}.blob.core.windows.net resolves to: ${RESOLVED_IP:-<unresolved>}"

# --- 3. Ensure the destination container exists ------------------------------
echo "[$(date '+%F %T')] Ensuring container '${DEST_CONTAINER}' exists..."
az storage container create \
  --account-name "$DEST_SA" \
  --name "$DEST_CONTAINER" \
  --auth-mode login \
  --output none

# --- 4. Run the synchronous server-side copy ---------------------------------
# - Blob type is preserved from the source automatically in S2S mode, so a
#   page-blob VHD stays a page blob (required for managed disk/image creation).
# - --s2s-preserve-access-tier=false avoids needing tier-set permission on dest.
# - --check-length verifies source/dest lengths match after the copy.
# - AzCopy prints live progress (% done, throughput, ETA) - no polling loop needed;
#   the command blocks until the copy finishes, so success/failure is the exit code.
echo "[$(date '+%F %T')] Starting synchronous server-side copy (data flows source -> dest directly)..."
set +e
azcopy copy "$SOURCE_URI" "$DEST_URL" \
  --s2s-preserve-access-tier=false \
  --check-length=true \
  --overwrite=true \
  --log-level=WARNING \
  ${AZCOPY_EXTRA_FLAGS[@]+"${AZCOPY_EXTRA_FLAGS[@]}"}
AZCOPY_RC=$?
set -e

if [ "$AZCOPY_RC" -ne 0 ]; then
  echo "[$(date '+%F %T')] AzCopy exited with code ${AZCOPY_RC}." >&2
  echo "  Logs: ${AZCOPY_LOG_LOCATION}" >&2
  echo "  To resume an interrupted job:  azcopy jobs list   then   azcopy jobs resume <job-id>" >&2
  exit 2
fi

# --- 5. Verify the blob exists and show name + size ---------------------------
echo "[$(date '+%F %T')] Copy succeeded. Verifying blob in destination account..."
az storage blob show \
  --account-name "$DEST_SA" \
  --container-name "$DEST_CONTAINER" \
  --name "$DEST_BLOB" \
  --auth-mode login \
  --query "{name:name, container:container, blobType:properties.blobType, sizeBytes:properties.contentLength}" \
  --output table

# --- 6. Report total elapsed time ---------------------------------------------
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
printf '[%s] Done. Total time: %02d:%02d:%02d (%d seconds)\n' \
  "$(date '+%F %T')" $((ELAPSED/3600)) $((ELAPSED%3600/60)) $((ELAPSED%60)) "$ELAPSED"
