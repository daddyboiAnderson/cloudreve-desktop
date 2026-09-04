export interface DriveConfig {
  id: string;
  name: string;
  instance_url: string;
  sync_path: string;
  icon_path?: string;
}

export interface TaskProgress {
  task_id: string;
  kind: "Upload" | "Download";
  local_path: string;
  progress: number;
  processed_bytes?: number;
  total_bytes?: number;
  speed_bytes_per_sec: number;
  eta_seconds?: number;
}

export interface TaskRecord {
  id: string;
  drive_id: string;
  task_type: string;
  local_path: string;
  status: "Pending" | "Running" | "Completed" | "Failed" | "Cancelled";
  progress: number;
  total_bytes: number;
  processed_bytes: number;
  custom_state?: {
    file_provider_item_identifier?: string;
    remote_uri?: string;
  };
  error?: string;
  created_at: number;
  updated_at: number;
}

export interface TaskWithProgress extends TaskRecord {
  live_progress?: TaskProgress;
}

export interface PendingConflict {
  id: number;
  drive_id: string;
  local_path: string;
  is_folder: boolean;
  updated_at: number;
  size: number;
}

export interface StatusSummary {
  drives: DriveConfig[];
  active_tasks: TaskWithProgress[];
  finished_tasks: TaskRecord[];
  pending_conflicts: PendingConflict[];
}

export interface FileProviderIssue {
  id: string;
  drive_id: string;
  drive_name: string;
  item_identifier: string;
  filename: string;
  is_folder: boolean;
  operation: "upload" | "download";
  source: "pending" | "upload_conflict";
  kind?: "locked" | "stale" | "unverified";
  application?: string;
  message: string;
  error_domain?: string;
  error_code?: number;
  conflict_id?: string;
  updated_at: number;
}

export interface FileIconResponse {
  data: string; // Base64 encoded RGBA pixel data
  width: number;
  height: number;
}
