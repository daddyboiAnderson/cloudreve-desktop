import { Box, Collapse } from "@mui/material";
import { useState } from "react";
import TaskItem from "./TaskItem";
import type { TaskRecord } from "./types";

export default function TaskHistoryGroup({ tasks }: { tasks: TaskRecord[] }) {
  const [expanded, setExpanded] = useState(false);
  const latest = tasks[0];

  return (
    <>
      <TaskItem
        task={latest}
        historyCount={tasks.length}
        historyExpanded={expanded}
        onToggleHistory={tasks.length > 1 ? () => setExpanded((value) => !value) : undefined}
      />
      {tasks.length > 1 && (
        <Collapse in={expanded} timeout="auto" unmountOnExit>
          <Box sx={{ borderLeft: 1, borderColor: "divider", ml: 3.25 }}>
            {tasks.slice(1).map((task) => (
              <TaskItem key={task.id} task={task} isHistoryEntry />
            ))}
          </Box>
        </Collapse>
      )}
    </>
  );
}
