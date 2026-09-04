import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import {
  Alert,
  Box,
  Button,
  CircularProgress,
  Divider,
  Stack,
  Tooltip,
  Typography,
} from "@mui/material";
import {
  ContentCopyRounded,
  DeleteOutlineRounded,
  ErrorOutlineRounded,
  RefreshRounded,
} from "@mui/icons-material";
import type { Theme } from "@mui/material/styles";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useSearchParams } from "react-router-dom";

type ConflictAction = "save_copy" | "retry" | "discard";

interface UploadConflictRecord {
  id: string;
  drive_id: string;
  uri: string;
  filename: string;
  kind: "locked" | "stale" | "unverified";
  application?: string | null;
  owner_id?: string | null;
  owner_name?: string | null;
  previous_version?: string | null;
}

const darkCalloutColors = {
  info: { background: "#164b68", foreground: "#c8ebff", icon: "#82cfff" },
  warning: { background: "#6b4a12", foreground: "#ffe1a8", icon: "#ffb74d" },
  success: { background: "#2e7d32", foreground: "#b7f5b9", icon: "#7ee787" },
  error: { background: "#8c1d18", foreground: "#ffb4ab", icon: "#ff8a80" },
} as const;

type CalloutTone = keyof typeof darkCalloutColors;

function calloutSx(tone: CalloutTone) {
  const colors = darkCalloutColors[tone];
  return {
    py: 0,
    alignItems: "center",
    backgroundColor: (theme: Theme) =>
      theme.palette.mode === "dark" ? colors.background : undefined,
    color: (theme: Theme) =>
      theme.palette.mode === "dark" ? colors.foreground : undefined,
    "& .MuiAlert-icon": {
      alignSelf: "center",
      py: 0,
      opacity: 1,
      color: (theme: Theme) =>
        theme.palette.mode === "dark" ? colors.icon : undefined,
    },
    "& .MuiAlert-message": { py: 0.5 },
  };
}

function filenameParts(filename: string) {
  const extensionStart = filename.lastIndexOf(".");
  const hasVisibleExtension =
    extensionStart > 0 && filename.length - extensionStart <= 16;

  return hasVisibleExtension
    ? {
        basename: filename.slice(0, extensionStart),
        extension: filename.slice(extensionStart),
      }
    : { basename: filename, extension: "" };
}

