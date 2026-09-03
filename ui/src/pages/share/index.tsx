import {
  Alert,
  Avatar,
  Box,
  Button,
  ButtonBase,
  Checkbox,
  CircularProgress,
  Divider,
  FormControl,
  FormControlLabel,
  IconButton,
  List,
  ListItem,
  ListItemAvatar,
  ListItemButton,
  ListItemText,
  MenuItem,
  Paper,
  Select,
  Stack,
  TextField,
  Typography,
} from "@mui/material";
import CloseIcon from "@mui/icons-material/Close";
import ContentCopyIcon from "@mui/icons-material/ContentCopy";
import DeleteOutlineIcon from "@mui/icons-material/DeleteOutline";
import EditOutlinedIcon from "@mui/icons-material/EditOutlined";
import ArrowBackIcon from "@mui/icons-material/ArrowBack";
import ExpandLessIcon from "@mui/icons-material/ExpandLess";
import ExpandMoreIcon from "@mui/icons-material/ExpandMore";
import GroupOutlinedIcon from "@mui/icons-material/GroupOutlined";
import IosShareOutlinedIcon from "@mui/icons-material/IosShareOutlined";
import LinkIcon from "@mui/icons-material/Link";
import PublicIcon from "@mui/icons-material/Public";
import SettingsIcon from "@mui/icons-material/Settings";
import LockOutlinedIcon from "@mui/icons-material/LockOutlined";
import DashboardOutlinedIcon from "@mui/icons-material/DashboardOutlined";
import DescriptionOutlinedIcon from "@mui/icons-material/DescriptionOutlined";
import TimerOutlinedIcon from "@mui/icons-material/TimerOutlined";
import { useCallback, useEffect, useRef, useState } from "react";
import type { ChangeEvent, ReactNode } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { type as platformType } from "@tauri-apps/plugin-os";
import { useSearchParams } from "react-router-dom";

type PermissionKey = "read" | "create" | "update" | "delete";
type PermissionState = Record<PermissionKey, boolean>;

interface PermissionSetting {
  same_group?: string;
  anonymous?: string;
  everyone?: string;
  other?: string;
  group_explicit?: Record<string, string>;
  user_explicit?: Record<string, string>;
}

interface ShareLink {
  id: string;
  url: string;
  expires?: string;
  is_private?: boolean;
  share_view?: boolean;
  permission_setting?: PermissionSetting;
  password_protected?: boolean;
  password?: string;
  show_readme?: boolean;
}

interface ShareTarget {
  drive_id: string;
  drive_name: string;
  instance_url?: string;
  uri: string;
  name: string;
  is_folder: boolean;
  shares: ShareLink[];
}

interface ShareWindowTarget {
  drive_id: string;
  uri: string;
}

interface ShareUser {
  id: string;
  nickname: string;
  email?: string;
  avatar?: string;
  group?: { id: string; name: string };
}

interface ShareGroup {
  id: string;
  name: string;
}

interface ShareGroupContext {
  groups: ShareGroup[];
  current_group_id?: string | null;
}

type GroupSelectionKind = "same_group" | "other" | "explicit";

interface SelectedGroup {
  id: string;
  name: string;
  kind: GroupSelectionKind;
  permissions: PermissionState;
}

interface SelectedPerson {
  user: ShareUser;
  permissions: PermissionState;
}

interface FooterNotice {
  message: string;
  severity: "success" | "error";
  action?: "undo";
}

interface PendingDeletion {
  share: ShareLink;
  driveId: string;
  uri: string;
  index: number;
}

const DEFAULT_PERMISSIONS: PermissionState = {
  read: true,
  create: false,
  update: false,
  delete: false,
};

const EMPTY_PERMISSIONS: PermissionState = {
  read: false,
  create: false,
  update: false,
  delete: false,
};

const PERMISSION_OPTIONS: {
  value: PermissionKey;
  label: string;
}[] = [
  { value: "read", label: "Read" },
  { value: "create", label: "Create" },
  { value: "update", label: "Update" },
  { value: "delete", label: "Delete" },
];

type ExpirationUnit = "minutes" | "hours" | "days";

const EXPIRATION_MULTIPLIERS: Record<ExpirationUnit, number> = {
  minutes: 60,
  hours: 3_600,
  days: 86_400,
};

function encodePermissions(permissions: PermissionState): string {
  let bits = 0;
  if (permissions.read) bits |= 1 << 0;
  if (permissions.update) bits |= 1 << 1;
  if (permissions.create) bits |= 1 << 2;
  if (permissions.delete) bits |= 1 << 3;
  return btoa(String.fromCharCode(bits));
}

function normalizePermissions(permissions: PermissionState): PermissionState {
  const normalized = { ...permissions };
  if (normalized.delete) normalized.update = true;
  if (normalized.create || normalized.update) normalized.read = true;
  return normalized;
}

function hasAnyPermission(permissions: PermissionState): boolean {
  return Object.values(permissions).some(Boolean);
}

function updatePermission(
  permissions: PermissionState,
  key: PermissionKey,
  checked: boolean,
): PermissionState {
  const next = { ...permissions, [key]: checked };
  if (checked && key === "delete") next.update = true;
  if (checked && (key === "create" || key === "update" || key === "delete")) {
    next.read = true;
  }
  if (!checked && key === "read") {
    next.create = false;
    next.update = false;
    next.delete = false;
  }
  if (!checked && key === "update") next.delete = false;
  return normalizePermissions(next);
}

function decodePermissions(encoded?: string): PermissionState {
  if (!encoded) return { ...EMPTY_PERMISSIONS };
  try {
    const bits = atob(encoded).charCodeAt(0);
    return normalizePermissions({
      read: (bits & (1 << 0)) !== 0,
      update: (bits & (1 << 1)) !== 0,
      create: (bits & (1 << 2)) !== 0,
      delete: (bits & (1 << 3)) !== 0,
    });
  } catch {
    return { ...EMPTY_PERMISSIONS };
  }
}

function expirationFromShare(expires?: string): number {
  if (!expires) return 0;
  const timestamp = Date.parse(expires);
  if (!Number.isFinite(timestamp) || timestamp <= Date.now()) return 0;
  return Math.max(1, Math.floor((timestamp - Date.now()) / 1000));
}

function expirationUnitFor(seconds: number): ExpirationUnit {
  if (seconds > 0 && seconds % EXPIRATION_MULTIPLIERS.days === 0) return "days";
  if (seconds > 0 && seconds % EXPIRATION_MULTIPLIERS.hours === 0) return "hours";
  return "minutes";
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <Box>
      <Typography variant="subtitle2" sx={{ mb: 0.75, fontWeight: 700 }}>
        {title}
      </Typography>
      {children}
    </Box>
  );
}

