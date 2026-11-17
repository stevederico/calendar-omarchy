use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

const FEED_URL: &str = "https://feeds.example.test/cal.ics?token=SECRET-TOKEN-123&q=a\"b";

fn scratch() -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("sd-calendar-it-{}-{nanos}", std::process::id()));
    fs::create_dir_all(dir.join("bin")).unwrap();
    dir
}

fn write_exe(path: &Path, text: &str) {
    fs::write(path, text).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

fn mode(path: &Path) -> u32 {
    fs::metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
fn subscribe_hands_the_feed_url_to_curl_and_the_cloud_script_on_stdin_and_stores_0600_under_0700_dirs(
) {
    let dir = scratch();
    let d = dir.display();
    write_exe(
        &dir.join("bin/curl"),
        &format!(
            "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\" >'{d}/curl-argv'\ncat >'{d}/curl-stdin'\nprintf 'BEGIN:VCALENDAR\\r\\nEND:VCALENDAR\\r\\n'\n"
        ),
    );
    write_exe(
        &dir.join("cloud.sh"),
        &format!("printf '%s\\n' \"$@\" >'{d}/cloud-argv'\ncat >'{d}/cloud-stdin'\nexit 3\n"),
    );
    let path = format!(
        "{}:{}",
        dir.join("bin").display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let out = Command::new(env!("CARGO_BIN_EXE_sd-calendar"))
        .args(["subscribe", "Feed", FEED_URL])
        .env("PATH", path)
        .env("HOME", &dir)
        .env("XDG_STATE_HOME", dir.join("state"))
        .env("SD_CALENDAR_CLOUD_SCRIPT", dir.join("cloud.sh"))
        .env_remove("SD_CALENDAR_ALMANAC_SCRIPT")
        .output()
        .unwrap();
    let read = |name: &str| fs::read_to_string(dir.join(name)).unwrap_or_default();
    let curl_argv = read("curl-argv");
    let curl_stdin = read("curl-stdin");
    let cloud_argv = read("cloud-argv");
    let cloud_stdin = read("cloud-stdin");
    let store = dir.join("state/omarchy/sd-calendar.json");
    let modes = (
        mode(&dir.join("state")),
        mode(&dir.join("state/omarchy")),
        mode(&store),
    );
    let _ = fs::remove_dir_all(&dir);

    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(cloud_argv, "ics\n");
    assert_eq!(cloud_stdin, format!("{FEED_URL}\n"));
    assert!(curl_argv.contains("-K\n-\n"), "{curl_argv}");
    assert!(
        !curl_argv.contains("SECRET-TOKEN-123"),
        "feed url reached curl argv: {curl_argv}"
    );
    assert_eq!(
        curl_stdin,
        "url = \"https://feeds.example.test/cal.ics?token=SECRET-TOKEN-123&q=a\\\"b\"\n"
    );
    assert_eq!(modes, (0o700, 0o700, 0o600));
}