function ConflictFilename({ filename }: { filename: string }) {
  const displayedFilename = filenameParts(filename);
  const basenameRef = useRef<HTMLSpanElement>(null);
  const [isTruncated, setIsTruncated] = useState(false);

  useLayoutEffect(() => {
    const basename = basenameRef.current;
    if (!basename) return;

    const update = () => setIsTruncated(basename.scrollWidth > basename.clientWidth);
    update();
    const observer = new ResizeObserver(update);
    observer.observe(basename);
    return () => observer.disconnect();
  }, [filename]);

  return (
    <Tooltip
      title={isTruncated ? filename : ""}
      placement="top"
      disableHoverListener={!isTruncated}
    >
      <Typography
        component="div"
        variant="subtitle1"
        fontWeight={700}
        sx={{ display: "flex", minWidth: 0 }}
      >
        <Box
          ref={basenameRef}
          component="span"
          sx={{ minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}
        >
          {displayedFilename.basename}
        </Box>
        <Box component="span" sx={{ flexShrink: 0 }}>
          {displayedFilename.extension}
        </Box>
      </Typography>
    </Tooltip>
  );
}

export default function UploadConflict() {
  const [searchParams] = useSearchParams();
  const [conflictId, setConflictId] = useState(searchParams.get("id") ?? "");
  const [conflict, setConflict] = useState<UploadConflictRecord | null>(null);
  const [loading, setLoading] = useState(true);
  const [resolving, setResolving] = useState<ConflictAction | null>(null);
  const [error, setError] = useState("");

  const loadConflict = useCallback(async (id: string) => {
    setLoading(true);
    setError("");
    try {
      setConflict(await invoke<UploadConflictRecord>("get_upload_conflict", { id }));
    } catch (loadError) {
      setConflict(null);
      setError(String(loadError));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (conflictId) void loadConflict(conflictId);
  }, [conflictId, loadConflict]);

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    void listen<string>("upload-conflict-target", (event) => {
      setConflictId(event.payload);
    }).then((cleanup) => {
      unlisten = cleanup;
    });
    return () => unlisten?.();
  }, []);

  const resolve = async (action: ConflictAction) => {
    if (!conflict || resolving) return;
    setResolving(action);
    setError("");
    try {
      await invoke("resolve_upload_conflict", { id: conflict.id, action });
      await getCurrentWindow().destroy();
    } catch (resolveError) {
      setError(String(resolveError));
      setResolving(null);
    }
  };

  const description = conflict
    ? conflict.kind === "locked"
      ? `${conflict.owner_name?.trim() || "Someone"} has this file open online. Cloudreve paused your upload to protect the online version. If online editing is available for your account, you can continue working on the online file in Cloudreve.`
      : conflict.kind === "stale"
        ? "The file changed online while you were editing it. Cloudreve paused your upload so the newer online version is not overwritten."
        : "Cloudreve could not verify which online version you edited, so it paused the upload to prevent an overwrite."
    : "";
  const canRetry = conflict?.kind === "locked" && Boolean(conflict.previous_version);
  const retryExplanation =
    conflict?.kind === "stale"
      ? "Try Again is unavailable because the online version changed after you started editing."
      : conflict?.kind === "unverified"
        ? "Try Again is unavailable because Cloudreve cannot verify the version you edited."
        : "Try Again safely uploads your changes only when the online editor has released the file and its version is unchanged.";
  return (
    <Box
      sx={{
        height: "100%",
        display: "flex",
        flexDirection: "column",
        bgcolor: "background.paper",
        borderRadius: "14px",
        overflow: "hidden",
      }}
    >
      <Box
        data-tauri-drag-region
        sx={{
          height: 46,
          flexShrink: 0,
          display: "flex",
          alignItems: "center",
          pl: "91px",
          pr: 2,
          borderBottom: 1,
          borderColor: "divider",
        }}
      >
        <Typography variant="subtitle1" fontWeight={700} noWrap>
          Upload Conflict
        </Typography>
      </Box>

      <Box sx={{ flex: 1, minHeight: 0, overflowY: "auto", p: 2.5 }}>
        {loading ? (
          <Stack height="100%" alignItems="center" justifyContent="center">
            <CircularProgress size={28} />
          </Stack>
        ) : conflict ? (
          <Stack spacing={2}>
            <Stack direction="row" spacing={1.5} alignItems="center">
              <Box
                sx={{
                  width: 42,
                  height: 42,
                  borderRadius: "50%",
                  display: "grid",
                  placeItems: "center",
                  bgcolor: "error.main",
                  color: "error.contrastText",
                  flexShrink: 0,
                }}
              >
                <ErrorOutlineRounded />
              </Box>
              <Box sx={{ minWidth: 0, flex: 1 }}>
                <ConflictFilename filename={conflict.filename} />
                <Typography variant="body2" color="text.secondary" sx={{ lineHeight: 1.35 }}>
                  Your local changes are still on this Mac and have not been uploaded
                </Typography>
              </Box>
            </Stack>

            <Typography variant="body2">{description}</Typography>
            <Stack spacing={0.75}>
              <Alert
                severity={canRetry ? "info" : "warning"}
                icon={<RefreshRounded fontSize="inherit" />}
                sx={calloutSx(canRetry ? "info" : "warning")}
              >
                <Typography variant="body2">{retryExplanation}</Typography>
              </Alert>
              <Alert
                severity="success"
                icon={<ContentCopyRounded fontSize="inherit" />}
                sx={calloutSx("success")}
              >
                <Typography variant="body2">
                  Save as Copy uploads your edits separately and keeps both versions.
                </Typography>
              </Alert>
              <Alert
                severity="error"
                icon={<DeleteOutlineRounded fontSize="inherit" />}
                sx={calloutSx("error")}
              >
                <Typography variant="body2">
                  Discard Changes removes your local edits and restores the online version.
                </Typography>
              </Alert>
            </Stack>
            {error && <Alert severity="error">{error}</Alert>}
          </Stack>
        ) : (
          <Alert severity="error">{error || "This upload conflict is no longer available."}</Alert>
        )}
      </Box>

      <Divider />
      <Stack
        direction="row"
        justifyContent="space-between"
        alignItems="center"
        sx={{ px: 2.5, py: 2, flexShrink: 0 }}
      >
        <Button
          color="error"
          startIcon={<DeleteOutlineRounded />}
          disabled={!conflict || Boolean(resolving)}
          onClick={() => void resolve("discard")}
          sx={{ whiteSpace: "nowrap", flexShrink: 0 }}
        >
          Discard Changes
        </Button>
        <Stack direction="row" spacing={1}>
          <Button
            variant="outlined"
            startIcon={<RefreshRounded />}
            disabled={!canRetry || Boolean(resolving)}
            title={!canRetry ? retryExplanation : undefined}
            onClick={() => void resolve("retry")}
            sx={{ whiteSpace: "nowrap", flexShrink: 0 }}
          >
            Try Again
          </Button>
          <Button
            variant="contained"
            startIcon={
              resolving === "save_copy" ? <CircularProgress size={16} /> : <ContentCopyRounded />
            }
            disabled={!conflict || Boolean(resolving)}
            onClick={() => void resolve("save_copy")}
            sx={{ whiteSpace: "nowrap", flexShrink: 0 }}
          >
            Save as Copy
          </Button>
        </Stack>
      </Stack>
    </Box>
  );
}
