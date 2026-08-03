use std::collections::HashSet;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Route {
    Direct(Vec<String>),
    CoveRemote(Vec<String>),
}

pub fn route_codex_args(args: &[String], bypass: bool, endpoint: &str) -> Route {
    if bypass || has_explicit_remote(args) {
        return Route::Direct(args.to_vec());
    }
    if args
        .iter()
        .any(|arg| matches!(arg.as_str(), "--help" | "-h" | "--version" | "-V"))
    {
        return Route::Direct(args.to_vec());
    }

    match recognized_subcommand(args).as_deref() {
        Some(command) if direct_subcommands().contains(command) => Route::Direct(args.to_vec()),
        Some(command) if remote_subcommands().contains(command) => {
            Route::CoveRemote(with_remote(args, endpoint))
        }
        Some(_) => Route::Direct(args.to_vec()),
        None => Route::CoveRemote(with_remote(args, endpoint)),
    }
}

pub fn has_explicit_remote(args: &[String]) -> bool {
    args.iter()
        .any(|arg| arg == "--remote" || arg.starts_with("--remote="))
}

fn with_remote(args: &[String], endpoint: &str) -> Vec<String> {
    let mut routed = Vec::with_capacity(args.len() + 2);
    routed.push("--remote".to_owned());
    routed.push(endpoint.to_owned());
    routed.extend_from_slice(args);
    routed
}

pub fn recognized_subcommand(args: &[String]) -> Option<String> {
    let known = all_subcommands();
    let mut skip_next = false;
    for arg in args {
        if skip_next {
            skip_next = false;
            continue;
        }
        if options_with_value().contains(arg.as_str()) {
            skip_next = true;
            continue;
        }
        if arg.starts_with('-') {
            continue;
        }
        if known.contains(arg.as_str()) {
            return Some(arg.clone());
        }
        // First positional not matching a known command is an interactive prompt.
        return None;
    }
    None
}

fn options_with_value() -> HashSet<&'static str> {
    [
        "-c",
        "--config",
        "--enable",
        "--disable",
        "--remote",
        "--remote-auth-token-env",
        "-i",
        "--image",
        "-m",
        "--model",
        "--local-provider",
        "-p",
        "--profile",
        "-s",
        "--sandbox",
        "-C",
        "--cd",
        "--add-dir",
        "-a",
        "--ask-for-approval",
    ]
    .into_iter()
    .collect()
}

fn direct_subcommands() -> HashSet<&'static str> {
    [
        "exec",
        "e",
        "review",
        "login",
        "logout",
        "mcp",
        "plugin",
        "mcp-server",
        "app-server",
        "remote-control",
        "app",
        "completion",
        "update",
        "doctor",
        "sandbox",
        "debug",
        "apply",
        "a",
        "cloud",
        "exec-server",
        "features",
        "help",
    ]
    .into_iter()
    .collect()
}

fn remote_subcommands() -> HashSet<&'static str> {
    ["resume", "fork", "archive", "delete", "unarchive"]
        .into_iter()
        .collect()
}

fn all_subcommands() -> HashSet<&'static str> {
    direct_subcommands()
        .into_iter()
        .chain(remote_subcommands())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    #[test]
    fn routes_interactive_and_supported_commands() {
        assert_eq!(
            route_codex_args(&[], false, "unix:///tmp/cove.sock"),
            Route::CoveRemote(strings(&["--remote", "unix:///tmp/cove.sock"]))
        );
        assert!(matches!(
            route_codex_args(
                &strings(&["-C", "/tmp", "resume", "--last"]),
                false,
                "unix://x"
            ),
            Route::CoveRemote(_)
        ));
        assert!(matches!(
            route_codex_args(&strings(&["fix", "the", "tests"]), false, "unix://x"),
            Route::CoveRemote(_)
        ));
    }

    #[test]
    fn passes_noninteractive_and_unknown_commands_directly() {
        for command in ["exec", "review", "doctor", "app-server", "plugin"] {
            assert_eq!(
                route_codex_args(&strings(&[command]), false, "unix://x"),
                Route::Direct(strings(&[command]))
            );
        }
    }

    #[test]
    fn explicit_remote_and_bypass_are_never_rewritten() {
        let explicit = strings(&["--remote", "unix://custom", "resume"]);
        assert_eq!(
            route_codex_args(&explicit, false, "unix://cove"),
            Route::Direct(explicit)
        );
        let normal = strings(&["resume"]);
        assert_eq!(
            route_codex_args(&normal, true, "unix://cove"),
            Route::Direct(normal)
        );
    }

    #[test]
    fn passes_global_help_and_version_flags_directly() {
        for flag in ["--help", "-h", "--version", "-V"] {
            let args = strings(&[flag]);
            assert_eq!(
                route_codex_args(&args, false, "unix://cove"),
                Route::Direct(args)
            );
        }
        let configured = strings(&["--config", "model=\"gpt-5\"", "--version"]);
        assert_eq!(
            route_codex_args(&configured, false, "unix://cove"),
            Route::Direct(configured)
        );
    }

    #[test]
    fn option_values_do_not_look_like_commands() {
        let args = strings(&["--model", "review", "resume", "--last"]);
        assert!(matches!(
            route_codex_args(&args, false, "unix://x"),
            Route::CoveRemote(_)
        ));
    }
}
