import { useState } from "react";
import { Alert, Box, Button, LinearProgress, Stack, Typography } from "@mui/material";
import { invoke } from "@tauri-apps/api/core";
import { ask } from "@tauri-apps/plugin-dialog";
import { openUrl } from "@tauri-apps/plugin-opener";
import { useTranslation } from "react-i18next";

type UpdateInfo = { version: string | null; notes: string | null; managed: boolean };

export default function Updates() {
  const { t } = useTranslation();
  const [update, setUpdate] = useState<UpdateInfo | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const check = async () => {
    setBusy(true); setError(""); setUpdate(null);
    try { setUpdate(await invoke<UpdateInfo>("check_app_update")); }
    catch (e) { setError(String(e)); }
    finally { setBusy(false); }
  };
  const install = async () => {
    if (!await ask(t("updates.confirm", "Save your work and close documents in Cloudreve before updating. Cloudreve will restart. Install the update now?"), { title: "Cloudreve", kind: "warning" })) return;
    setBusy(true); setError("");
    try { await invoke("install_app_update"); }
    catch (e) { setError(String(e)); }
    finally { setBusy(false); }
  };
  return <Box sx={{ my: 3 }}>
    <Stack spacing={1.5}>
      <Typography variant="subtitle1">{t("updates.title", "Software updates")}</Typography>
      <Button variant="outlined" onClick={check} disabled={busy} sx={{ alignSelf: "flex-start" }}>
        {busy ? t("updates.working", "Working…") : t("updates.check", "Check for updates")}
      </Button>
      {busy && <LinearProgress />}
      {error && <Alert severity="error">{t("updates.error", "Could not complete the update. Your current installation has not been confirmed updated.")} {error}</Alert>}
      {update?.managed && <>
        <Typography variant="body2">{t("updates.managed", "Use your Windows package installer or Microsoft Store to update. This preserves Explorer integration.")}</Typography>
        <Button onClick={() => openUrl("https://github.com/daddyboiAnderson/cloudreve-desktop/releases")} sx={{ alignSelf: "flex-start" }}>{t("updates.releases", "View releases")}</Button>
      </>}
      {update && !update.managed && !update.version && <Typography variant="body2">{t("updates.current", "You’re up to date.")}</Typography>}
      {update?.version && <>
        <Typography>{t("updates.available", "Version {{version}} is available", { version: update.version })}</Typography>
        {update.notes && <Typography variant="body2" sx={{ whiteSpace: "pre-wrap", maxHeight: 240, overflow: "auto" }}>{update.notes}</Typography>}
        <Button variant="contained" disabled={busy} onClick={install} sx={{ alignSelf: "flex-start" }}>{t("updates.install", "Install and restart")}</Button>
      </>}
    </Stack>
  </Box>;
}
