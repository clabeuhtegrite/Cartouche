//! The questions the installer asks the person at the window while it
//! works, the two-factor code and the certificates to revoke, and the
//! window's answers.
//!
//! The question goes to the window as an event ("2fa-required",
//! "max-certs-reached"), which Tauri always hands to the window. The answer
//! comes back by a command, never as an event: Tauri hands an event to Rust
//! only if its table of listeners is free at that instant. When another
//! thread holds it, listening, unlistening or sending an event of its own
//! (the installer sends one for each line of its log), the event waits in a
//! queue that only a later event with a listener in Rust empties, and that
//! may never come. The code the person typed was lost that way, and the
//! sign-in failed two minutes later. A command goes straight to its
//! function.

use std::{
    sync::{
        Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

use tauri::State;
use tokio::sync::oneshot;
use tracing::warn;

/// How long the installer waits for the code before the sign-in fails.
pub const TWO_FACTOR_TIMEOUT: Duration = Duration::from_secs(120);
/// How long it waits for the certificates to revoke before the install fails.
pub const MAX_CERTS_TIMEOUT: Duration = Duration::from_secs(300);

/// The questions the window answers, one of each at a time.
pub struct Questions {
    pub two_factor: Question<String>,
    pub max_certs: Question<Option<Vec<String>>>,
}

impl Default for Questions {
    fn default() -> Self {
        Questions {
            two_factor: Question::new("the two-factor code"),
            max_certs: Question::new("the certificates to revoke"),
        }
    }
}

/// A question the installer may be asking, and where its answer goes.
pub struct Question<T> {
    what: &'static str,
    waiting: Mutex<Option<(u64, oneshot::Sender<T>)>>,
    next_id: AtomicU64,
}

/// The installer waiting for the answer to the question it asks. Once it is
/// dropped, an answer goes nowhere.
pub struct Waiting<'a, T> {
    question: &'a Question<T>,
    id: u64,
    receiver: oneshot::Receiver<T>,
}

#[derive(Debug, thiserror::Error)]
pub enum NoAnswer {
    #[error("No answer about {0} came from the window within {1} seconds")]
    Timeout(&'static str, u64),
    #[error("The installer asked again for {0} before an answer came")]
    AskedAgain(&'static str),
}

impl<T> Question<T> {
    fn new(what: &'static str) -> Self {
        Question { what, waiting: Mutex::new(None), next_id: AtomicU64::new(0) }
    }

    /// Waits for the answer from now on: call it before asking, so that no
    /// answer comes before. Only the last question asked is answered.
    pub fn ask(&self) -> Waiting<'_, T> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (sender, receiver) = oneshot::channel();
        *self.waiting.lock().unwrap() = Some((id, sender));
        Waiting { question: self, id, receiver }
    }

    /// Hands the window's answer to the question being asked: false when
    /// none is, as when the installer stopped waiting.
    pub fn answer(&self, answer: T) -> bool {
        let waiting = self.waiting.lock().unwrap().take();
        let taken = waiting.is_some_and(|(_, sender)| sender.send(answer).is_ok());
        if !taken {
            warn!("An answer about {} came while the installer was not asking for it", self.what);
        }
        taken
    }
}

impl<T> Waiting<'_, T> {
    /// The window's answer, or why none came.
    pub async fn answer(mut self, timeout: Duration) -> Result<T, NoAnswer> {
        match tokio::time::timeout(timeout, &mut self.receiver).await {
            Ok(Ok(answer)) => Ok(answer),
            Ok(Err(_)) => Err(NoAnswer::AskedAgain(self.question.what)),
            Err(_) => Err(NoAnswer::Timeout(self.question.what, timeout.as_secs())),
        }
    }
}

impl<T> Drop for Waiting<'_, T> {
    fn drop(&mut self) {
        let mut waiting = self.question.waiting.lock().unwrap();
        if waiting.as_ref().is_some_and(|(id, _)| *id == self.id) {
            *waiting = None;
        }
    }
}

/// The window's answer to "2fa-required": the code the person typed.
/// Whether the installer was asking for one.
#[tauri::command]
pub fn answer_two_factor_code(questions: State<'_, Questions>, code: String) -> bool {
    questions.two_factor.answer(code)
}

/// The window's answer to "max-certs-reached": the serial numbers of the
/// certificates to revoke, or none to cancel. Whether the installer was
/// asking.
#[tauri::command]
pub fn answer_max_certs(questions: State<'_, Questions>, revoke: Option<Vec<String>>) -> bool {
    questions.max_certs.answer(revoke)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block_on<F: std::future::Future>(future: F) -> F::Output {
        tauri::async_runtime::block_on(future)
    }

    #[test]
    fn hands_the_answer_to_the_question_asked() {
        let question = Question::<String>::new("a code");
        let waiting = question.ask();
        assert!(question.answer("123456".into()));
        assert_eq!(block_on(waiting.answer(Duration::from_secs(5))).unwrap(), "123456");
        // Asked once, answered once.
        assert!(!question.answer("654321".into()));
    }

    #[test]
    fn takes_no_answer_when_nothing_is_asked() {
        let question = Question::<String>::new("a code");
        assert!(!question.answer("123456".into()));
        // A late answer is not kept for the next question.
        let waiting = question.ask();
        let error = block_on(waiting.answer(Duration::from_millis(50))).unwrap_err();
        assert!(matches!(error, NoAnswer::Timeout(..)), "{error}");
    }

    #[test]
    fn stops_waiting_once_the_installer_gives_up() {
        let question = Question::<String>::new("a code");
        let waiting = question.ask();
        let error = block_on(waiting.answer(Duration::from_millis(50))).unwrap_err();
        assert!(matches!(error, NoAnswer::Timeout("a code", _)), "{error}");
        assert!(!question.answer("123456".into()), "taken after the installer stopped waiting");
        assert_eq!(
            NoAnswer::Timeout("the two-factor code", TWO_FACTOR_TIMEOUT.as_secs()).to_string(),
            "No answer about the two-factor code came from the window within 120 seconds"
        );
    }

    #[test]
    fn answers_only_the_last_question_asked() {
        let question = Question::<String>::new("a code");
        let first = question.ask();
        let second = question.ask();
        let error = block_on(first.answer(Duration::from_secs(5))).unwrap_err();
        assert!(matches!(error, NoAnswer::AskedAgain(_)), "{error}");
        // The first one, dropped, leaves the second one waiting.
        assert!(question.answer("123456".into()));
        assert_eq!(block_on(second.answer(Duration::from_secs(5))).unwrap(), "123456");
    }
}
