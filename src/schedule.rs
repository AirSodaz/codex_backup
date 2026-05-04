use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{bail, Context, Result};

use crate::restic::{quoted_command_line, CommandSpec};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SystemdUnitFiles {
    pub service: String,
    pub timer: String,
}

pub fn windows_install_command(
    task_name: &str,
    time: &str,
    executable: &Path,
    env_file: &Path,
) -> CommandSpec {
    let task_run = quoted_command_line(
        executable,
        &["backup", "--env-file", &env_file.to_string_lossy()],
    );
    CommandSpec::new(
        "schtasks.exe",
        vec![
            "/Create".to_string(),
            "/TN".to_string(),
            task_name.to_string(),
            "/SC".to_string(),
            "DAILY".to_string(),
            "/ST".to_string(),
            time.to_string(),
            "/TR".to_string(),
            task_run,
            "/F".to_string(),
        ],
    )
}

pub fn windows_remove_command(task_name: &str) -> CommandSpec {
    CommandSpec::new(
        "schtasks.exe",
        vec![
            "/Delete".to_string(),
            "/TN".to_string(),
            task_name.to_string(),
            "/F".to_string(),
        ],
    )
}

pub fn launch_agent_plist(label: &str, time: &str, executable: &Path, env_file: &Path) -> String {
    let (hour, minute) = parse_time(time).unwrap_or((3, 0));
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{}</string>
    <string>backup</string>
    <string>--env-file</string>
    <string>{}</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>{}</integer>
    <key>Minute</key>
    <integer>{}</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>{}.out.log</string>
  <key>StandardErrorPath</key>
  <string>{}.err.log</string>
</dict>
</plist>
"#,
        xml_escape(label),
        xml_escape(&executable.display().to_string()),
        xml_escape(&env_file.display().to_string()),
        hour,
        minute,
        xml_escape(label),
        xml_escape(label)
    )
}

pub fn systemd_unit_files(
    service_name: &str,
    time: &str,
    executable: &Path,
    env_file: &Path,
) -> SystemdUnitFiles {
    let service = format!(
        r#"[Unit]
Description=Back up Codex history and SQLite snapshots to Cloudflare R2 with Restic

[Service]
Type=oneshot
ExecStart={} backup --env-file {}
"#,
        executable.display(),
        env_file.display()
    );

    let timer = format!(
        r#"[Unit]
Description=Run {service_name} daily

[Timer]
OnCalendar=*-*-* {time}:00
Persistent=true

[Install]
WantedBy=timers.target
"#
    );

    SystemdUnitFiles { service, timer }
}

pub fn install_schedule(
    task_name: &str,
    time: &str,
    executable: &Path,
    env_file: &Path,
) -> Result<()> {
    if cfg!(target_os = "windows") {
        run_spec(&windows_install_command(
            task_name, time, executable, env_file,
        ))
    } else if cfg!(target_os = "macos") {
        install_launch_agent(task_name, time, executable, env_file)
    } else if cfg!(target_os = "linux") {
        install_systemd_user_timer(task_name, time, executable, env_file)
    } else {
        bail!("schedule install is not supported on this platform")
    }
}

pub fn remove_schedule(task_name: &str) -> Result<()> {
    if cfg!(target_os = "windows") {
        run_spec(&windows_remove_command(task_name))
    } else if cfg!(target_os = "macos") {
        let plist_path = launch_agents_dir()?.join(format!("{task_name}.plist"));
        if plist_path.exists() {
            let _ = Command::new("launchctl")
                .args(["unload", "-w", &plist_path.display().to_string()])
                .status();
            fs::remove_file(&plist_path)
                .with_context(|| format!("failed to remove {}", plist_path.display()))?;
        }
        Ok(())
    } else if cfg!(target_os = "linux") {
        let config_dir = systemd_user_dir()?;
        let service = format!("{task_name}.service");
        let timer = format!("{task_name}.timer");
        let _ = Command::new("systemctl")
            .args(["--user", "disable", "--now", &timer])
            .status();
        for path in [config_dir.join(&service), config_dir.join(&timer)] {
            if path.exists() {
                fs::remove_file(&path)
                    .with_context(|| format!("failed to remove {}", path.display()))?;
            }
        }
        let _ = Command::new("systemctl")
            .args(["--user", "daemon-reload"])
            .status();
        Ok(())
    } else {
        bail!("schedule remove is not supported on this platform")
    }
}

fn install_launch_agent(label: &str, time: &str, executable: &Path, env_file: &Path) -> Result<()> {
    let plist = launch_agent_plist(label, time, executable, env_file);
    let plist_path = launch_agents_dir()?.join(format!("{label}.plist"));
    if let Some(parent) = plist_path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    fs::write(&plist_path, plist)
        .with_context(|| format!("failed to write {}", plist_path.display()))?;
    run_command(Command::new("launchctl").args(["load", "-w", &plist_path.display().to_string()]))
}

fn install_systemd_user_timer(
    service_name: &str,
    time: &str,
    executable: &Path,
    env_file: &Path,
) -> Result<()> {
    let units = systemd_unit_files(service_name, time, executable, env_file);
    let config_dir = systemd_user_dir()?;
    fs::create_dir_all(&config_dir)
        .with_context(|| format!("failed to create {}", config_dir.display()))?;
    fs::write(
        config_dir.join(format!("{service_name}.service")),
        units.service,
    )?;
    fs::write(
        config_dir.join(format!("{service_name}.timer")),
        units.timer,
    )?;
    run_command(Command::new("systemctl").args(["--user", "daemon-reload"]))?;
    run_command(Command::new("systemctl").args([
        "--user",
        "enable",
        "--now",
        &format!("{service_name}.timer"),
    ]))
}

fn run_spec(spec: &CommandSpec) -> Result<()> {
    run_command(Command::new(&spec.program).args(&spec.args))
}

fn run_command(command: &mut Command) -> Result<()> {
    let output = command
        .output()
        .context("failed to run scheduler command")?;
    if output.status.success() {
        Ok(())
    } else {
        bail!(
            "scheduler command failed: {}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
    }
}

fn parse_time(time: &str) -> Result<(u32, u32)> {
    let Some((hour, minute)) = time.split_once(':') else {
        bail!("time must use HH:MM format");
    };
    let hour = hour.parse::<u32>()?;
    let minute = minute.parse::<u32>()?;
    if hour > 23 || minute > 59 {
        bail!("time must use HH:MM format with valid hour/minute");
    }
    Ok((hour, minute))
}

fn launch_agents_dir() -> Result<PathBuf> {
    let home = std::env::var("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home).join("Library/LaunchAgents"))
}

fn systemd_user_dir() -> Result<PathBuf> {
    if let Ok(config_home) = std::env::var("XDG_CONFIG_HOME") {
        return Ok(PathBuf::from(config_home).join("systemd/user"));
    }
    let home = std::env::var("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home).join(".config/systemd/user"))
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