function PlatformCheckbox({
  checked,
  onChange,
  isMacOS,
}: {
  checked: boolean;
  onChange: (checked: boolean) => void;
  isMacOS: boolean;
}) {
  if (!isMacOS) {
    return (
      <Checkbox
        size="small"
        checked={checked}
        onChange={(event) => onChange(event.target.checked)}
      />
    );
  }

  return (
    <Box
      component="input"
      type="checkbox"
      checked={checked}
      onChange={(event: ChangeEvent<HTMLInputElement>) => onChange(event.target.checked)}
      sx={{
        appearance: "auto",
        WebkitAppearance: "checkbox",
        width: 16,
        height: 16,
        m: "9px",
        flexShrink: 0,
        colorScheme: (theme) => theme.palette.mode,
      }}
    />
  );
}

function AdvancedOptionRow({
  label,
  symbol,
  fallback,
  checked,
  onChange,
  isMacOS,
}: {
  label: string;
  symbol?: string;
  fallback: ReactNode;
  checked: boolean;
  onChange: (checked: boolean) => void;
  isMacOS: boolean;
}) {
  return (
    <Box
      component="label"
      sx={{
        display: "flex",
        alignItems: "center",
        width: "100%",
        minHeight: 48,
        px: 1,
        borderRadius: 1.5,
        cursor: "pointer",
        userSelect: "none",
        "&:hover": { bgcolor: "action.hover" },
      }}
    >
      <Box sx={{ width: 32, display: "grid", placeItems: "center", color: "text.secondary" }}>
        {symbol ? (
          <Box
            component="img"
            src={symbol}
            alt=""
            sx={{
              width: 21,
              height: 21,
              objectFit: "contain",
              filter: (theme) => theme.palette.mode === "light" ? "invert(1)" : "none",
              opacity: 0.72,
            }}
          />
        ) : fallback}
      </Box>
      <Typography variant="body2" sx={{ flex: 1, ml: 1 }}>
        {label}
      </Typography>
      <PlatformCheckbox isMacOS={isMacOS} checked={checked} onChange={onChange} />
    </Box>
  );
}

function PermissionCheckboxes({
  permissions,
  onChange,
  isMacOS,
}: {
  permissions: PermissionState;
  onChange: (permissions: PermissionState) => void;
  isMacOS: boolean;
}) {
  const normalized = normalizePermissions(permissions);
  return (
    <Box sx={{ display: "flex", flexWrap: "wrap", columnGap: 0.5, rowGap: 0 }}>
      {PERMISSION_OPTIONS.map((option) => (
        <FormControlLabel
          key={option.value}
          sx={{ mr: 0.75, my: -0.25 }}
          control={
            <PlatformCheckbox
              isMacOS={isMacOS}
              checked={normalized[option.value]}
              onChange={(checked) =>
                onChange(updatePermission(normalized, option.value, checked))
              }
            />
          }
          label={<Typography variant="caption">{option.label}</Typography>}
        />
      ))}
    </Box>
  );
}

function shareAccessLabel(share: ShareLink): string {
  const settings = share.permission_setting ?? {};
  const hasExplicitAccess = Object.keys(settings.user_explicit ?? {}).length > 0;
  const hasExplicitGroups = Object.keys(settings.group_explicit ?? {}).length > 0;
  const hasGroupAccess =
    hasExplicitGroups ||
    [settings.same_group, settings.other].some((encoded) =>
      hasAnyPermission(decodePermissions(encoded)),
    );
  const hasGeneralAccess = [settings.anonymous, settings.everyone].some((encoded) =>
    hasAnyPermission(decodePermissions(encoded)),
  );
  if ((hasExplicitAccess || hasGroupAccess) && hasGeneralAccess) return "Shared link";
  if (hasGroupAccess && hasExplicitAccess) return "Shared groups and people";
  if (hasGroupAccess) return "Shared groups";
  if (hasExplicitAccess) {
    return "Selected people";
  }
  return share.is_private || share.password_protected ? "Private link" : "Anyone with the link";
}

