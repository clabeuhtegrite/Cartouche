import { useCallback, useEffect, useRef, useState } from "react";
import "./App.css";
import { AppleID } from "./AppleID";
import { ImportedSigning, ImportedSigningInput } from "./ImportedSigning";
import { Device, DeviceInfo } from "./Device";
import { invoke } from "@tauri-apps/api/core";
import { open as openFileDialog } from "@tauri-apps/plugin-dialog";
import { openUrl } from "@tauri-apps/plugin-opener";
import {
  installCartoucheFromFileOperation,
  installCartoucheOperation,
  Operation,
  OperationState,
  OperationUpdate,
  placeCartouchePairingOperation,
} from "./components/operations";
import { listen } from "@tauri-apps/api/event";
import OperationView from "./components/OperationView";
import { toast } from "sonner";
import { Modal } from "./components/Modal";
import { Certificates } from "./pages/Certificates";
import { AppIds } from "./pages/AppIds";
import { Settings } from "./pages/Settings";
import { getVersion } from "@tauri-apps/api/app";
import logo from "./assets/cartouche.svg";
import { GlassCard } from "./components/GlassCard";
import { useTranslation } from "react-i18next";
import { usePlatform } from "./PlatformContext";
import { useStore } from "./StoreContext";
import i18n, { defaultLanguage } from "./i18next";

const REPOSITORY_URL = "https://github.com/clabeuhtegrite/Cartouche";

/// The newest Cartouche, as its source lists it.
type Release = {
  version: string;
  date: string;
  size: number;
};

/// Cartouche as the iPhone lists it.
type InstalledCartouche = {
  bundleId: string;
  version: string | null;
};

const StepTitle = ({
  number,
  title,
  done,
}: {
  number: number;
  title: string;
  done: boolean;
}) => (
  <div className="step-title">
    <span className={"step-number" + (done ? " done" : "")} aria-hidden="true">
      {done ? "✓" : number}
    </span>
    <h2>{title}</h2>
  </div>
);

