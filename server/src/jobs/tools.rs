//! External tools for formats Rust can't decode itself: ffmpeg (videos) and libheif (HEIC).
//! They are started directly, never through a shell, with the lowest CPU and disk priority
//! (`nice -n 19`, `ionice -c 3` on Linux), a time limit, and killed when the job is cancelled.

use std::{
    ffi::OsString,
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};

use tokio::{io::AsyncReadExt, process::Command};

/// Where the tools are, if installed.
#[derive(Debug, Clone, Default)]
pub struct Tools {
    pub ffmpeg: Option<PathBuf>,
    pub ffprobe: Option<PathBuf>,
    /// `heif-dec` (libheif 1.17+) or the older `heif-convert`.
    pub heif_dec: Option<PathBuf>,
    pub heif_enc: Option<PathBuf>,
    nice: Option<PathBuf>,
    ionice: Option<PathBuf>,
}

#[derive(Debug, thiserror::Error)]
pub enum ToolError {
    #[error("{0} is not installed")]
    Missing(&'static str),
    #[error("{tool} failed: {message}")]
    Failed { tool: String, message: String },
    #[error("{0} took too long and was stopped")]
    Timeout(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

fn find(names: &[&str]) -> Option<PathBuf> {
    let mut folders: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).collect())
        .unwrap_or_default();
    for extra in ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"] {
        folders.push(PathBuf::from(extra));
    }
    names.iter().find_map(|name| {
        folders
            .iter()
            .map(|folder| folder.join(name))
            .find(|candidate| candidate.is_file())
    })
}

impl Tools {
    pub fn find() -> Self {
        Self {
            ffmpeg: find(&["ffmpeg"]),
            ffprobe: find(&["ffprobe"]),
            heif_dec: find(&["heif-dec", "heif-convert"]),
            heif_enc: find(&["heif-enc"]),
            nice: find(&["nice"]),
            ionice: if cfg!(target_os = "linux") {
                find(&["ionice"])
            } else {
                None
            },
        }
    }

    /// Runs `program` with `args` at the lowest priority. Output is thrown away; the end of the
    /// error output is kept for the error message.
    pub async fn run(
        &self,
        name: &str,
        program: &Path,
        args: &[OsString],
        timeout: Duration,
    ) -> Result<(), ToolError> {
        let mut command = match &self.nice {
            Some(nice) => {
                let mut command = Command::new(nice);
                command.arg("-n").arg("19");
                if let Some(ionice) = &self.ionice {
                    command.arg(ionice).arg("-c").arg("3");
                }
                command.arg(program);
                command
            }
            None => Command::new(program),
        };
        command
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let mut child = command.spawn()?;
        let mut stderr = child.stderr.take();
        let finished = tokio::time::timeout(timeout, async {
            let mut output = Vec::new();
            if let Some(stderr) = stderr.as_mut() {
                let _ = stderr.read_to_end(&mut output).await;
            }
            (child.wait().await, output)
        })
        .await;
        match finished {
            Err(_) => Err(ToolError::Timeout(name.to_string())),
            Ok((Ok(status), _)) if status.success() => Ok(()),
            Ok((Ok(status), output)) => {
                let text = String::from_utf8_lossy(&output);
                let tail: String = text.lines().rev().take(3).collect::<Vec<_>>().join(" / ");
                Err(ToolError::Failed {
                    tool: name.to_string(),
                    message: format!("{status}: {tail}"),
                })
            }
            Ok((Err(error), _)) => Err(ToolError::Io(error)),
        }
    }
}

impl Tools {
    /// Runs a quick tool (like `ffprobe`) and returns what it printed.
    pub async fn output(
        &self,
        program: &Path,
        args: &[OsString],
        timeout: Duration,
    ) -> Result<String, ToolError> {
        let mut command = Command::new(program);
        command
            .args(args)
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        match tokio::time::timeout(timeout, command.output()).await {
            Err(_) => Err(ToolError::Timeout(program.display().to_string())),
            Ok(Ok(output)) if output.status.success() => {
                Ok(String::from_utf8_lossy(&output.stdout).into_owned())
            }
            Ok(Ok(output)) => Err(ToolError::Failed {
                tool: program.display().to_string(),
                message: output.status.to_string(),
            }),
            Ok(Err(error)) => Err(ToolError::Io(error)),
        }
    }
}

pub fn args(items: &[&(dyn AsRef<std::ffi::OsStr> + Sync)]) -> Vec<OsString> {
    items
        .iter()
        .map(|item| item.as_ref().to_os_string())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn tools_run_without_a_shell_and_report_failures() {
        let tools = Tools::find();
        let Some(sh) = find(&["sh"]) else { return };
        tools
            .run(
                "sh",
                &sh,
                &args(&[&"-c", &"exit 0"]),
                Duration::from_secs(5),
            )
            .await
            .unwrap();
        let failed = tools
            .run(
                "sh",
                &sh,
                &args(&[&"-c", &"echo broken >&2; exit 3"]),
                Duration::from_secs(5),
            )
            .await
            .unwrap_err();
        assert!(failed.to_string().contains("broken"), "{failed}");
        let slow = tools
            .run(
                "sh",
                &sh,
                &args(&[&"-c", &"sleep 5"]),
                Duration::from_millis(200),
            )
            .await
            .unwrap_err();
        assert!(matches!(slow, ToolError::Timeout(_)));
    }
}
