use serde::Serialize;
use tauri::{Emitter, Runtime, Window};

use crate::error::AppError;

pub struct Operation<'a, R: Runtime> {
    id: String,
    window: &'a Window<R>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct OperationUpdate<'a> {
    update_type: &'a str,
    step_id: &'a str,
    extra_details: Option<AppError>,
    /// For "progress": how much of the step is done, from 0 to 1.
    progress: Option<f32>,
}

impl<'a, R: Runtime> Operation<'a, R> {
    pub fn new(id: String, window: &'a Window<R>) -> Operation<'a, R> {
        Operation { id, window }
    }

    fn emit(
        &self,
        update_type: &str,
        step_id: &str,
        extra_details: Option<AppError>,
        progress: Option<f32>,
    ) -> Result<(), AppError> {
        self.window
            .emit(
                &format!("operation_{}", self.id),
                OperationUpdate {
                    update_type,
                    step_id,
                    extra_details,
                    progress,
                },
            )
            .map_err(|e| AppError::OperationUpdate(e.to_string()))
    }

    pub fn move_on(&self, old_id: &str, new_id: &str) -> Result<(), AppError> {
        self.complete(old_id)?;
        self.start(new_id)
    }

    pub fn start(&self, id: &str) -> Result<(), AppError> {
        self.emit("started", id, None, None)
    }

    pub fn complete(&self, id: &str) -> Result<(), AppError> {
        self.emit("finished", id, None, None)
    }

    /// A function that reports how much of the step `id` is done, for the
    /// work that runs in isideload or in a download.
    pub fn progress_reporter(&self, id: &str) -> impl Fn(f32) -> std::future::Ready<()> + use<R> {
        let window = self.window.clone();
        let event = format!("operation_{}", self.id);
        let step_id = id.to_string();
        move |fraction: f32| {
            let _ = window.emit(
                &event,
                OperationUpdate {
                    update_type: "progress",
                    step_id: &step_id,
                    extra_details: None,
                    progress: Some(fraction.clamp(0.0, 1.0)),
                },
            );
            std::future::ready(())
        }
    }

    pub fn fail<T>(&self, id: &str, error: AppError) -> Result<T, AppError> {
        self.emit("failed", id, Some(error.clone()), None)?;
        Err(error)
    }

    pub fn fail_if_err<T>(&self, id: &str, res: Result<T, AppError>) -> Result<T, AppError> {
        match res {
            Ok(t) => Ok(t),
            Err(e) => self.fail::<T>(id, e),
        }
    }
}
