import type { TaskRecord } from "./types";

const HISTORY_WINDOW_SECONDS = 2 * 60;

export function groupRecentTasks(tasks: TaskRecord[]): TaskRecord[][] {
  const groups: TaskRecord[][] = [];

  for (const task of tasks) {
    const current = groups[groups.length - 1];
    const newest = current?.[0];
    const belongsToCurrent =
      newest &&
      newest.drive_id === task.drive_id &&
      newest.local_path === task.local_path &&
      task.updated_at <= newest.updated_at &&
      newest.updated_at - task.updated_at <= HISTORY_WINDOW_SECONDS;

    if (belongsToCurrent) {
      current.push(task);
    } else {
      groups.push([task]);
    }
  }

  return groups;
}
