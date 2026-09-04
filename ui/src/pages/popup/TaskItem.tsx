import {
  Box,
  LinearProgress,
  Link,
  ListItem,
  ListItemIcon,
  ListItemText,
  Typography,
} from "@mui/material";
import {
  CheckCircle as CheckCircleIcon,
  Error as ErrorIcon,
  CloudUpload as UploadIcon,
  CloudDownload as DownloadIcon,
  AddCircleOutline as AddIcon,
  Sync as SyncIcon,
  DriveFileRenameOutline as RenameIcon,
  DeleteOutline as DeleteIcon,
  ExpandMore as ExpandMoreIcon,
} from "@mui/icons-material";
import { invoke } from "@tauri-apps/api/core";
import TimeAgo from "react-timeago";
import { useTranslation } from "react-i18next";
import type { TaskWithProgress, TaskRecord } from "./types";
import { formatBytes, getFileName, getParentFolderName } from "./utils";
import FileIcon from "./FileIcon";

interface TaskItemProps {
  task: TaskWithProgress | TaskRecord;
  isActive?: boolean;
  historyCount?: number;
  historyExpanded?: boolean;
  isHistoryEntry?: boolean;
  onToggleHistory?: () => void;
}

export default function TaskItem({
  task,
  isActive = false,
  historyCount = 1,
  historyExpanded = false,
  isHistoryEntry = false,
  onToggleHistory,
}: TaskItemProps) {
  const { t } = useTranslation();
  const activeTask = task as TaskWithProgress;
  const liveProgress = activeTask.live_progress;
  const progress = liveProgress?.progress ?? task.progress;
  const isUpload = task.task_type === "upload";
  const isLegacyMacSync =
    task.task_type === "download" &&
    task.id.startsWith("fp-") &&
    !task.id.startsWith("fp-transfer-") &&
    task.total_bytes === 0 &&
    task.processed_bytes === 0;
  const isDownload = task.task_type === "download" && !isLegacyMacSync;
  const fileName = getFileName(task.local_path);
  const parentFolderName = getParentFolderName(task.local_path);
  const isFailed = task.status === "Failed";

  const activityLabel = (() => {
    if (isActive) {
      if (task.status === "Pending") {
        return isUpload
          ? t("popup.uploadWaiting", "Upload waiting")
          : t("popup.downloadWaiting", "Download waiting");
      }
      return isUpload
        ? t("popup.uploading", "Uploading")
        : t("popup.downloading", "Downloading");
    }
    if (task.status === "Completed") {
      switch (task.task_type) {
        case "upload":
          return t("popup.uploaded", "Uploaded");
        case "download":
          return isLegacyMacSync
            ? t("popup.synced", "Synced")
            : t("popup.downloaded", "Downloaded");
        case "sync_create":
          return t("popup.itemAdded", "Added");
        case "sync_modify":
          return t("popup.itemUpdated", "Updated");
        case "sync_rename":
          return t("popup.itemRenamed", "Renamed");
        case "sync_delete":
          return t("popup.itemDeleted", "Deleted");
        default:
          return t("popup.synced", "Synced");
      }
    }
    if (task.status === "Cancelled") {
      return isUpload
        ? t("popup.uploadCancelled", "Upload cancelled")
        : t("popup.downloadCancelled", "Download cancelled");
    }
    if (isUpload) return t("popup.uploadFailed", "Upload failed");
    if (isDownload) return t("popup.downloadFailed", "Download failed");
    return t("popup.syncFailed", "Sync failed");
  })();

  const timeAgoFormatter = (
    value: number,
    unit: string,
    suffix: string
  ): string => {
    if (unit === "second") {
      return t("timeAgo.justNow", "Just now");
    }
    const unitKey = value === 1 ? unit : `${unit}s`;
    return t(`timeAgo.${unitKey}${suffix === "ago" ? "Ago" : "FromNow"}`, `${value} ${unitKey} ${suffix}`, { value });
  };

  const handleShowInExplorer = (e: React.MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    invoke("show_file_in_explorer", { path: task.local_path });
  };

  const getStatusBadge = () => {
    if (isActive) {
      return isUpload ? (
        <UploadIcon sx={{ fontSize: 14 }} color="primary" />
      ) : (
        <DownloadIcon sx={{ fontSize: 14 }} color="primary" />
      );
    }
    switch (task.status) {
      case "Completed":
        return <CheckCircleIcon sx={{ fontSize: 14 }} color="success" />;
      case "Failed":
      case "Cancelled":
        return <ErrorIcon sx={{ fontSize: 14 }} color="error" />;
      default:
        return null;
    }
  };

  const getProgressText = () => {
    if (isActive && liveProgress) {
      const processed = formatBytes(liveProgress.processed_bytes ?? 0);
      const total = formatBytes(liveProgress.total_bytes ?? 0);
      const speed = formatBytes(liveProgress.speed_bytes_per_sec);
      return `${processed} / ${total} - ${speed}/s`;
    }
    return null;
  };

  const statusBadge = getStatusBadge();
  const progressText = getProgressText();
  const canExpand = historyCount > 1 && Boolean(onToggleHistory);

  const historyIcon = (() => {
    switch (task.task_type) {
      case "upload":
        return <UploadIcon fontSize="small" />;
      case "download":
        return isLegacyMacSync ? (
          <SyncIcon fontSize="small" />
        ) : (
          <DownloadIcon fontSize="small" />
        );
      case "sync_create":
        return <AddIcon fontSize="small" />;
      case "sync_modify":
        return <SyncIcon fontSize="small" />;
      case "sync_rename":
        return <RenameIcon fontSize="small" />;
      case "sync_delete":
        return <DeleteIcon fontSize="small" />;
      default:
        return <SyncIcon fontSize="small" />;
    }
  })();

  const toggleOnKeyboard = (event: React.KeyboardEvent) => {
    if (!canExpand || (event.key !== "Enter" && event.key !== " ")) return;
    event.preventDefault();
    onToggleHistory?.();
  };

  return (
    <ListItem
      role={canExpand ? "button" : undefined}
      tabIndex={canExpand ? 0 : undefined}
      onClick={canExpand ? onToggleHistory : undefined}
      onKeyDown={toggleOnKeyboard}
      sx={{
        pl: isHistoryEntry ? 7 : 2,
        pr: 2,
        py: isHistoryEntry ? 0.75 : 1,
        cursor: canExpand ? "pointer" : "default",
        "&:hover": {
          bgcolor: "action.hover",
        },
      }}
    >
      <ListItemIcon sx={{ minWidth: isHistoryEntry ? 30 : 40 }}>
        <Box sx={{ position: "relative", width: 28, height: 28 }}>
          {isHistoryEntry ? (
            <Box
              sx={{
                width: 28,
                height: 28,
                display: "grid",
                placeItems: "center",
                color:
                  task.status === "Completed"
                    ? "success.main"
                    : task.status === "Failed" || task.status === "Cancelled"
                      ? "error.main"
                      : "primary.main",
              }}
            >
              {historyIcon}
            </Box>
          ) : (
            <FileIcon path={task.local_path} size={28} />
          )}
          {statusBadge && !isHistoryEntry && (
            <Box
              sx={{
                position: "absolute",
                bottom: -4,
                right: -4,
                bgcolor: "background.paper",
                borderRadius: "50%",
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                width: 18,
                height: 18,
              }}
            >
              {statusBadge}
            </Box>
          )}
        </Box>
      </ListItemIcon>
      <ListItemText
        primary={
          <Typography variant="body2" noWrap sx={{ fontWeight: 500 }}>
            {isHistoryEntry ? activityLabel : fileName}
          </Typography>
        }
        secondary={
          <Box>
            {isFailed && task.error ? (
              <Typography variant="caption" color="error" component="span">
                {activityLabel}: {task.error}
              </Typography>
            ) : (
              <Typography variant="caption" color="text.secondary" component="span">
                {!isHistoryEntry && <>{activityLabel}{" · "}</>}
                {progressText ?? (
                  <TimeAgo date={task.updated_at * 1000} formatter={timeAgoFormatter} />
                )}
              </Typography>
            )}
            {!isActive && !isHistoryEntry && (
              <>
                <Typography variant="caption" color="text.secondary" component="span">
                  {" · "}
                </Typography>
                <Link
                  component="button"
                  variant="caption"
                  color="text.secondary"
                  onClick={handleShowInExplorer}
                  underline="always"
                  sx={{
                  }}
                >
                  {parentFolderName}
                </Link>
              </>
            )}
            {isActive && (
              <LinearProgress
                variant="determinate"
                value={progress * 100}
                sx={{ mt: 0.5, height: 4, borderRadius: 2 }}
              />
            )}
          </Box>
        }
      />
      {canExpand && (
        <Box
          sx={{
            ml: 1,
            display: "flex",
            alignItems: "center",
            gap: 0.25,
            color: "text.secondary",
            flexShrink: 0,
          }}
        >
          <Typography variant="caption">
            {t("popup.activityCount", "{{count}} actions", { count: historyCount })}
          </Typography>
          <ExpandMoreIcon
            sx={{
              fontSize: 20,
              transform: historyExpanded ? "rotate(180deg)" : "none",
              transition: "transform 150ms ease",
            }}
          />
        </Box>
      )}
    </ListItem>
  );
}
