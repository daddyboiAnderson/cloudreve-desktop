import { Alert, Box, Button, CircularProgress, IconButton, InputAdornment, List, ListItem, Menu, MenuItem, TextField, Tooltip, Typography } from "@mui/material";
import { ContentCopy, FolderOutlined, FolderOpenOutlined, MoreHoriz, OfflinePinOutlined, PeopleOutline, Refresh, Search } from "@mui/icons-material";
import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useTranslation } from "react-i18next";
import type { DriveConfig } from "./types";
import FileIcon from "./FileIcon";

function displayPath(uri: string): string {
  try { return decodeURIComponent(uri); }
  catch { return uri; }
}

interface SavedItem {
  uri: string;
  name: string;
  is_folder: boolean;
  share_url: string | null;
  share_id: string | null;
  share_count: number;
  expired: boolean;
  drive: DriveConfig;
}

export default function SavedItems({ kind, drives, selectedDrive }: {
  kind: "pinned" | "shared"; drives: DriveConfig[]; selectedDrive: string | null;
}) {
  const { t } = useTranslation();
  const [items, setItems] = useState<SavedItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [query, setQuery] = useState("");
  const [busy, setBusy] = useState(false);
  const [menu, setMenu] = useState<{ anchor: HTMLElement; item: SavedItem } | null>(null);
  const generation = useRef(0);
  const driveRef = useRef(drives);
  driveRef.current = drives;
  const driveKey = drives.map(d => d.id).join(",");

  const refresh = useCallback(async () => {
    const run = ++generation.current;
    setLoading(true);
    setError("");
    const ids = new Set(driveKey.split(","));
    const targets = driveRef.current.filter(d => ids.has(d.id) && (!selectedDrive || d.id === selectedDrive));
    const results = await Promise.allSettled(targets.map(async drive => {
      const rows = await invoke<Omit<SavedItem, "drive">[]>("list_saved_items", { driveId: drive.id, kind });
      return rows.map(item => ({ ...item, drive }));
    }));
    if (run !== generation.current) return;
    const failures: string[] = [];
    const seen = new Set<string>();
    const next: SavedItem[] = [];
    results.forEach((result, index) => {
      if (result.status === "rejected") { failures.push(`${targets[index].name}: ${String(result.reason)}`); return; }
      result.value.forEach(item => {
        const key = kind === "shared"
          ? `${item.drive.instance_url}:${item.share_id}` : `${item.drive.id}:${item.uri}`;
        if (!seen.has(key)) { seen.add(key); next.push(item); }
      });
    });
    setItems(next.sort((a, b) => a.name.localeCompare(b.name)));
    setError(failures.join("\n"));
    setLoading(false);
  }, [kind, selectedDrive, driveKey]);

  useEffect(() => {
    const requests = generation;
    setItems([]);
    setQuery("");
    setNotice("");
    void refresh();
    const onFocus = () => { void refresh(); };
    window.addEventListener("focus", onFocus);
    return () => { requests.current++; window.removeEventListener("focus", onFocus); };
  }, [refresh]);

  useEffect(() => {
    if (!notice) return;
    const timer = window.setTimeout(() => setNotice(""), 3000);
    return () => window.clearTimeout(timer);
  }, [notice]);

  const action = async (item: SavedItem, command: "reveal" | "copy" | "share" | "unpin") => {
    setMenu(null);
    setBusy(true);
    setError("");
    setNotice("");
    try {
      if (command === "copy" && item.share_url) {
        await navigator.clipboard.writeText(item.share_url);
        setNotice(t("popup.linkCopied", "Link copied"));
      } else {
        await invoke(command === "reveal" ? "reveal_saved_item" : command === "share" ? "show_share_window" : "remove_saved_pin", {
          driveId: item.drive.id, uri: item.uri,
        });
        if (command === "unpin") {
          setNotice(t("popup.pinRemoved", "Keep Downloaded removed from “{{name}}”. Existing downloads stay on this Mac.", { name: item.name }));
          await refresh();
        }
      }
    } catch (e) { setError(String(e)); }
    finally { setBusy(false); }
  };

  const filtered = items.filter(item => `${item.name} ${displayPath(item.uri)} ${item.drive.name}`.toLowerCase().includes(query.toLowerCase()));
  const EmptyIcon = kind === "pinned" ? OfflinePinOutlined : PeopleOutline;
  return <Box sx={{ p: 2 }}>
    <Box sx={{ display: "flex", alignItems: "center", gap: 1, mb: 1.5 }}>
      <TextField size="small" fullWidth value={query} onChange={e => setQuery(e.target.value)}
        placeholder={t("popup.searchItems", "Search files and folders")}
        slotProps={{ input: { startAdornment: <InputAdornment position="start"><Search sx={{ fontSize: 18 }} /></InputAdornment> }, htmlInput: { "aria-label": t("popup.searchItems", "Search files and folders") } }}
        sx={{ "& .MuiOutlinedInput-root": { borderRadius: 2, fontSize: 13 } }} />
      <Tooltip title={t("popup.refresh", "Refresh")}><span><IconButton aria-label="Refresh items" disabled={loading || busy} onClick={() => void refresh()} size="small"><Refresh fontSize="small" /></IconButton></span></Tooltip>
    </Box>
    <Typography variant="caption" color="text.secondary" sx={{ display: "block", mb: 1.5 }}>
      {kind === "pinned" ? t("popup.pinnedHint", "Your selections for offline access. Folders include their contents.") : t("popup.sharedHint", "Links you created. Manage access in Share Options.")}
    </Typography>
    {error && <Alert severity="warning" sx={{ mb: 1.5, whiteSpace: "pre-line", fontSize: 12 }}>{error}</Alert>}
    {notice && <Alert severity="success" onClose={() => setNotice("")} sx={{ mb: 1.5, fontSize: 12 }}>{notice}</Alert>}
    {loading && !items.length ? <Box sx={{ textAlign: "center", py: 5 }}><CircularProgress size={24} aria-label="Loading items" /></Box> : error && !items.length ?
      <Button fullWidth onClick={() => void refresh()} sx={{ mt: 1 }}>{t("popup.tryAgain", "Try again")}</Button> : !filtered.length ?
      <Box sx={{ textAlign: "center", py: 5, color: "text.secondary" }}>
        <EmptyIcon sx={{ fontSize: 36, mb: 1, opacity: 0.5 }} />
        <Typography variant="body2">{query ? t("popup.noMatches", "No matching items") : kind === "pinned" ? t("popup.noPins", "Nothing kept downloaded yet") : t("popup.noShares", "No share links in this drive")}</Typography>
        {!query && kind === "pinned" && <Typography variant="caption" sx={{ display: "block", mt: 0.5 }}>{t("popup.pinHelp", "Choose Keep Downloaded from an item’s Finder menu.")}</Typography>}
      </Box> : <>
        <Typography variant="caption" color="text.secondary">{t("popup.itemCount", "{{count}} items", { count: filtered.length })}{loading ? " · Refreshing…" : ""}</Typography>
        <List disablePadding sx={{ mt: 0.5 }}>
          {filtered.map(item => <ListItem key={`${item.drive.id}:${item.share_id || item.uri}`} disableGutters sx={{ gap: 1.25, py: 1.5, borderBottom: 1, borderColor: "divider", alignItems: "center" }}>
            <Box sx={{ width: 32, flexShrink: 0, display: "flex", justifyContent: "center" }}>{item.is_folder ? <FolderOutlined sx={{ color: "primary.main", fontSize: 28 }} /> : <FileIcon path={item.name} size={28} />}</Box>
            <Box sx={{ minWidth: 0, flex: 1 }}>
              <Typography title={item.name} variant="body2" noWrap sx={{ fontWeight: 600 }}>{item.name}</Typography>
              <Typography title={displayPath(item.uri)} variant="caption" color="text.secondary" noWrap component="div">{item.drive.name} · {displayPath(item.uri.split("/").slice(3, -1).join("/")) || "/"}</Typography>
              {item.expired && <Typography variant="caption" color="warning.main">{t("popup.expiredLink", "Expired link")}</Typography>}
              {item.share_count > 1 && <Typography variant="caption" color="text.secondary">{t("popup.linkCount", "{{count}} share links", { count: item.share_count })}</Typography>}
            </Box>
            <Tooltip title={t("popup.showInFinder", "Show in Finder")}><span><IconButton size="small" aria-label={`Show ${item.name} in Finder`} disabled={busy} onClick={() => void action(item, "reveal")}><FolderOpenOutlined fontSize="small" /></IconButton></span></Tooltip>
            <IconButton size="small" aria-label={`Actions for ${item.name}`} disabled={busy} onClick={e => setMenu({ anchor: e.currentTarget, item })}><MoreHoriz fontSize="small" /></IconButton>
          </ListItem>)}
        </List>
      </>}
    <Menu anchorEl={menu?.anchor} open={!!menu} onClose={() => setMenu(null)}>
      {menu?.item.share_url && menu.item.share_count === 1 && <MenuItem onClick={() => void action(menu.item, "copy")}><ContentCopy sx={{ mr: 1, fontSize: 18 }} />{t("popup.copyLink", "Copy link")}</MenuItem>}
      {menu && <MenuItem onClick={() => void action(menu.item, "share")}>{t("popup.shareOptions", "Share Options")}</MenuItem>}
      {menu && kind === "pinned" && <MenuItem onClick={() => void action(menu.item, "unpin")}>{t("popup.removePin", "Remove Keep Downloaded")}</MenuItem>}
    </Menu>
    {busy && <Button disabled fullWidth size="small" startIcon={<CircularProgress size={12} />} sx={{ mt: 1 }}>Updating…</Button>}
  </Box>;
}
