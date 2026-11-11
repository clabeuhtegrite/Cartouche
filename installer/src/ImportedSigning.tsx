import { open } from "@tauri-apps/plugin-dialog";
import { useTranslation } from "react-i18next";

export type ImportedSigningInput = {
  p12Path: string;
  profilePath: string;
  password: string;
};

export function ImportedSigning({ value, onChange }: {
  value: ImportedSigningInput;
  onChange: (value: ImportedSigningInput) => void;
}) {
  const { t } = useTranslation();
  async function choose(field: "p12Path" | "profilePath", extension: string) {
    const path = await open({ multiple: false, filters: [{ name: extension, extensions: [extension] }] });
    if (typeof path === "string") onChange({ ...value, [field]: path });
  }
  return <div className="credentials-container">
    <p>{t("signing.hint")}</p>
    <button onClick={() => choose("p12Path", "p12")}>{t("signing.choose_p12")}</button>
    {value.p12Path && <span>{value.p12Path.split(/[\\/]/).pop()}</span>}
    <button onClick={() => choose("profilePath", "mobileprovision")}>{t("signing.choose_profile")}</button>
    {value.profilePath && <span>{value.profilePath.split(/[\\/]/).pop()}</span>}
    <label>
      {t("signing.password")}
      <input type="password" autoComplete="off" value={value.password}
        onChange={event => onChange({ ...value, password: event.target.value })} />
    </label>
    <p className="step-hint">{t("signing.limitations")}</p>
  </div>;
}
