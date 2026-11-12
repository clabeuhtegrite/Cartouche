import { AppError } from "../errors";

export type Operation = {
  id: string;
  titleKey: string;
  successMessageKey?: string;
  successTitleKey?: string;
  steps: OperationStep[];
};

export type OperationStep = {
  id: string;
  titleKey: string;
};

export type OperationState = {
  current: Operation;
  completed: string[];
  started: string[];
  failed: {
    stepId: string;
    extraDetails: AppError;
  }[];
  /// How much of each running step is done, from 0 to 1, when it says.
  progress: { [stepId: string]: number };
};

type OperationInfoUpdate = {
  updateType: "started" | "finished";
  stepId: string;
};

type OperationProgressUpdate = {
  updateType: "progress";
  stepId: string;
  progress: number;
};

type OperationFailedUpdate = {
  updateType: "failed";
  stepId: string;
  extraDetails: AppError;
};

export type OperationUpdate =
  | OperationInfoUpdate
  | OperationProgressUpdate
  | OperationFailedUpdate;

export const installCartoucheOperation: Operation = {
  id: "install_cartouche",
  titleKey: "operations.install_title",
  successTitleKey: "operations.install_success_title",
  successMessageKey: "operations.install_success_message",
  steps: [
    {
      id: "download",
      titleKey: "operations.install_step_download",
    },
    {
      id: "install",
      titleKey: "operations.install_step_install",
    },
    {
      id: "pairing",
      titleKey: "operations.install_step_pairing",
    },
  ],
};

export const installCartoucheFromFileOperation: Operation = {
  ...installCartoucheOperation,
  steps: [
    {
      id: "download",
      titleKey: "operations.install_step_check",
    },
    ...installCartoucheOperation.steps.slice(1),
  ],
};

export const importedInstallCartoucheOperation: Operation = {
  ...installCartoucheOperation,
  successMessageKey: "signing.success_message",
  steps: installCartoucheOperation.steps.map(step => ({
    ...step,
    titleKey: step.id === "install" ? "signing.step_install"
      : step.id === "pairing" ? "signing.step_handoff" : step.titleKey,
  })),
};

export const importedInstallCartoucheFromFileOperation: Operation = {
  ...importedInstallCartoucheOperation,
  steps: [{ id: "download", titleKey: "operations.install_step_check" },
    ...importedInstallCartoucheOperation.steps.slice(1)],
};

export const placeCartouchePairingOperation: Operation = {
  id: "place_cartouche_pairing",
  titleKey: "operations.pairing_title",
  successTitleKey: "operations.pairing_success_title",
  successMessageKey: "operations.pairing_success_message",
  steps: [
    {
      id: "pairing",
      titleKey: "operations.install_step_pairing",
    },
  ],
};
