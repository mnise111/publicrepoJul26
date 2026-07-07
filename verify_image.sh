curl -sI "$CISCO_SAS_URL" | grep -i content-md5
# returns base64 — convert to the usual hex form:
echo "<base64value>" | base64 -d | xxd -p



az storage blob show \
  --account-name mycompanystvhd --container-name cisco-vhds \
  --name esa-c600v-16-0-0.vhd --auth-mode login \
  --query "{md5:properties.contentSettings.contentMd5, bytes:properties.contentLength}" -o table
