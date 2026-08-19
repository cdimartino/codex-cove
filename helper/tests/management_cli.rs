use codex_cove::config::support_directory_for_home;
use std::fs;
use std::path::Path;
use std::process::{Command, Output};
use tempfile::tempdir;

fn run(home: &Path, arguments: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_codex-cove"))
        .args(arguments)
        .env("CODEX_COVE_HOME", home)
        .output()
        .unwrap()
}

#[test]
fn uninstall_help_is_read_only() {
    let home = tempdir().unwrap();
    let workspace = support_directory_for_home(home.path()).join("workspace.json");
    fs::create_dir_all(workspace.parent().unwrap()).unwrap();
    fs::write(&workspace, b"workspace sentinel").unwrap();

    for help in ["--help", "-h"] {
        let output = run(home.path(), &["uninstall", help]);
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("usage: codex-cove"), "{stdout}");
        assert!(stdout.contains("uninstall"), "{stdout}");
    }
    assert_eq!(fs::read(workspace).unwrap(), b"workspace sentinel");
}

#[test]
fn uninstall_rejects_unknown_arguments_without_mutating() {
    let home = tempdir().unwrap();
    let workspace = support_directory_for_home(home.path()).join("workspace.json");
    fs::create_dir_all(workspace.parent().unwrap()).unwrap();
    fs::write(&workspace, b"workspace sentinel").unwrap();

    let output = run(home.path(), &["uninstall", "--keep-setting"]);

    assert!(!output.status.success());
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("unknown uninstall argument --keep-setting")
    );
    assert_eq!(fs::read(workspace).unwrap(), b"workspace sentinel");
}
