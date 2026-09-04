import { Box, Collapse } from "@mui/material";
import { useState } from "react";
import TaskItem from "./TaskItem";
import type { TaskRecord } from "./types";

export default function TaskHistoryGroup({ tasks }: { tasks: TaskRecord[] }) {
  const [expanded, setExpanded] = useState(false);
  const latest = tasks[0];
  const echoedUpload =
    latest.task_type === "sync_create" || latest.task_type === "sync_modify"
      ? tasks.find(
          (task) => task.task_type === "upload" && latest.updated_at - task.updated_at <= 30
        )
      : undefined;
  const summary = echoedUpload ?? latest;
  const history = tasks.filter((task) => task.id !== summary.id);

  return (
    <>
      <TaskItem
        task={summary}
        historyCount={tasks.length}
        historyExpanded={expanded}
        onToggleHistory={tasks.length > 1 ? () => setExpanded((value) => !value) : undefined}
      />
      {tasks.length > 1 && (
        <Collapse in={expanded} timeout="auto" unmountOnExit>
          <Box sx={{ borderLeft: 1, borderColor: "divider", ml: 3.25 }}>
            {history.map((task) => (
              <TaskItem key={task.id} task={task} isHistoryEntry />
            ))}
          </Box>
        </Collapse>
      )}
    </>
  );
}