function App() {
  const { t } = useTranslation();

  const [operationState, setOperationState] = useState<OperationState | null>(
    null,
  );
  const [loggedInAs, setLoggedInAs] = useState<string | null>(null);
  const [signingMode, setSigningMode] = useState<"imported" | "account">("imported");
  const [importedSigning, setImportedSigning] = useState<ImportedSigningInput>({ p12Path: "", profilePath: "", password: "" });
  const signingReady = signingMode === "imported"
    ? Boolean(importedSigning.p12Path && importedSigning.profilePath) : loggedInAs !== null;
  const [selectedDevice, setSelectedDevice] = useState<DeviceInfo | null>(null);
  const [openModal, setOpenModal] = useState<
    null | "settings" | "certificates" | "appids"
  >(null);
  const [version, setVersion] = useState<string>("");
  const [release, setRelease] = useState<Release | null>(null);
  const [releaseFailed, setReleaseFailed] = useState<boolean>(false);
  const [installed, setInstalled] = useState<InstalledCartouche | null>(null);

  const refreshDevicesRef = useRef<(() => void) | null>(null);

  const [noKeyringAvailable, setNoKeyringAvailable] = useState<boolean>(false);
  const { platform } = usePlatform();

  // Settings shows only in a dialog: the choices it keeps apply from here.
  const [lang] = useStore<string>("lang", defaultLanguage());
  useEffect(() => {
    i18n.changeLanguage(lang);
  }, [lang]);

  const checkKeyring = useCallback(async () => {
    try {
      const available = await invoke<boolean>("keyring_available");
      setNoKeyringAvailable(!available);
    } catch (e) {
      console.error("Unable to check keyring availability:", e);
      setNoKeyringAvailable(true);
    }
  }, []);

  const [overrideKeyring] = useStore<boolean>("overrideKeyring", false);
  useEffect(() => {
    (async () => {
      await invoke("force_disable_keyring", { force: overrideKeyring });
      checkKeyring();
    })();
  }, [overrideKeyring, checkKeyring]);

  useEffect(() => {
    getVersion().then(setVersion);
  }, []);

  const loadRelease = useCallback(() => {
    setReleaseFailed(false);
    invoke<Release>("cartouche_release")
      .then(setRelease)
      .catch((e) => {
        console.error("Unable to read Cartouche's releases:", e);
        setReleaseFailed(true);
      });
  }, []);

  useEffect(() => {
    loadRelease();
  }, [loadRelease]);

  const loadInstalled = useCallback(async () => {
    if (!selectedDevice) {
      setInstalled(null);
      return;
    }
    try {
      setInstalled(
        await invoke<InstalledCartouche | null>("installed_cartouche"),
      );
    } catch (e) {
      console.error("Unable to list the iPhone's apps:", e);
      setInstalled(null);
    }
  }, [selectedDevice]);

  useEffect(() => {
    loadInstalled();
  }, [loadInstalled]);

  const shortcutLabel = useCallback(
    (mac: string, windows: string, linux?: string) => {
      if (platform === "mac") return mac;
      if (platform === "linux") return linux ?? windows;
      return windows;
    },
    [platform],
  );

  const startOperation = useCallback(
    async (
      operation: Operation,
      params: { [key: string]: any },
    ): Promise<void> => {
      setOperationState({
        current: operation,
        started: [],
        failed: [],
        completed: [],
        progress: {},
      });
      const unlistenFn = await listen<OperationUpdate>(
        "operation_" + operation.id,
        (event) => {
          const update = event.payload;
          setOperationState((old) => {
            if (old == null) return null;
            switch (update.updateType) {
              case "started":
                return { ...old, started: [...old.started, update.stepId] };
              case "finished":
                return {
                  ...old,
                  completed: [...old.completed, update.stepId],
                };
              case "progress":
                return {
                  ...old,
                  progress: { ...old.progress, [update.stepId]: update.progress },
                };
              case "failed":
                return {
                  ...old,
                  failed: [
                    ...old.failed,
                    { stepId: update.stepId, extraDetails: update.extraDetails },
                  ],
                };
            }
          });
        },
      );
      try {
        await invoke(operation.id + "_operation", params);
      } finally {
        unlistenFn();
        loadInstalled();
      }
    },
    [setOperationState, loadInstalled],
  );

  const ensureReady = useCallback((): boolean => {
    if (!selectedDevice) {
      toast.error(t("app.must_select_device"));
      return false;
    }
    if (!signingReady) {
      toast.error(t(signingMode === "imported" ? "signing.needs_files" : "app.must_be_logged_in"));
      return false;
    }
    return true;
  }, [selectedDevice, signingReady, signingMode, t]);

  const ensureSelectedDevice = useCallback((): boolean => {
    if (selectedDevice) return true;
    toast.error(t("app.must_select_device"));
    return false;
  }, [selectedDevice, t]);

  const install = useCallback(() => {
    if (!ensureReady()) return;
    startOperation(installCartoucheOperation, { ipaPath: null, importedSigning: signingMode === "imported" ? importedSigning : null }).catch((e) =>
      console.error(e?.message ?? e),
    );
  }, [ensureReady, startOperation, signingMode, importedSigning]);

  const installFromFile = useCallback(async () => {
    if (!ensureReady()) return;
    const path = await openFileDialog({
      multiple: false,
      filters: [{ name: t("app.ipa_files"), extensions: ["ipa"] }],
    });
    if (!path) return;
    startOperation(installCartoucheFromFileOperation, {
      ipaPath: path as string,
      importedSigning: signingMode === "imported" ? importedSigning : null,
    }).catch((e) => console.error(e?.message ?? e));
  }, [ensureReady, startOperation, t, signingMode, importedSigning]);

  const placePairing = useCallback(() => {
    if (!ensureSelectedDevice()) return;
    startOperation(placeCartouchePairingOperation, {}).catch((e) =>
      console.error(e?.message ?? e),
    );
  }, [ensureSelectedDevice, startOperation]);

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === undefined) return;
      const key = event.key.toLowerCase();
      const primaryPressed = platform === "mac" ? event.metaKey : event.ctrlKey;
      if (!primaryPressed || event.shiftKey) return;
      if (key === "r") {
        event.preventDefault();
        refreshDevicesRef.current?.();
      } else if (key === ",") {
        event.preventDefault();
        setOpenModal("settings");
      }
    };

    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [platform]);

  const upToDate =
    installed !== null &&
    release !== null &&
    installed.version === release.version;
  const ready = selectedDevice !== null && signingReady;

  return (
    <main className="workspace">
      <header className="workspace-header">
        <div className="header-left">
          <div className="title-block">
            <img src={logo} alt="" className="logo" />
            <div>
              <h1 className="title">{t("app.title")}</h1>
              <p className="subtitle">{t("subtitle")}</p>
            </div>
          </div>
          <span className="version-pill">
            {t("version")} {version}
          </span>
        </div>
        <div className="header-actions">
          <button
            className="toolbar-button"
            onClick={() => setOpenModal("settings")}
          >
            {t("app.settings")}
          </button>
          <button
            className="toolbar-button"
            onClick={async () => {
              try {
                await openUrl(REPOSITORY_URL);
              } catch (error) {
                console.error("Failed to open GitHub link", error);
                toast.error(t("app.open_github_failed"));
              }
            }}
          >
            {t("app.github")}
          </button>
        </div>
      </header>
      <div className="steps">
        <section className="step">
          <StepTitle
            number={1}
            title={t("steps.iphone_title")}
            done={selectedDevice !== null}
          />
          <p className="step-hint">{t("steps.iphone_hint")}</p>
          <GlassCard className="panel">
            <Device
              selectedDevice={selectedDevice}
              setSelectedDevice={setSelectedDevice}
              registerRefresh={(fn) => {
                refreshDevicesRef.current = fn ?? null;
              }}
            />
          </GlassCard>
        </section>
        <section className="step">
          <StepTitle
            number={2}
            title={t("signing.title")}
            done={signingReady}
          />
          <p className="step-hint">{t("signing.choice_hint")}</p>
          <GlassCard className="panel">
            <div className="action-row">
              <button aria-pressed={signingMode === "imported"} onClick={() => setSigningMode("imported")}>{t("signing.imported")}</button>
              <button aria-pressed={signingMode === "account"} onClick={() => setSigningMode("account")}>{t("steps.apple_id_title")}</button>
            </div>
            {signingMode === "imported" ? <ImportedSigning value={importedSigning} onChange={setImportedSigning} /> :
            <AppleID
              loggedInAs={loggedInAs}
              setLoggedInAs={setLoggedInAs}
              noKeyringAvailable={noKeyringAvailable}
            />}
          </GlassCard>
        </section>
        <section className="step">
          <StepTitle number={3} title={t("steps.install_title")} done={upToDate} />
          <p className="step-hint">{t("steps.install_hint")}</p>
          <GlassCard className="panel install-panel">
            <div className="install-status">
              {release ? (
                <p>{t("install.latest", { version: release.version })}</p>
              ) : releaseFailed ? (
                <p>
                  {t("install.release_failed")}{" "}
                  <span
                    className="error-link"
                    role="button"
                    tabIndex={0}
                    onClick={loadRelease}
                  >
                    {t("common.retry")}
                  </span>
                </p>
              ) : (
                <p className="text-muted">{t("install.release_loading")}</p>
              )}
              {selectedDevice && (
                <p className="text-muted">
                  {installed
                    ? t("install.installed", {
                        version: installed.version ?? "?",
                      })
                    : t("install.not_installed")}
                </p>
              )}
            </div>
            <button
              className="primary-button"
              disabled={!ready || release === null}
              onClick={install}
            >
              {installed
                ? t("install.update_button", { version: release?.version ?? "" })
                : t("install.button", { version: release?.version ?? "" })}
            </button>
            {!ready && <p className="step-hint">{t("signing.needs_ready")}</p>}
            <div className="secondary-actions">
              <button
                disabled={selectedDevice === null || installed === null}
                onClick={placePairing}
              >
                {t("install.place_pairing")}
              </button>
              <button disabled={!ready} onClick={installFromFile}>
                {t("install.from_file")}
              </button>
            </div>
          </GlassCard>
        </section>
      </div>
      <p className="credits">{t("app.credits")}</p>
      {operationState && (
        <OperationView
          operationState={operationState}
          closeMenu={() => setOperationState(null)}
        />
      )}
      <Modal
        isOpen={openModal === "settings"}
        close={() => setOpenModal(null)}
      >
        <h2 style={{ marginTop: 0 }}>{t("app.settings")}</h2>
        <Settings
          ensureSelectedDevice={ensureSelectedDevice}
          setSelectedDevice={setSelectedDevice}
          platform={platform}
          shortcutLabel={shortcutLabel}
          openCertificates={() => {
            if (!loggedInAs) {
              toast.error(t("app.must_be_logged_in"));
              return;
            }
            setOpenModal("certificates");
          }}
          openAppIds={() => {
            if (!loggedInAs) {
              toast.error(t("app.must_be_logged_in"));
              return;
            }
            setOpenModal("appids");
          }}
        />
      </Modal>
      <Modal
        isOpen={openModal === "certificates"}
        close={() => setOpenModal(null)}
      >
        <Certificates />
      </Modal>
      <Modal isOpen={openModal === "appids"} close={() => setOpenModal(null)}>
        <AppIds />
      </Modal>
    </main>
  );
}

export default App;