export default function Share() {
  const isMacOS = platformType() === "macos";
  const [systemShareSymbol, setSystemShareSymbol] = useState<string | null>(null);
  const [advancedSymbols, setAdvancedSymbols] = useState<Record<string, string>>({});
  const [searchParams] = useSearchParams();

  useEffect(() => {
    if (!isMacOS) return;
    const symbols = [
      "square.and.arrow.up",
      "lock.fill",
      "rectangle.grid.2x2.fill",
      "doc.text.fill",
      "timer",
    ];
    Promise.all(
      symbols.map(async (name) => [
        name,
        await invoke<string>("get_system_symbol", { name }).catch(() => ""),
      ] as const),
    )
      .then((entries) => {
        const rendered = Object.fromEntries(entries);
        setSystemShareSymbol(rendered["square.and.arrow.up"]);
        setAdvancedSymbols(rendered);
      })
      .catch(() => {
        setSystemShareSymbol(null);
        setAdvancedSymbols({});
      });
  }, [isMacOS]);

  const [routeTarget, setRouteTarget] = useState<ShareWindowTarget | null>(() => {
    const driveId = searchParams.get("drive_id");
    const uri = searchParams.get("uri");
    return driveId && uri ? { drive_id: driveId, uri } : null;
  });
  const [target, setTarget] = useState<ShareTarget | null>(null);
  const [availableGroups, setAvailableGroups] = useState<ShareGroup[]>([]);
  const [currentGroupId, setCurrentGroupId] = useState<string | null>(null);
  const [groupsLoading, setGroupsLoading] = useState(false);
  const [anonymousPermissions, setAnonymousPermissions] = useState<PermissionState>({
    ...DEFAULT_PERMISSIONS,
  });
  const [everyonePermissions, setEveryonePermissions] = useState<PermissionState>({
    ...DEFAULT_PERMISSIONS,
  });
  const [selectedGroups, setSelectedGroups] = useState<SelectedGroup[]>([]);
  const [selectedPeople, setSelectedPeople] = useState<SelectedPerson[]>([]);
  const [userQuery, setUserQuery] = useState("");
  const [userResults, setUserResults] = useState<ShareUser[]>([]);
  const [searchingUsers, setSearchingUsers] = useState(false);
  const [searchPickerOpen, setSearchPickerOpen] = useState(false);
  const [passwordEnabled, setPasswordEnabled] = useState(false);
  const [password, setPassword] = useState("");
  const [shareView, setShareView] = useState(false);
  const [showReadme, setShowReadme] = useState(false);
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const [existingLinksOpen, setExistingLinksOpen] = useState(false);
  const [expiration, setExpiration] = useState(0);
  const [expirationUnit, setExpirationUnit] = useState<ExpirationUnit>("minutes");
  const [editingShareId, setEditingShareId] = useState<string | null>(null);
  const [footerNotice, setFooterNotice] = useState<FooterNotice | null>(null);
  const footerNoticeTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [deletingShareIds, setDeletingShareIds] = useState<Set<string>>(() => new Set());
  const deletingShareIdsRef = useRef<Set<string>>(new Set());
  const [pendingDeletion, setPendingDeletion] = useState<PendingDeletion | null>(null);
  const deleteTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const deleteQueueRef = useRef<Promise<boolean>>(Promise.resolve(true));
  const deleteOperationsRef = useRef(new Map<string, Promise<boolean>>());
  const closeInProgressRef = useRef(false);
  const closeWindowRef = useRef<() => Promise<void>>(async () => undefined);
  const [error, setError] = useState("");

  const updateDeletingShareIds = (update: (ids: Set<string>) => Set<string>) => {
    setDeletingShareIds((ids) => {
      const next = update(ids);
      deletingShareIdsRef.current = next;
      return next;
    });
  };

  const clearFooterNoticeTimer = useCallback(() => {
    if (footerNoticeTimerRef.current !== null) {
      clearTimeout(footerNoticeTimerRef.current);
      footerNoticeTimerRef.current = null;
    }
  }, []);

  const clearDeleteTimer = useCallback(() => {
    if (deleteTimerRef.current !== null) {
      clearTimeout(deleteTimerRef.current);
      deleteTimerRef.current = null;
    }
  }, []);

  const resetForm = useCallback((preserveDeletion = false) => {
    if (!preserveDeletion) {
      clearDeleteTimer();
      clearFooterNoticeTimer();
    }
    setAnonymousPermissions({ ...DEFAULT_PERMISSIONS });
    setEveryonePermissions({ ...DEFAULT_PERMISSIONS });
    setSelectedGroups([]);
    setSelectedPeople([]);
    setUserQuery("");
    setUserResults([]);
    setSearchPickerOpen(false);
    setPasswordEnabled(false);
    setPassword("");
    setShareView(false);
    setShowReadme(false);
    setAdvancedOpen(false);
    setExistingLinksOpen(false);
    setExpiration(0);
    setExpirationUnit("minutes");
    setEditingShareId(null);
    if (!preserveDeletion) {
      setFooterNotice(null);
      setPendingDeletion(null);
      const nextDeletingShareIds = new Set<string>();
      deletingShareIdsRef.current = nextDeletingShareIds;
      setDeletingShareIds(nextDeletingShareIds);
    }
  }, [clearDeleteTimer, clearFooterNoticeTimer]);

  useEffect(
    () => () => {
      clearDeleteTimer();
      clearFooterNoticeTimer();
    },
    [clearDeleteTimer, clearFooterNoticeTimer],
  );

  const showFooterNotice = useCallback(
    (notice: FooterNotice) => {
      clearFooterNoticeTimer();
      setFooterNotice(notice);
      footerNoticeTimerRef.current = setTimeout(() => {
        footerNoticeTimerRef.current = null;
        setFooterNotice(null);
      }, 5_000);
    },
    [clearFooterNoticeTimer],
  );

  const loadTarget = useCallback(
    async (nextTarget: ShareWindowTarget) => {
      setLoading(true);
      setError("");
      setTarget(null);
      setAvailableGroups([]);
      setCurrentGroupId(null);
      setGroupsLoading(true);
      resetForm();

      for (let attempt = 0; attempt < 10; attempt += 1) {
        try {
          const result = await invoke<ShareTarget>("get_share_target", {
            driveId: nextTarget.drive_id,
            uri: nextTarget.uri,
          });
          setTarget(result);
          setLoading(false);
          try {
            const groupContext = await invoke<ShareGroupContext>("get_share_groups", {
              driveId: nextTarget.drive_id,
            });
            setAvailableGroups(groupContext.groups);
            setCurrentGroupId(groupContext.current_group_id ?? null);
          } catch {
            setAvailableGroups([]);
            setCurrentGroupId(null);
          } finally {
            setGroupsLoading(false);
          }
          return;
        } catch (loadError) {
          const message = String(loadError);
          if (!message.includes("App not yet initialized") || attempt === 9) {
            setError(message);
            setLoading(false);
            setGroupsLoading(false);
            return;
          }
          await new Promise((resolve) => setTimeout(resolve, 400));
        }
      }
    },
    [resetForm],
  );

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    listen<ShareWindowTarget>("share-target", (event) => {
      setRouteTarget(event.payload);
    }).then((cleanup) => {
      unlisten = cleanup;
    });
    return () => unlisten?.();
  }, []);

  useEffect(() => {
    if (routeTarget) loadTarget(routeTarget);
  }, [loadTarget, routeTarget]);

  useEffect(() => {
    if (!target || userQuery.trim().length < 2) {
      setUserResults([]);
      return;
    }

    let cancelled = false;
    const timeout = setTimeout(async () => {
      setSearchingUsers(true);
      try {
        const results = await invoke<ShareUser[]>("search_share_users", {
          driveId: target.drive_id,
          keyword: userQuery.trim(),
        });
        if (!cancelled) setUserResults(results);
      } catch (searchError) {
        if (!cancelled) setError(String(searchError));
      } finally {
        if (!cancelled) setSearchingUsers(false);
      }
    }, 250);

    return () => {
      cancelled = true;
      clearTimeout(timeout);
    };
  }, [target, userQuery]);

  const currentGroupName = availableGroups.find((group) => group.id === currentGroupId)?.name;
  const normalizedUserQuery = userQuery.trim().toLowerCase();
  const filteredGroups = availableGroups.filter(
    (group) =>
      !selectedGroups.some(
        (selected) => selected.kind === "explicit" && selected.id === group.id,
      ) &&
      (!normalizedUserQuery || group.name.toLowerCase().includes(normalizedUserQuery)),
  );
  const sameGroupSelected = selectedGroups.some((group) => group.kind === "same_group");
  const otherGroupsSelected = selectedGroups.some((group) => group.kind === "other");
  const availableUsers = userResults.filter(
    (user) => !selectedPeople.some((person) => person.user.id === user.id),
  );

  const loadShareForEdit = async (share: ShareLink) => {
    if (!target) return;
    setError("");
    try {
      const details = await invoke<ShareLink>("get_share_link_info", {
        driveId: target.drive_id,
        shareId: share.id,
      });
      const settings = details.permission_setting ?? {};
      const explicitUsers = Object.entries(settings.user_explicit ?? {});
      const explicitGroups = Object.entries(settings.group_explicit ?? {});
      let resolvedUsers: ShareUser[] = [];
      if (explicitUsers.length > 0) {
        try {
          resolvedUsers = await invoke<ShareUser[]>("get_share_users", {
            driveId: target.drive_id,
            userIds: explicitUsers.map(([id]) => id),
          });
        } catch {
          resolvedUsers = [];
        }
      }
      const usersById = new Map(resolvedUsers.map((user) => [user.id, user]));
      setAnonymousPermissions(decodePermissions(settings.anonymous));
      setEveryonePermissions(decodePermissions(settings.everyone));
      setSelectedGroups([
        ...(hasAnyPermission(decodePermissions(settings.same_group))
          ? [
              {
                id: "same_group",
                name: "Same group with me",
                kind: "same_group" as const,
                permissions: decodePermissions(settings.same_group),
              },
            ]
          : []),
        ...(hasAnyPermission(decodePermissions(settings.other))
          ? [
              {
                id: "other",
                name: "Other groups",
                kind: "other" as const,
                permissions: decodePermissions(settings.other),
              },
            ]
          : []),
        ...explicitGroups
          .filter(([, encoded]) => hasAnyPermission(decodePermissions(encoded)))
          .map(([id, encoded]) => ({
            id,
            name: availableGroups.find((group) => group.id === id)?.name ?? id,
            kind: "explicit" as const,
            permissions: decodePermissions(encoded),
          })),
      ]);
      setSelectedPeople(
        explicitUsers.map(([id, encoded]) => ({
          user: usersById.get(id) ?? { id, nickname: id },
          permissions: decodePermissions(encoded),
        })),
      );
      setPasswordEnabled(details.password_protected === true || !!details.password);
      setPassword(details.password ?? "");
      setShareView(details.share_view ?? false);
      setShowReadme(details.show_readme ?? false);
      const loadedExpiration = expirationFromShare(details.expires);
      setExpiration(loadedExpiration);
      setExpirationUnit(expirationUnitFor(loadedExpiration));
      setEditingShareId(details.id);
      clearFooterNoticeTimer();
      setFooterNotice(null);
    } catch (loadError) {
      setError(String(loadError));
    }
  };

  const requestForForm = () => {
    if (!target) throw new Error("No share target selected");
    const hasGeneralAccess =
      hasAnyPermission(anonymousPermissions) || hasAnyPermission(everyonePermissions);
    const hasGroupAccess = selectedGroups.some((group) => hasAnyPermission(group.permissions));
    const hasExplicitAccess = selectedPeople.some((person) => hasAnyPermission(person.permissions));
    if (!hasGeneralAccess && !hasGroupAccess && !hasExplicitAccess) {
      throw new Error("Grant access to at least one person or general access group");
    }

    const sameGroup = selectedGroups.find(
      (group) => group.kind === "same_group" && hasAnyPermission(group.permissions),
    );
    const otherGroups = selectedGroups.find(
      (group) => group.kind === "other" && hasAnyPermission(group.permissions),
    );
    const permissions: PermissionSetting = {
      ...(sameGroup && { same_group: encodePermissions(sameGroup.permissions) }),
      anonymous: encodePermissions(anonymousPermissions),
      everyone: encodePermissions(everyonePermissions),
      ...(otherGroups && { other: encodePermissions(otherGroups.permissions) }),
      ...(selectedGroups.some(
        (group) => group.kind === "explicit" && hasAnyPermission(group.permissions),
      ) && {
        group_explicit: Object.fromEntries(
          selectedGroups
            .filter((group) => group.kind === "explicit" && hasAnyPermission(group.permissions))
            .map((group) => [group.id, encodePermissions(group.permissions)]),
        ),
      }),
      ...(selectedPeople.some((person) => hasAnyPermission(person.permissions)) && {
        user_explicit: Object.fromEntries(
          selectedPeople
            .filter((person) => hasAnyPermission(person.permissions))
            .map((person) => [person.user.id, encodePermissions(person.permissions)]),
        ),
      }),
    };

    return {
      permissions,
      uri: target.uri,
      is_private: !hasGeneralAccess || passwordEnabled,
      share_view: shareView,
      expire: expiration,
      price: 0,
      password: passwordEnabled ? password.trim() : undefined,
      show_readme: target.is_folder && showReadme,
    };
  };

  const handleSave = async () => {
    if (!target) return;
    setError("");
    clearFooterNoticeTimer();
    setFooterNotice(null);
    try {
      const request = requestForForm();
      setSaving(true);
      const result = await invoke<string>(
        editingShareId ? "edit_share_link" : "create_share_link",
        editingShareId
          ? {
              driveId: target.drive_id,
              shareId: editingShareId,
              request,
            }
          : { driveId: target.drive_id, request },
      );
      await copyUrl(result);
      const refreshed = await invoke<ShareTarget>("get_share_target", {
        driveId: target.drive_id,
        uri: target.uri,
      });
      setTarget(refreshed);
    } catch (saveError) {
      setError(String(saveError));
    } finally {
      setSaving(false);
    }
  };

  const copyUrl = async (url: string) => {
    try {
      await navigator.clipboard.writeText(url);
      showFooterNotice({ message: "Share link copied to clipboard", severity: "success" });
    } catch (copyError) {
      setError(`Could not copy link: ${copyError}`);
    }
  };

  const restorePendingDeletion = (pending: PendingDeletion) => {
    setTarget((current) => {
      if (
        !current ||
        current.drive_id !== pending.driveId ||
        current.uri !== pending.uri ||
        current.shares.some((share) => share.id === pending.share.id)
      ) {
        return current;
      }
      const shares = [...current.shares];
      shares.splice(Math.min(pending.index, shares.length), 0, pending.share);
      return { ...current, shares };
    });
  };

  const completeDelete = (pending: PendingDeletion): Promise<boolean> => {
    const existing = deleteOperationsRef.current.get(pending.share.id);
    if (existing) return existing;

    const operation = deleteQueueRef.current
      .catch(() => true)
      .then(async () => {
        let deleted = false;
        setPendingDeletion((current) =>
          current?.share.id === pending.share.id ? null : current,
        );
        try {
          await invoke("delete_share_link", {
            driveId: pending.driveId,
            shareId: pending.share.id,
          });
          deleted = true;
          if (editingShareId === pending.share.id) resetForm(true);
          const refreshed = await invoke<ShareTarget>("get_share_target", {
            driveId: pending.driveId,
            uri: pending.uri,
          });
          setTarget({
            ...refreshed,
            shares: refreshed.shares.filter(
              (share) => !deletingShareIdsRef.current.has(share.id),
            ),
          });
        } catch (deleteError) {
          if (!deleted) restorePendingDeletion(pending);
          setError(String(deleteError));
        } finally {
          setPendingDeletion((current) =>
            current?.share.id === pending.share.id ? null : current,
          );
          updateDeletingShareIds((ids) => {
            const next = new Set(ids);
            next.delete(pending.share.id);
            return next;
          });
        }
        return deleted;
      });

    deleteOperationsRef.current.set(pending.share.id, operation);
    deleteQueueRef.current = operation.catch(() => false);
    operation.finally(() => {
      if (deleteOperationsRef.current.get(pending.share.id) === operation) {
        deleteOperationsRef.current.delete(pending.share.id);
      }
    }).catch(() => undefined);
    return operation;
  };

  const handleDelete = (share: ShareLink) => {
    if (!target || deletingShareIds.has(share.id)) return;
    setError("");
    if (pendingDeletion) {
      const previous = pendingDeletion;
      clearDeleteTimer();
      setPendingDeletion(null);
      void completeDelete(previous);
    }
    const pending: PendingDeletion = {
      share,
      driveId: target.drive_id,
      uri: target.uri,
      index: target.shares.findIndex((item) => item.id === share.id),
    };
    setPendingDeletion(pending);
    updateDeletingShareIds((ids) => new Set(ids).add(share.id));
    showFooterNotice({ message: "Share link deleted", severity: "error", action: "undo" });
    setTarget((current) => {
      if (!current || current.drive_id !== pending.driveId || current.uri !== pending.uri) {
        return current;
      }
      return {
        ...current,
        shares: current.shares.filter((item) => item.id !== pending.share.id),
      };
    });
    deleteTimerRef.current = setTimeout(() => {
      deleteTimerRef.current = null;
      void completeDelete(pending);
    }, 5_000);
  };

  const undoDelete = () => {
    if (!pendingDeletion) return;
    const pending = pendingDeletion;
    clearDeleteTimer();
    setPendingDeletion(null);
    updateDeletingShareIds((ids) => {
      const next = new Set(ids);
      next.delete(pending.share.id);
      return next;
    });
    restorePendingDeletion(pending);
    showFooterNotice({ message: "Share link restored", severity: "success" });
  };

  const closeWindow = async () => {
    if (closeInProgressRef.current) return;
    closeInProgressRef.current = true;
    clearDeleteTimer();
    try {
      const pending = pendingDeletion;
      if (pending) {
        setPendingDeletion(null);
        void completeDelete(pending);
      }
      const deletions = [...deleteOperationsRef.current.values()];
      const results = await Promise.all(deletions);
      if (results.some((deleted) => !deleted)) return;
      await getCurrentWindow().destroy();
    } catch (closeError) {
      setError(String(closeError));
    } finally {
      closeInProgressRef.current = false;
    }
  };

  closeWindowRef.current = closeWindow;

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let cancelled = false;
    void getCurrentWindow()
      .onCloseRequested(async (event) => {
        if (closeInProgressRef.current) return;
        event.preventDefault();
        await closeWindowRef.current();
      })
      .then((removeListener) => {
        if (cancelled) {
          removeListener();
        } else {
          unlisten = removeListener;
        }
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, []);

  const groupSelectionKey = (group: Pick<SelectedGroup, "id" | "kind">) =>
    `${group.kind}:${group.id}`;

  const addGroup = (group: ShareGroup, kind: GroupSelectionKind = "explicit") => {
    const selectedGroup: SelectedGroup = {
      id: kind === "explicit" ? group.id : kind,
      name: group.name,
      kind,
      permissions: { ...DEFAULT_PERMISSIONS },
    };
    setSelectedGroups((groups) =>
      groups.some((item) => groupSelectionKey(item) === groupSelectionKey(selectedGroup))
        ? groups
        : [...groups, selectedGroup],
    );
    setUserQuery("");
    setUserResults([]);
    setSearchPickerOpen(false);
  };

  const removeGroup = (group: SelectedGroup) => {
    setSelectedGroups((groups) =>
      groups.filter((item) => groupSelectionKey(item) !== groupSelectionKey(group)),
    );
  };

  const avatarUrl = (user: ShareUser) => {
    if (!user.avatar || !target?.instance_url) return undefined;
    return `${target.instance_url.replace(/\/+$/, "")}/api/v4/user/avatar/${encodeURIComponent(user.id)}?nocache=true`;
  };

  const addPerson = (user: ShareUser) => {
    if (selectedPeople.some((person) => person.user.id === user.id)) return;
    setSelectedPeople((people) => [
      ...people,
      { user, permissions: { ...DEFAULT_PERMISSIONS } },
    ]);
    setUserQuery("");
    setUserResults([]);
    setSearchPickerOpen(false);
  };

  return (
    <Box
      sx={{
        height: "100%",
        minHeight: 0,
        width: "100%",
        display: "flex",
        flexDirection: "column",
        bgcolor: "background.paper",
        borderRadius: "14px",
        border: "1px solid",
        borderColor: (theme) =>
          theme.palette.mode === "dark"
            ? "rgba(255, 255, 255, 0.12)"
            : "rgba(0, 0, 0, 0.08)",
        boxShadow: (theme) =>
          theme.palette.mode === "dark"
            ? "0 3px 14px rgba(0, 0, 0, 0.24)"
            : "0 3px 14px rgba(0, 0, 0, 0.08)",
        boxSizing: "border-box",
        overflow: "hidden",
      }}
    >
      <Box
        sx={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          px: 2,
          pl: isMacOS ? "91px" : 2,
          py: 1.25,
          borderBottom: 1,
          borderColor: "divider",
        }}
      >
        <Stack
          direction="row"
          spacing={isMacOS ? 1.25 : 1}
          alignItems="center"
          sx={{ flex: 1, minWidth: 0, overflow: "hidden", transform: isMacOS ? "translateY(-2px)" : undefined }}
        >
          {systemShareSymbol ? (
            <Box
              component="img"
              src={systemShareSymbol}
              alt=""
              sx={{
                width: 20,
                height: 20,
                flexShrink: 0,
                objectFit: "contain",
                filter: (theme) => theme.palette.mode === "light" ? "invert(1)" : "none",
                transform: "translateY(-1px)",
              }}
            />
          ) : (
            <IosShareOutlinedIcon
              sx={{ flexShrink: 0, fontSize: 20, color: isMacOS ? "text.primary" : "primary.main", transform: isMacOS ? "translateY(-1px)" : undefined }}
            />
          )}
          <Stack
            direction="row"
            spacing={0.75}
            alignItems="baseline"
            sx={{ flex: 1, minWidth: 0, overflow: "hidden", transform: isMacOS ? "translateY(1px)" : undefined }}
          >
            <Typography variant="subtitle1" fontWeight={700} noWrap sx={{ flexShrink: 0 }}>
              Share
            </Typography>
            <Typography
              variant="body2"
              color="text.secondary"
              noWrap
              sx={{ minWidth: 0, overflow: "hidden", textOverflow: "ellipsis" }}
            >
              {target?.name ?? "Cloudreve item"}
            </Typography>
          </Stack>
        </Stack>
        {!isMacOS && (
          <IconButton size="small" onClick={closeWindow} aria-label="Close" sx={{ flexShrink: 0, ml: 1 }}>
            <CloseIcon fontSize="small" />
          </IconButton>
        )}
      </Box>

      <Box
        sx={{
          flex: 1,
          minHeight: 0,
          minWidth: 0,
          overflowY: "auto",
          overflowX: "hidden",
          overscrollBehavior: "contain",
          p: 2,
        }}
      >
        {loading ? (
          <Stack alignItems="center" justifyContent="center" height="100%" spacing={1}>
            <CircularProgress size={28} />
            <Typography variant="body2" color="text.secondary">
              Loading share settings…
            </Typography>
          </Stack>
        ) : error && !target ? (
          <Stack spacing={2}>
            <Alert severity="error">{error}</Alert>
            <Button variant="outlined" onClick={() => routeTarget && loadTarget(routeTarget)}>
              Try again
            </Button>
          </Stack>
        ) : target ? (
          <Stack spacing={2}>
            {error && (
              <Alert severity="error" onClose={() => setError("")}>
                {error}
              </Alert>
            )}

            {advancedOpen ? (
              <Section title="Advanced options">
                <Paper variant="outlined" sx={{ p: 1.25 }}>
                  <Stack spacing={0.25}>
                    <AdvancedOptionRow
                      label="Protect with password"
                      symbol={advancedSymbols["lock.fill"]}
                      fallback={<LockOutlinedIcon fontSize="small" />}
                      checked={passwordEnabled}
                      onChange={setPasswordEnabled}
                      isMacOS={isMacOS}
                    />
                    {passwordEnabled && (
                      <TextField
                        size="small"
                        fullWidth
                        type="password"
                        label="Password"
                        value={password}
                        onChange={(event) => setPassword(event.target.value)}
                        inputProps={{ maxLength: 32, pattern: "[A-Za-z0-9]+" }}
                        helperText="Use up to 32 letters or numbers."
                      />
                    )}
                    <AdvancedOptionRow
                      label="Enable share view"
                      symbol={advancedSymbols["rectangle.grid.2x2.fill"]}
                      fallback={<DashboardOutlinedIcon fontSize="small" />}
                      checked={shareView}
                      onChange={setShareView}
                      isMacOS={isMacOS}
                    />
                    {target.is_folder && (
                      <AdvancedOptionRow
                        label="Show README file"
                        symbol={advancedSymbols["doc.text.fill"]}
                        fallback={<DescriptionOutlinedIcon fontSize="small" />}
                        checked={showReadme}
                        onChange={setShowReadme}
                        isMacOS={isMacOS}
                      />
                    )}
                    <AdvancedOptionRow
                      label="Automatic expiration"
                      symbol={advancedSymbols.timer}
                      fallback={<TimerOutlinedIcon fontSize="small" />}
                      checked={expiration > 0}
                      onChange={(checked) => {
                        if (checked) setExpirationUnit("minutes");
                        setExpiration(checked ? 5 * EXPIRATION_MULTIPLIERS.minutes : 0);
                      }}
                      isMacOS={isMacOS}
                    />
                    {expiration > 0 && (
                      <Stack
                        direction="row"
                        alignItems="center"
                        gap={1}
                        sx={{ pl: 6, pr: 1, pb: 1 }}
                      >
                        <Typography variant="body2" color="text.secondary" sx={{ whiteSpace: "nowrap" }}>
                          Expire after
                        </Typography>
                        <TextField
                          size="small"
                          type="number"
                          value={Math.max(
                            1,
                            Math.round(expiration / EXPIRATION_MULTIPLIERS[expirationUnit]),
                          )}
                          onChange={(event) => {
                            const amount = Math.max(1, Math.floor(Number(event.target.value) || 1));
                            setExpiration(amount * EXPIRATION_MULTIPLIERS[expirationUnit]);
                          }}
                          inputProps={{ min: 1, step: 1 }}
                          sx={{ width: 110 }}
                        />
                        <FormControl size="small" sx={{ minWidth: 120 }}>
                          <Select
                            value={expirationUnit}
                            onChange={(event) => {
                              const nextUnit = event.target.value as ExpirationUnit;
                              const amount = Math.max(
                                1,
                                Math.round(expiration / EXPIRATION_MULTIPLIERS[expirationUnit]),
                              );
                              setExpirationUnit(nextUnit);
                              setExpiration(amount * EXPIRATION_MULTIPLIERS[nextUnit]);
                            }}
                        >
                            <MenuItem value="minutes">Minutes</MenuItem>
                            <MenuItem value="hours">Hours</MenuItem>
                            <MenuItem value="days">Days</MenuItem>
                          </Select>
                        </FormControl>
                      </Stack>
                    )}
                  </Stack>
                </Paper>
              </Section>
            ) : (
              <>

            {target.shares.length > 0 && (
              <Box>
                <ButtonBase
                  onClick={() => setExistingLinksOpen((open) => !open)}
                  aria-expanded={existingLinksOpen}
                  aria-controls="share-existing-links"
                  sx={{
                    width: "100%",
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "space-between",
                    borderRadius: 1,
                    px: 0.5,
                    py: 0.25,
                    textAlign: "left",
                    color: "text.primary",
                  }}
                >
                  <Typography variant="subtitle2" sx={{ fontWeight: 700 }}>
                    Existing share links ({target.shares.length})
                  </Typography>
                  {existingLinksOpen ? <ExpandLessIcon /> : <ExpandMoreIcon />}
                </ButtonBase>
                {existingLinksOpen && (
                  <Paper id="share-existing-links" variant="outlined" sx={{ overflow: "hidden", mt: 0.75 }}>
                    <List dense disablePadding>
                      {target.shares.map((share, index) => (
                        <Box key={share.id}>
                          {index > 0 && <Divider />}
                          <ListItem
                            secondaryAction={
                              <Stack direction="row" spacing={0.25}>
                                <IconButton
                                  size="small"
                                  disabled={deletingShareIds.has(share.id)}
                                  onClick={() => copyUrl(share.url)}
                                  aria-label="Copy link"
                                >
                                  <ContentCopyIcon fontSize="small" />
                                </IconButton>
                                <IconButton
                                  size="small"
                                  disabled={deletingShareIds.has(share.id)}
                                  onClick={() => loadShareForEdit(share)}
                                  aria-label="Edit share"
                                >
                                  <EditOutlinedIcon fontSize="small" />
                                </IconButton>
                                <IconButton
                                  size="small"
                                  color="error"
                                  disabled={deletingShareIds.has(share.id)}
                                  onClick={() => handleDelete(share)}
                                  aria-label="Delete share"
                                >
                                  {deletingShareIds.has(share.id) ? (
                                    <CircularProgress size={16} />
                                  ) : (
                                    <DeleteOutlineIcon fontSize="small" />
                                  )}
                                </IconButton>
                              </Stack>
                            }
                          >
                            <ListItemAvatar sx={{ minWidth: 38 }}>
                              <Avatar sx={{ width: 28, height: 28 }}>
                                {shareAccessLabel(share) !== "Anyone with the link" &&
                                shareAccessLabel(share) !== "Private link" ? (
                                  <GroupOutlinedIcon fontSize="small" />
                                ) : (
                                  <LinkIcon fontSize="small" />
                                )}
                              </Avatar>
                            </ListItemAvatar>
                            <ListItemText
                              primary={shareAccessLabel(share)}
                              secondary={share.url}
                              slotProps={{
                                primary: { noWrap: true },
                                secondary: { noWrap: true },
                              }}
                              sx={{ pr: 11 }}
                            />
                          </ListItem>
                        </Box>
                      ))}
                    </List>
                  </Paper>
                )}
              </Box>
            )}

            <Box
              sx={{ position: "relative" }}
              onFocus={() => setSearchPickerOpen(true)}
              onBlur={() => setTimeout(() => setSearchPickerOpen(false), 150)}
            >
              <TextField
                fullWidth
                size="small"
                placeholder="Search for emails or groups..."
                value={userQuery}
                onChange={(event) => {
                  setUserQuery(event.target.value);
                  setSearchPickerOpen(true);
                }}
                InputProps={{
                  endAdornment: (
                    <Stack direction="row" alignItems="center">
                      {searchingUsers && <CircularProgress size={18} sx={{ mr: 0.5 }} />}
                      <IconButton
                        size="small"
                        tabIndex={-1}
                        onMouseDown={(event) => event.preventDefault()}
                        onClick={() => setSearchPickerOpen((open) => !open)}
                        aria-label={searchPickerOpen ? "Hide recipients" : "Show recipients"}
                      >
                        {searchPickerOpen ? <ExpandLessIcon /> : <ExpandMoreIcon />}
                      </IconButton>
                    </Stack>
                  ),
                }}
              />
              {searchPickerOpen &&
                (groupsLoading ||
                  normalizedUserQuery.length < 2 ||
                  availableGroups.length > 0 ||
                  searchingUsers ||
                  availableUsers.length > 0) && (
                  <Paper
                    variant="outlined"
                    sx={{
                      position: "absolute",
                      zIndex: 2,
                      left: 0,
                      right: 0,
                      mt: 0.5,
                      maxHeight: 300,
                      overflow: "auto",
                      pb: 1,
                    }}
                  >
                    {normalizedUserQuery.length < 2 && (
                      <>
                        <Typography
                          variant="caption"
                          color="text.secondary"
                          sx={{ display: "block", px: 2, pt: 1.25, pb: 0.5, fontWeight: 700 }}
                        >
                          Built-in collections
                        </Typography>
                        <List dense disablePadding>
                          <ListItemButton
                            disabled={sameGroupSelected}
                            onClick={() =>
                              addGroup(
                                {
                                  id: "same_group",
                                  name: "Same group with me",
                                },
                                "same_group",
                              )
                            }
                          >
                            <ListItemAvatar sx={{ minWidth: 38 }}>
                              <Avatar sx={{ width: 28, height: 28, bgcolor: "success.main" }}>
                                <GroupOutlinedIcon fontSize="small" />
                              </Avatar>
                            </ListItemAvatar>
                            <ListItemText
                              primary="Same group with me"
                              secondary={currentGroupName ? `Members of ${currentGroupName}` : "Members of your group"}
                            />
                          </ListItemButton>
                          <ListItemButton
                            disabled={otherGroupsSelected}
                            onClick={() =>
                              addGroup(
                                {
                                  id: "other",
                                  name: "Other groups",
                                },
                                "other",
                              )
                            }
                          >
                            <ListItemAvatar sx={{ minWidth: 38 }}>
                              <Avatar sx={{ width: 28, height: 28, bgcolor: "warning.main" }}>
                                <GroupOutlinedIcon fontSize="small" />
                              </Avatar>
                            </ListItemAvatar>
                            <ListItemText
                              primary="Other groups"
                              secondary="Members outside your group"
                            />
                          </ListItemButton>
                        </List>
                      </>
                    )}

                    {(filteredGroups.length > 0 || groupsLoading) && (
                      <>
                        <Typography
                          variant="caption"
                          color="text.secondary"
                          sx={{ display: "block", px: 2, pt: 1.25, pb: 0.5, fontWeight: 700 }}
                        >
                          Groups
                        </Typography>
                        {groupsLoading ? (
                          <Stack alignItems="center" py={1}>
                            <CircularProgress size={20} />
                          </Stack>
                        ) : (
                          <List dense disablePadding>
                            {filteredGroups.map((group) => (
                              <ListItemButton key={group.id} onClick={() => addGroup(group)}>
                                <ListItemAvatar sx={{ minWidth: 38 }}>
                                  <Avatar sx={{ width: 28, height: 28, bgcolor: "primary.main" }}>
                                    <GroupOutlinedIcon fontSize="small" />
                                  </Avatar>
                                </ListItemAvatar>
                                <ListItemText primary={group.name} />
                              </ListItemButton>
                            ))}
                          </List>
                        )}
                      </>
                    )}

                    {availableUsers.length > 0 && (
                      <>
                        <Typography
                          variant="caption"
                          color="text.secondary"
                          sx={{ display: "block", px: 2, pt: 1.25, pb: 0.5, fontWeight: 700 }}
                        >
                          People
                        </Typography>
                        <List dense disablePadding>
                          {availableUsers.map((user) => (
                            <ListItemButton key={user.id} onClick={() => addPerson(user)}>
                              <ListItemAvatar sx={{ minWidth: 38 }}>
                                <Avatar src={avatarUrl(user)} sx={{ width: 28, height: 28 }}>
                                  {user.nickname.slice(0, 1).toUpperCase()}
                                </Avatar>
                              </ListItemAvatar>
                              <ListItemText
                                primary={user.nickname}
                                secondary={user.email ?? user.group?.name}
                              />
                            </ListItemButton>
                          ))}
                        </List>
                      </>
                    )}
                    {!groupsLoading &&
                      normalizedUserQuery.length >= 2 &&
                      filteredGroups.length === 0 &&
                      availableUsers.length === 0 &&
                      !searchingUsers && (
                        <Typography color="text.secondary" sx={{ px: 2, py: 1.5 }}>
                          No matching people or groups
                        </Typography>
                      )}
                  </Paper>
                )}
            </Box>

            {selectedGroups.length > 0 && (
              <Section title="Group access">
                <Paper variant="outlined" sx={{ overflow: "hidden" }}>
                  <List dense disablePadding>
                    {selectedGroups.map((group, index) => (
                      <Box key={groupSelectionKey(group)}>
                        {index > 0 && <Divider />}
                        <ListItem
                          secondaryAction={
                            <IconButton
                              edge="end"
                              size="small"
                              onClick={() => removeGroup(group)}
                              aria-label="Remove group"
                            >
                              <CloseIcon fontSize="small" />
                            </IconButton>
                          }
                        >
                          <ListItemAvatar sx={{ minWidth: 38 }}>
                            <Avatar
                              sx={{
                                width: 28,
                                height: 28,
                                bgcolor: group.kind === "same_group" ? "success.main" :
                                  group.kind === "other" ? "warning.main" : "primary.main",
                              }}
                            >
                              <GroupOutlinedIcon fontSize="small" />
                            </Avatar>
                          </ListItemAvatar>
                          <Box sx={{ flex: 1, minWidth: 0, pr: 7 }}>
                            <ListItemText
                              primary={group.name}
                              secondary={
                                group.kind === "same_group"
                                  ? currentGroupName
                                    ? `Members of ${currentGroupName}`
                                    : "Members of your group"
                                  : group.kind === "other"
                                    ? "Members outside your group"
                                    : "Cloudreve group"
                              }
                              sx={{ m: 0 }}
                            />
                            <PermissionCheckboxes
                              isMacOS={isMacOS}
                              permissions={group.permissions}
                              onChange={(permissions) =>
                                setSelectedGroups((groups) =>
                                  groups.map((item) =>
                                    groupSelectionKey(item) === groupSelectionKey(group)
                                      ? { ...item, permissions }
                                      : item,
                                  ),
                                )
                              }
                            />
                          </Box>
                        </ListItem>
                      </Box>
                    ))}
                  </List>
                </Paper>
              </Section>
            )}

            {selectedPeople.length > 0 && (
              <Section title="Explicit access">
                <Paper variant="outlined" sx={{ overflow: "hidden" }}>
                  <List dense disablePadding>
                    {selectedPeople.map((person, index) => (
                      <Box key={person.user.id}>
                        {index > 0 && <Divider />}
                        <ListItem
                          secondaryAction={
                            <IconButton
                              edge="end"
                              size="small"
                              onClick={() =>
                                setSelectedPeople((people) => people.filter((item) => item.user.id !== person.user.id))
                              }
                              aria-label="Remove person"
                            >
                              <CloseIcon fontSize="small" />
                          </IconButton>
                          }
                        >
                          <ListItemAvatar sx={{ minWidth: 38 }}>
                            <Avatar src={avatarUrl(person.user)} sx={{ width: 28, height: 28 }}>
                              {person.user.nickname.slice(0, 1).toUpperCase()}
                            </Avatar>
                          </ListItemAvatar>
                          <Box sx={{ flex: 1, minWidth: 0, pr: 7 }}>
                            <ListItemText
                              primary={person.user.nickname}
                              secondary={person.user.email ?? "Cloudreve user"}
                              sx={{ m: 0 }}
                            />
                            <PermissionCheckboxes
                              isMacOS={isMacOS}
                              permissions={person.permissions}
                              onChange={(permissions) =>
                                setSelectedPeople((people) =>
                                  people.map((item) =>
                                    item.user.id === person.user.id ? { ...item, permissions } : item,
                                  ),
                                )
                              }
                            />
                          </Box>
                        </ListItem>
                      </Box>
                    ))}
                  </List>
                </Paper>
              </Section>
            )}

            <Section title="General access">
              <Stack spacing={1}>
                <Paper variant="outlined" sx={{ p: 1.25 }}>
                  <Stack direction="row" spacing={1.25} alignItems="flex-start">
                    <Avatar sx={{ bgcolor: "action.selected", color: "text.primary" }}>
                      <PublicIcon fontSize="small" />
                    </Avatar>
                    <Box flex={1} minWidth={0}>
                      <Typography variant="body2" fontWeight={600}>
                        Anonymous visitors
                      </Typography>
                      <Typography variant="caption" color="text.secondary">
                        Anyone with the link, without signing in
                      </Typography>
                      <PermissionCheckboxes
                        isMacOS={isMacOS}
                        permissions={anonymousPermissions}
                        onChange={setAnonymousPermissions}
                      />
                    </Box>
                  </Stack>
                </Paper>
                <Paper variant="outlined" sx={{ p: 1.25 }}>
                  <Stack direction="row" spacing={1.25} alignItems="flex-start">
                    <Avatar sx={{ bgcolor: "action.selected", color: "text.primary" }}>
                      <GroupOutlinedIcon fontSize="small" />
                    </Avatar>
                    <Box flex={1} minWidth={0}>
                      <Typography variant="body2" fontWeight={600}>
                        Everyone else
                      </Typography>
                      <Typography variant="caption" color="text.secondary">
                        Signed-in Cloudreve users
                      </Typography>
                      <PermissionCheckboxes
                        isMacOS={isMacOS}
                        permissions={everyonePermissions}
                        onChange={setEveryonePermissions}
                      />
                    </Box>
                  </Stack>
                </Paper>
              </Stack>
            </Section>

              </>
            )}
          </Stack>
        ) : null}
      </Box>

      {target && (
        <Box
          sx={{
            position: "relative",
            flexShrink: 0,
            px: 2,
            py: 1.25,
            borderTop: 1,
            borderColor: "divider",
            bgcolor: "background.paper",
          }}
        >
          {footerNotice && (
            <Box
              sx={{
                position: "absolute",
                zIndex: 1,
                bottom: "calc(100% + 8px)",
                left: 0,
                right: 0,
                px: 2,
                boxSizing: "border-box",
              }}
            >
              <Alert
                severity={footerNotice.severity}
                icon={
                  footerNotice.message === "Share link deleted" ? (
                    <DeleteOutlineIcon fontSize="inherit" />
                  ) : (
                    <LinkIcon fontSize="inherit" />
                  )
                }
                action={
                  footerNotice.action === "undo" && pendingDeletion ? (
                    <Button size="small" onClick={undoDelete}>
                      Undo
                    </Button>
                  ) : undefined
                }
                sx={{
                  width: "100%",
                  minWidth: 0,
                  py: 0.25,
                  px: 1,
                  boxShadow: "none",
                  backgroundColor: (theme) =>
                      footerNotice.severity === "error"
                        ? theme.palette.mode === "dark"
                          ? "#8c1d18"
                          : "#ffebee"
                        : theme.palette.mode === "dark"
                          ? "#2e7d32"
                          : "#edf7ed",
                  color: (theme) =>
                    footerNotice.severity === "error"
                      ? theme.palette.mode === "dark"
                        ? "#ffb4ab"
                        : "#b71c1c"
                      : theme.palette.mode === "dark"
                        ? "#b7f5b9"
                        : "#205b29",
                  "& .MuiAlert-icon": {
                    color: (theme) =>
                      footerNotice.severity === "error"
                        ? theme.palette.mode === "dark"
                          ? "#ff8a80"
                          : "#d32f2f"
                        : theme.palette.mode === "dark"
                          ? "#7ee787"
                          : "#388e3c",
                  },
                  "& .MuiButton-root": {
                    color: (theme) =>
                      footerNotice.severity === "error"
                        ? theme.palette.mode === "dark"
                          ? "#ffb4ab"
                          : "#b71c1c"
                        : theme.palette.mode === "dark"
                          ? "#b7f5b9"
                          : "#205b29",
                  },
                  "& .MuiAlert-message": {
                    minWidth: 0,
                    overflow: "hidden",
                    textOverflow: "ellipsis",
                    whiteSpace: "nowrap",
                  },
                  "& .MuiAlert-action": { alignItems: "center", py: 0, mr: 0 },
                }}
              >
                {footerNotice.message}
              </Alert>
            </Box>
          )}

          <Stack
            direction="row"
            alignItems="center"
            justifyContent="space-between"
            sx={{ width: "100%", minWidth: 0 }}
          >
            <IconButton
              size="small"
              onClick={() => setAdvancedOpen((open) => !open)}
              aria-expanded={advancedOpen}
              aria-label={advancedOpen ? "Back to share options" : "Show advanced options"}
              sx={{ flexShrink: 0 }}
            >
              {advancedOpen ? <ArrowBackIcon fontSize="small" /> : <SettingsIcon fontSize="small" />}
            </IconButton>
            <Stack
              direction="row"
              justifyContent="flex-end"
              spacing={1}
              sx={{ flexShrink: 0, marginLeft: "auto" }}
            >
              {editingShareId && (
                <Button variant="text" onClick={() => resetForm()} disabled={saving}>
                  Cancel edit
                </Button>
              )}
              <Button
                variant="contained"
                onClick={handleSave}
                disabled={
                  saving ||
                  !!pendingDeletion ||
                  deletingShareIds.size > 0
                }
                startIcon={saving ? <CircularProgress size={16} color="inherit" /> : <LinkIcon />}
              >
                {editingShareId ? "Save changes" : "Create link"}
              </Button>
            </Stack>
          </Stack>
        </Box>
      )}
    </Box>
  );
}
