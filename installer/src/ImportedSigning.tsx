import { open } from "@tauri-apps/plugin-dialog";
import { invoke } from "@tauri-apps/api/core";
import { useRef, useState } from "react";
import { useTranslation } from "react-i18next";

export type ImportedSigningInput = {
  p12Path: string;
  profilePath: string;
  password: string;
};

export type SigningProfileSummary = {
  profilePath: string;
  increasedMemoryLimit: boolean;
  sha256: string;
  // The app the profile is for, when it is not Cartouche.
  otherApp: string | null;
};

export function ImportedSigning({ value, onChange, summary, onProfileChecked }: {
  value: ImportedSigningInput;
  onChange: (value: ImportedSigningInput) => void;
  summary: SigningProfileSummary | null;
  onProfileChecked: (summary: SigningProfileSummary | null) => void;
}) {
  const { t } = useTranslation();
  const request = useRef(0);
  const [profileError, setProfileError] = useState(false);
  const [checkingProfile, setCheckingProfile] = useState(false);
  async function choose(field: "p12Path" | "profilePath", extension: string) {
    const path = await open({ multiple: false, filters: [{ name: extension, extensions: [extension] }] });
    if (typeof path !== "string") return;
    onChange({ ...value, [field]: path });
    if (field !== "profilePath") return;
    const current = ++request.current;
    onProfileChecked(null);
    setProfileError(false);
    setCheckingProfile(true);
    try {
      const checked = await invoke<Omit<SigningProfileSummary, "profilePath">>("inspect_signing_profile", { profilePath: path });
      if (current === request.current) onProfileChecked({ ...checked, profilePath: path });
    } catch {
      if (current === request.current) setProfileError(true);
    } finally {
      if (current === request.current) setCheckingProfile(false);
    }
  }
  const fileName = (path: string) => path.split(/[\\/]/).pop();
  // Laid out as the Apple Account's form; what it is for, the step says above.
  return <div className="credentials-container signing-files">
    <div className="file-choice">
      <button type="button" onClick={() => choose("p12Path", "p12")}>{t("signing.choose_p12")}</button>
      {value.p12Path && <span className="chosen-file">{fileName(value.p12Path)}</span>}
    </div>
    <div className="file-choice">
      <button type="button" onClick={() => choose("profilePath", "mobileprovision")}>{t("signing.choose_profile")}</button>
      {value.profilePath && <span className="chosen-file">{fileName(value.profilePath)}</span>}
    </div>
    {checkingProfile && <p role="status" className="step-hint">{t("signing.profile_checking")}</p>}
    {profileError && <p role="alert" className="signing-alert">{t("signing.profile_invalid")}</p>}
    {summary?.profilePath === value.profilePath && summary.otherApp &&
      <p role="alert" className="signing-alert">{t("signing.profile_other_app", { app: summary.otherApp })}</p>}
    {summary?.profilePath === value.profilePath && !summary.otherApp && !summary.increasedMemoryLimit &&
      <p role="alert" className="signing-alert warning">{t("signing.no_memory_limit")}</p>}
    <label className="signing-password">
      {t("signing.password")}
      <input type="password" autoComplete="off" value={value.password}
        onChange={event => onChange({ ...value, password: event.target.value })} />
    </label>
    <p className="step-hint">{t("signing.limitations")}</p>
  </div>;
}
