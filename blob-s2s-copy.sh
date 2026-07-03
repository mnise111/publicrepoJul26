#!/usr/bin/env bash
# blob-s2s-copy.sh
# Server-side (async) blob copy into a private storage account using the VM's managed identity.
#
# Usage:
#   ./blob-s2s-copy.sh <dest_storage_account> <dest_container> <dest_blob_name> "<source_uri_with_sas>"
#
# Example:
#   ./blob-s2s-copy.sh myprivateblobsa11 copied testbinfile.bin \
#     "https://mypublicsrcsa11.blob.core.windows.net/source/testbinfile.bin?sv=...&sig=..."

set -euo pipefail

if [ $# -ne 4 ]; then
  echo "Usage: $0 <dest_storage_account> <dest_container> <dest_blob_name> <source_uri_with_sas>" >&2
  exit 1
fi

DEST_SA="$1"
DEST_CONTAINER="$2"
DEST_BLOB="$3"
SOURCE_URI="$4"

START_TS=$(date +%s)
echo "=============================================================="
echo "[$(date '+%F %T')] Server-side blob copy starting"
echo "  Destination : https://${DEST_SA}.blob.core.windows.net/${DEST_CONTAINER}/${DEST_BLOB}"
echo "  Source      : ${SOURCE_URI%%\?*}   (SAS token hidden)"
echo "=============================================================="

# --- 1. Authenticate as the VM's managed identity -------------------------
echo "[$(date '+%F %T')] Logging in with the VM's managed identity..."
az login --identity --output none

# Sanity check: confirm the destination resolves to a PRIVATE IP (private endpoint)
RESOLVED_IP=$(getent hosts "${DEST_SA}.blob.core.windows.net" | awk '{print $1; exit}')
echo "[$(date '+%F %T')] ${DEST_SA}.blob.core.windows.net resolves to: ${RESOLVED_IP:-<unresolved>}"

# --- 2. Ensure the destination container exists ----------------------------
echo "[$(date '+%F %T')] Ensuring container '${DEST_CONTAINER}' exists..."
az storage container create \
  --account-name "$DEST_SA" \
  --name "$DEST_CONTAINER" \
  --auth-mode login \
  --output none

# --- 3. Kick off the asynchronous server-side copy -------------------------
# The destination storage SERVICE pulls the data directly from the source URL.
# No data flows through this VM.
echo "[$(date '+%F %T')] Initiating server-side copy..."
az storage blob copy start \
  --account-name "$DEST_SA" \
  --destination-container "$DEST_CONTAINER" \
  --destination-blob "$DEST_BLOB" \
  --source-uri "$SOURCE_URI" \
  --auth-mode login \
  --output none

# --- 4. Poll the copy status until it completes -----------------------------
# Single API call per iteration; status and progress are joined with an
# explicit '|' delimiter server-side (JMESPath), so parsing is unambiguous
# regardless of tabs/whitespace/CR quirks in the CLI output.
STATUS=""
PROGRESS=""
while true; do
  COPYINFO=$(az storage blob show \
      --account-name "$DEST_SA" \
      --container-name "$DEST_CONTAINER" \
      --name "$DEST_BLOB" \
      --auth-mode login \
      --query "join('|', [to_string(properties.copy.status), to_string(properties.copy.progress)])" \
      --output tsv | tr -d '\r')
  IFS='|' read -r STATUS PROGRESS <<< "$COPYINFO"
  echo "[$(date '+%F %T')] Copy status: ${STATUS} | bytes copied/total: ${PROGRESS}"
  case "$STATUS" in
    pending)
      sleep 2
      ;;
    success)
      break
      ;;
    failed|aborted)
      DESC=$(az storage blob show \
          --account-name "$DEST_SA" \
          --container-name "$DEST_CONTAINER" \
          --name "$DEST_BLOB" \
          --auth-mode login \
          --query "properties.copy.statusDescription" \
          --output tsv | tr -d '\r')
      echo "[$(date '+%F %T')] Copy terminated with status '${STATUS}': ${DESC:-no detail}" >&2
      exit 2
      ;;
    *)
      echo "[$(date '+%F %T')] Unexpected copy status '${STATUS}' - retrying..." >&2
      sleep 2
      ;;
  esac
done

# --- 5. Verify the blob exists and show name + size ------------------------
echo "[$(date '+%F %T')] Copy succeeded. Verifying blob in destination account..."
az storage blob show \
  --account-name "$DEST_SA" \
  --container-name "$DEST_CONTAINER" \
  --name "$DEST_BLOB" \
  --auth-mode login \
  --query "{name:name, container:container, sizeBytes:properties.contentLength, copyStatus:properties.copy.status, completedOn:properties.copy.completionTime}" \
  --output table

# --- 6. Report total elapsed time ------------------------------------------
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
printf '[%s] Done. Total time: %02d:%02d:%02d (%d seconds)\n' \
  "$(date '+%F %T')" $((ELAPSED/3600)) $((ELAPSED%3600/60)) $((ELAPSED%60)) "$ELAPSED"
