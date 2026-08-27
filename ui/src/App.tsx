import { Suspense, useEffect, useMemo, useState } from "react";
import {
  ThemeProvider,
  CssBaseline,
  GlobalStyles,
  Box,
  useMediaQuery,
} from "@mui/material";
import { Routes, Route, HashRouter } from "react-router-dom";
import { getCurrentWindow } from "@tauri-apps/api/window";
import type { Theme as TauriTheme } from "@tauri-apps/api/window";
import { type as platformType } from "@tauri-apps/plugin-os";
import "@fontsource/roboto/300.css";
import "@fontsource/roboto/400.css";
import "@fontsource/roboto/500.css";
import "@fontsource/roboto/700.css";
import "./i18n";
import { createAppTheme } from "./theme";
import AddDrive from "./pages/AddDrive";
import Popup from "./pages/popup";
import Settings from "./pages/settings";

function LoadingFallback() {
  return (
    <Box
      sx={{
        display: "flex",
        justifyContent: "center",
        alignItems: "center",
        height:"80vh"
      }}
    >
    </Box>
  );
}

/**
 * Resolve the UI theme from the native window appearance (Tauri) and fall
 * back to the CSS media query. Some windows (transparent/undecorated tray
 * popups, overlay title bars) misreport `prefers-color-scheme` in WKWebView,
 * so the native value wins when available.
 */
function useDarkMode(): boolean {
  const mediaDark = useMediaQuery("(prefers-color-scheme: dark)");
  const [nativeDark, setNativeDark] = useState<boolean | null>(null);

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    const win = getCurrentWindow();
    win
      .theme()
      .then((t: TauriTheme | null) => setNativeDark(t === "dark"))
      .catch(() => setNativeDark(null));
    win
      .onThemeChanged(({ payload }) => setNativeDark(payload === "dark"))
      .then((fn) => {
        unlisten = fn;
      })
      .catch(() => {});
    return () => unlisten?.();
  }, []);

  return nativeDark ?? mediaDark;
}

function App() {
  const darkMode = useDarkMode();
  const isRoundedMacOSWindow =
    platformType() === "macos" &&
    (window.location.hash.startsWith("#/popup") ||
      window.location.hash.startsWith("#/settings"));
  const theme = useMemo(
    () => createAppTheme(darkMode ? "dark" : "light"),
    [darkMode]
  );

  return (
    <Suspense fallback={<LoadingFallback />}>
      <ThemeProvider theme={theme}>
        <CssBaseline enableColorScheme />
        {isRoundedMacOSWindow && (
          <GlobalStyles
            styles={{
              "html, body, #root": { backgroundColor: "transparent" },
            }}
          />
        )}
        {/* Paint the resolved theme background so windows with a fixed native
            background color never show through. */}
        <Box
          sx={{
            minHeight: "100vh",
            bgcolor: isRoundedMacOSWindow
              ? "transparent"
              : "background.default",
          }}
        >
          <HashRouter>
            <Routes>
              <Route path="/add-drive" element={<AddDrive />} />
              <Route path="/reauthorize/:driveId/:siteUrl/:driveName" element={<AddDrive mode="reauthorize" />} />
              <Route path="/popup" element={<Popup />} />
              <Route path="/settings" element={<Settings />} />
            </Routes>
          </HashRouter>
        </Box>
      </ThemeProvider>
    </Suspense>
  );
}

export default App;
