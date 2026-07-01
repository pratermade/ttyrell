use include_dir::{include_dir, Dir};
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

// ── Embedded asset trees ──────────────────────────────────────────────────────
// Any file added under lua/ or shell/ is automatically included here.
// No manual registration needed — just add the file and rebuild.

static LUA_DIR: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/lua");
static SHELL_DIR: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/shell");

// ── Detection ─────────────────────────────────────────────────────────────────

/// Returns true if init.lua exists at any canonical config location.
/// Does NOT consider the dev fallback `./lua/init.lua`.
pub fn is_installed() -> bool {
    canonical_config_dirs()
        .into_iter()
        .any(|d| d.join("init.lua").exists())
}

/// Returns true if stdin is connected to a terminal.
pub fn stdin_is_tty() -> bool {
    use std::io::IsTerminal;
    std::io::stdin().is_terminal()
}

fn canonical_config_dirs() -> Vec<PathBuf> {
    let Some(home) = dirs::home_dir() else {
        return vec![];
    };
    let mut out = Vec::new();
    if let Some(d) = dirs::config_dir() {
        out.push(d.join("ttyrell").join("lua"));
    }
    // macOS dirs::config_dir() returns ~/Library/Application Support;
    // also check the XDG-style path explicitly.
    out.push(home.join(".config").join("ttyrell").join("lua"));
    out.push(home.join(".ttyrell").join("lua"));
    out
}

/// The binary filename, including `.exe` on Windows.
const BINARY_NAME: &str = if cfg!(windows) { "ttyrell.exe" } else { "ttyrell" };

fn default_install_root() -> Option<PathBuf> {
    // Unix: ~/.config/ttyrell  (XDG convention)
    // Windows: %APPDATA%\ttyrell  (what dirs::config_dir returns on Windows)
    #[cfg(windows)]
    return dirs::config_dir().map(|d| d.join("ttyrell"));
    #[cfg(not(windows))]
    return dirs::home_dir().map(|h| h.join(".config").join("ttyrell"));
}

fn default_bin_dir() -> Option<PathBuf> {
    // Unix: ~/.local/bin
    // Windows: %LOCALAPPDATA%\Programs
    #[cfg(windows)]
    return dirs::data_local_dir().map(|d| d.join("Programs"));
    #[cfg(not(windows))]
    return dirs::home_dir().map(|h| h.join(".local").join("bin"));
}

// ── Terminal helpers ──────────────────────────────────────────────────────────

fn say(msg: &str) {
    println!("\n\x1b[1m\x1b[34m==>\x1b[0m\x1b[1m {msg}\x1b[0m");
}
fn ok(msg: &str) {
    println!("  \x1b[32m✓\x1b[0m {msg}");
}
fn warn(msg: &str) {
    println!("  \x1b[33m!\x1b[0m {msg}");
}

fn prompt_yn(msg: &str, default_yes: bool) -> bool {
    let hint = if default_yes { "[Y/n]" } else { "[y/N]" };
    loop {
        print!("  \x1b[36m?\x1b[0m {msg} {hint}: ");
        io::stdout().flush().ok();
        let mut line = String::new();
        if io::stdin().read_line(&mut line).is_err() {
            return default_yes;
        }
        match line.trim().to_lowercase().as_str() {
            "" => return default_yes,
            "y" | "yes" => return true,
            "n" | "no" => return false,
            _ => println!("  Please enter y or n."),
        }
    }
}

fn prompt_input(msg: &str, default: Option<&str>) -> String {
    match default {
        Some(d) if !d.is_empty() => print!("  \x1b[36m?\x1b[0m {msg} [{d}]: "),
        _ => print!("  \x1b[36m?\x1b[0m {msg}: "),
    }
    io::stdout().flush().ok();
    let mut line = String::new();
    io::stdin().read_line(&mut line).ok();
    let s = line.trim().to_string();
    if s.is_empty() {
        default.unwrap_or("").to_string()
    } else {
        s
    }
}

// ── LLM provider setup ────────────────────────────────────────────────────────

enum LlmProvider {
    Local {
        name: String,
        endpoint: String,
        model: String,
    },
    OpenAI {
        endpoint: String,
        model: String,
        api_key: String,
    },
    Anthropic {
        model: String,
        api_key: String,
    },
    None,
}

fn collect_llm_settings() -> LlmProvider {
    say("LLM provider  (press Enter to skip — configure later in init.lua)");
    println!();
    println!("    1) Local / OpenAI-compatible  (Ollama, llama.cpp, LM Studio, …)");
    println!("    2) OpenAI");
    println!("    3) Anthropic (Claude)");
    println!("    4) Skip");
    println!();
    print!("  \x1b[36m?\x1b[0m Choose [1-4]: ");
    io::stdout().flush().ok();

    let mut line = String::new();
    io::stdin().read_line(&mut line).ok();

    match line.trim() {
        "1" => {
            let endpoint = prompt_input(
                "Endpoint URL",
                Some("http://localhost:11434/v1/chat/completions"),
            );
            if endpoint.is_empty() {
                warn("No endpoint entered — skipping LLM setup.");
                return LlmProvider::None;
            }
            let model = prompt_input("Model name", Some("default"));
            ok("Local LLM configured");
            LlmProvider::Local {
                name: "local_llm".into(),
                endpoint,
                model,
            }
        }
        "2" => {
            let endpoint = prompt_input(
                "Endpoint URL",
                Some("https://api.openai.com/v1/chat/completions"),
            );
            let model = prompt_input("Model name", Some("gpt-4o"));
            let api_key =
                prompt_input("API key (blank → use OPENAI_API_KEY env var at runtime)", None);
            ok("OpenAI configured");
            LlmProvider::OpenAI {
                endpoint,
                model,
                api_key,
            }
        }
        "3" => {
            let model = prompt_input("Model name", Some("claude-opus-4-8"));
            let api_key = prompt_input(
                "API key (blank → use ANTHROPIC_API_KEY env var at runtime)",
                None,
            );
            ok("Anthropic/Claude configured");
            LlmProvider::Anthropic { model, api_key }
        }
        _ => {
            warn("LLM setup skipped. Edit init.lua to add a provider later.");
            LlmProvider::None
        }
    }
}

// ── LLM palette Lua block ─────────────────────────────────────────────────────

fn llm_palette_block(provider: &LlmProvider) -> String {
    match provider {
        LlmProvider::Local {
            name,
            endpoint,
            model,
        } => {
            format!(
                "LLM = {{\n    {name} = {{\n        endpoint = \"{endpoint}\",\n        model    = \"{model}\",\n    }},\n}}"
            )
        }

        LlmProvider::OpenAI {
            endpoint,
            model,
            api_key,
        } => {
            let key = if api_key.is_empty() {
                "os.getenv(\"OPENAI_API_KEY\")".to_string()
            } else {
                format!("\"{}\"", api_key)
            };
            format!(
                "LLM = {{\n    openai = {{\n        endpoint = \"{endpoint}\",\n        api_key  = {key},\n        model    = \"{model}\",\n    }},\n}}"
            )
        }

        LlmProvider::Anthropic { model, api_key } => {
            let key = if api_key.is_empty() {
                "os.getenv(\"ANTHROPIC_API_KEY\")".to_string()
            } else {
                format!("\"{}\"", api_key)
            };
            let mut b = String::new();
            b.push_str("LLM = {\n");
            b.push_str("    claude = {\n");
            b.push_str("        endpoint = \"https://api.anthropic.com/v1/messages\",\n");
            b.push_str(&format!("        api_key  = {key},\n"));
            b.push_str(&format!("        model    = \"{model}\",\n"));
            b.push_str("        headers  = function(cfg)\n");
            b.push_str("            return {\n");
            b.push_str("                [\"x-api-key\"]         = cfg.api_key,\n");
            b.push_str("                [\"anthropic-version\"] = \"2023-06-01\",\n");
            b.push_str("            }\n");
            b.push_str("        end,\n");
            b.push_str("        build_request = function(cfg, prompt, context)\n");
            b.push_str("            return {\n");
            b.push_str("                model      = cfg.model,\n");
            b.push_str("                max_tokens = 1024,\n");
            b.push_str("                system     = cfg.system_prompt,\n");
            b.push_str(
                "                messages   = { { role = \"user\", content = prompt .. (context and \"\\n\\n\" .. context or \"\") } },\n",
            );
            b.push_str("            }\n");
            b.push_str("        end,\n");
            b.push_str("        parse_response = function(parsed)\n");
            b.push_str("            if not parsed.content or #parsed.content == 0 then return nil, \"no content\" end\n");
            b.push_str("            return parsed.content[1].text, nil\n");
            b.push_str("        end,\n");
            b.push_str("    },\n");
            b.push_str("}");
            b
        }

        LlmProvider::None => concat!(
            "-- No LLM provider configured yet.\n",
            "-- Uncomment and edit one of the examples below, or see docs/llm-providers.md.\n",
            "--\n",
            "-- LLM = {\n",
            "--     local_llm = {\n",
            "--         endpoint = \"http://localhost:11434/v1/chat/completions\",\n",
            "--         model    = \"default\",\n",
            "--     },\n",
            "-- }",
        )
        .to_string(),
    }
}

fn provider_lua_ref(provider: &LlmProvider) -> Option<String> {
    match provider {
        LlmProvider::Local { name, .. } => Some(format!("LLM.{name}")),
        LlmProvider::OpenAI { .. } => Some("LLM.openai".into()),
        LlmProvider::Anthropic { .. } => Some("LLM.claude".into()),
        LlmProvider::None => None,
    }
}

// ── init.lua generation from template ────────────────────────────────────────

fn generate_init_lua(provider: &LlmProvider) -> String {
    let template = LUA_DIR
        .get_file("init.lua.template")
        .and_then(|f| f.contents_utf8())
        .expect("init.lua.template is missing from the embedded lua/ directory");

    template.replace("{{LLM_PALETTE}}", &llm_palette_block(provider))
}

// ── Plugin file patching ──────────────────────────────────────────────────────

/// Replace `VAR_NAME = LLM.<anything>` with `VAR_NAME = <new_ref>`.
fn patch_llm_ref(content: &str, var_name: &str, new_ref: &str) -> String {
    let prefix = format!("{var_name} = LLM.");
    let replacement = format!("{var_name} = {new_ref}");
    let lines: Vec<String> = content
        .lines()
        .map(|l| {
            if l.starts_with(&prefix) {
                replacement.clone()
            } else {
                l.to_string()
            }
        })
        .collect();
    lines.join("\n") + "\n"
}

/// Uncomment + set JOURNAL_OBSIDIAN_VAULT/DIR when a vault path is provided,
/// or ensure both are commented out when it is not.
fn patch_obsidian(content: &str, vault: Option<&str>) -> String {
    match vault {
        Some(path) if !path.is_empty() => content
            .lines()
            .map(|l| {
                let stripped = l.trim_start_matches("-- ");
                if stripped.starts_with("JOURNAL_OBSIDIAN_VAULT =") {
                    format!("JOURNAL_OBSIDIAN_VAULT = \"{path}\"")
                } else if stripped.starts_with("JOURNAL_OBSIDIAN_DIR") {
                    stripped.to_string()
                } else {
                    l.to_string()
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
            + "\n",
        _ => content
            .lines()
            .map(|l| {
                if l.starts_with("JOURNAL_OBSIDIAN_VAULT =")
                    || l.starts_with("JOURNAL_OBSIDIAN_DIR")
                {
                    format!("-- {l}")
                } else {
                    l.to_string()
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
            + "\n",
    }
}

/// Apply any install-time patches for a specific plugin file.
fn patch_file(
    file_name: &str,
    content: &str,
    llm_ref: Option<&str>,
    obsidian_vault: Option<&str>,
) -> String {
    match file_name {
        "ai_query.lua" => match llm_ref {
            Some(r) => patch_llm_ref(content, "AI_QUERY_LLM", r),
            None => content.to_string(),
        },
        "error_help.lua" => match llm_ref {
            Some(r) => patch_llm_ref(content, "ERROR_HELP_LLM", r),
            None => content.to_string(),
        },
        "workflow_journal.lua" => {
            let s = match llm_ref {
                Some(r) => patch_llm_ref(content, "JOURNAL_LLM", r),
                None => content.to_string(),
            };
            patch_obsidian(&s, obsidian_vault)
        }
        _ => content.to_string(),
    }
}

/// Files whose LLM provider / Obsidian settings the user may have edited.
/// In upgrade mode these are left alone if they already exist on disk.
fn is_user_editable(file_name: &str) -> bool {
    matches!(
        file_name,
        "ai_query.lua" | "error_help.lua" | "workflow_journal.lua"
    )
}

// ── Directory write ───────────────────────────────────────────────────────────

/// Recursively write an embedded Dir to `dest`.
///
/// - `init.lua` is skipped (generated separately from the template).
/// - `init.lua.template` is skipped (build-time asset only).
/// - In upgrade mode (`skip_user_editable = true`), user-editable plugin files
///   that already exist on disk are left untouched.
fn write_embedded_dir(
    dir: &Dir<'_>,
    dest: &Path,
    llm_ref: Option<&str>,
    obsidian_vault: Option<&str>,
    skip_user_editable: bool,
) -> anyhow::Result<()> {
    fs::create_dir_all(dest)?;

    for file in dir.files() {
        let name = match file.path().file_name().and_then(|n| n.to_str()) {
            Some(n) => n,
            None => continue,
        };

        if matches!(name, "init.lua" | "init.lua.template") {
            continue;
        }

        let dest_path = dest.join(name);

        if skip_user_editable && is_user_editable(name) && dest_path.exists() {
            continue;
        }

        let content = file.contents_utf8().unwrap_or("");
        let patched = patch_file(name, content, llm_ref, obsidian_vault);
        fs::write(&dest_path, patched)?;
    }

    for subdir in dir.dirs() {
        let name = match subdir.path().file_name().and_then(|n| n.to_str()) {
            Some(n) => n,
            None => continue,
        };
        write_embedded_dir(
            subdir,
            &dest.join(name),
            llm_ref,
            obsidian_vault,
            skip_user_editable,
        )?;
    }

    Ok(())
}

// ── High-level write helpers ──────────────────────────────────────────────────

fn write_all_files(
    install_root: &Path,
    provider: &LlmProvider,
    obsidian_vault: Option<&str>,
    upgrade: bool,
) -> anyhow::Result<()> {
    say(if upgrade {
        "Updating config files..."
    } else {
        "Writing config files..."
    });

    let lua_dest = install_root.join("lua");
    let shell_dest = install_root.join("shell");
    let llm_ref = provider_lua_ref(provider);

    write_embedded_dir(
        &LUA_DIR,
        &lua_dest,
        llm_ref.as_deref(),
        obsidian_vault,
        upgrade,
    )?;
    write_embedded_dir(&SHELL_DIR, &shell_dest, None, None, false)?;

    let init_path = lua_dest.join("init.lua");
    if !upgrade || !init_path.exists() {
        fs::write(&init_path, generate_init_lua(provider))?;
        ok(&format!("Config: {}", lua_dest.display()));
    } else {
        ok(&format!("Preserved: {}", init_path.display()));
    }

    Ok(())
}

// ── Binary self-copy ──────────────────────────────────────────────────────────

fn install_binary(bin_dir: &Path) -> anyhow::Result<PathBuf> {
    say("Installing binary...");
    let dest = bin_dir.join(BINARY_NAME);
    let current = std::env::current_exe()?;

    let already_there = current.canonicalize().ok() == dest.canonicalize().ok();
    if !already_there {
        fs::create_dir_all(bin_dir)?;
        fs::copy(&current, &dest)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&dest, fs::Permissions::from_mode(0o755))?;
        }
    }

    // Warn if the bin dir is not in PATH, using the correct separator per platform.
    let path_var = std::env::var("PATH").unwrap_or_default();
    let bin_str = bin_dir.to_string_lossy();
    let path_sep = if cfg!(windows) { ';' } else { ':' };
    if !path_var.split(path_sep).any(|p| p == bin_str.as_ref()) {
        warn(&format!("{bin_str} is not in PATH"));
        #[cfg(windows)]
        warn("Add it via System Properties → Environment Variables, or in PowerShell:\n  $env:PATH += \";{bin_str}\"");
        #[cfg(not(windows))]
        warn("Add to your shell rc:  export PATH=\"$HOME/.local/bin:$PATH\"");
    }

    ok(&format!("Binary: {}", dest.display()));
    Ok(dest)
}

// ── Shell integration ─────────────────────────────────────────────────────────

fn offer_shell_integration(install_root: &Path) {
    say("Shell integration  (optional — adds per-command events and exit codes)");

    // On Windows SHELL is usually unset; check PSModulePath to detect PowerShell.
    #[cfg(windows)]
    let shell_name = {
        let s = std::env::var("SHELL").unwrap_or_default();
        let name = Path::new(&s)
            .file_stem()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_lowercase();
        if name.is_empty() {
            // No $SHELL set — default to powershell if available
            if std::env::var("PSModulePath").is_ok() {
                "powershell".to_string()
            } else {
                String::new()
            }
        } else {
            name
        }
    };
    #[cfg(not(windows))]
    let shell_name = {
        let s = std::env::var("SHELL").unwrap_or_default();
        Path::new(&s)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_string()
    };

    match shell_name.as_str() {
        "zsh" | "bash" => {
            let (rc_path, script_name) = if shell_name == "zsh" {
                (dirs::home_dir().map(|h| h.join(".zshrc")), "integration.zsh")
            } else {
                (
                    dirs::home_dir().map(|h| h.join(".bashrc")),
                    "integration.bash",
                )
            };
            let Some(rc_path) = rc_path else { return };
            let script = install_root.join("shell").join(script_name);

            if fs::read_to_string(&rc_path)
                .map(|s| s.contains("ttyrell"))
                .unwrap_or(false)
            {
                ok(&format!(
                    "Shell integration already present in {}",
                    rc_path.display()
                ));
                return;
            }

            if prompt_yn(
                &format!("Add {shell_name} integration to {}?", rc_path.display()),
                true,
            ) {
                let snippet = format!(
                    "\n# ttyrell shell integration\nexport TTYRELL=1\n[ -f \"{0}\" ] && source \"{0}\"\n",
                    script.display()
                );
                match fs::OpenOptions::new().append(true).open(&rc_path) {
                    Ok(mut f) => {
                        if f.write_all(snippet.as_bytes()).is_ok() {
                            ok(&format!("Added to {}", rc_path.display()));
                        } else {
                            warn("Write failed — add manually:");
                            println!("  export TTYRELL=1");
                            println!("  source \"{}\"", script.display());
                        }
                    }
                    Err(_) => {
                        warn(&format!(
                            "Could not open {} — add manually:",
                            rc_path.display()
                        ));
                        println!("  export TTYRELL=1");
                        println!("  source \"{}\"", script.display());
                    }
                }
            }
        }

        "fish" => {
            let conf_d = dirs::config_dir()
                .map(|d| d.join("fish").join("conf.d"));
            let Some(conf_d) = conf_d else { return };
            let dest = conf_d.join("ttyrell.fish");

            if dest.exists() {
                ok("Fish integration already installed");
                return;
            }

            let src = install_root.join("shell").join("integration.fish");
            if prompt_yn(&format!("Install fish integration to {}?", dest.display()), true) {
                let _ = fs::create_dir_all(&conf_d);
                if fs::copy(&src, &dest).is_ok() {
                    ok(&format!("Fish integration: {}", dest.display()));
                    warn("Add 'set -Ux TTYRELL 1' to your fish config if not already present.");
                } else {
                    warn(&format!("Could not write to {}", dest.display()));
                }
            }
        }

        // PowerShell — Windows primary shell
        "powershell" | "pwsh" => {
            // $PROFILE path: %USERPROFILE%\Documents\PowerShell\Microsoft.PowerShell_profile.ps1
            let profile = dirs::home_dir().map(|h| {
                h.join("Documents")
                    .join("PowerShell")
                    .join("Microsoft.PowerShell_profile.ps1")
            });
            let Some(profile) = profile else { return };
            let script = install_root.join("shell").join("integration.ps1");

            if fs::read_to_string(&profile)
                .map(|s| s.contains("ttyrell"))
                .unwrap_or(false)
            {
                ok(&format!(
                    "PowerShell integration already present in {}",
                    profile.display()
                ));
                return;
            }

            if prompt_yn(
                &format!("Add PowerShell integration to {}?", profile.display()),
                true,
            ) {
                let snippet = format!(
                    "\r\n# ttyrell shell integration\r\n$env:TTYRELL = \"1\"\r\n. \"{}\"\r\n",
                    script.display()
                );
                let _ = profile.parent().map(fs::create_dir_all);
                match fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&profile)
                {
                    Ok(mut f) => {
                        if f.write_all(snippet.as_bytes()).is_ok() {
                            ok(&format!("Added to {}", profile.display()));
                        } else {
                            warn("Write failed — add manually to your $PROFILE:");
                            println!("  $env:TTYRELL = \"1\"");
                            println!("  . \"{}\"", script.display());
                        }
                    }
                    Err(_) => {
                        warn(&format!(
                            "Could not open {} — add manually:",
                            profile.display()
                        ));
                        println!("  $env:TTYRELL = \"1\"");
                        println!("  . \"{}\"", script.display());
                    }
                }
            }
        }

        other => {
            if !other.is_empty() {
                warn(&format!(
                    "Unknown shell ({other}) — see README.md for manual integration."
                ));
            }
        }
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn run(force: bool) -> anyhow::Result<()> {
    let version = env!("CARGO_PKG_VERSION");
    println!("\n\x1b[1mttyrell installer\x1b[0m  v{version}");
    println!("══════════════════════════════════════════");

    let Some(install_root) = default_install_root() else {
        anyhow::bail!("cannot determine home directory");
    };
    let Some(bin_dir) = default_bin_dir() else {
        anyhow::bail!("cannot determine home directory");
    };

    let init_lua = install_root.join("lua").join("init.lua");
    let bin_dest = bin_dir.join(BINARY_NAME);
    let has_config = init_lua.exists();
    let has_binary = bin_dest.exists();

    // ── Detect / confirm ──────────────────────────────────────────────────────
    let mut keep_config = false;

    if (has_config || has_binary) && !force {
        println!();
        if has_binary {
            warn(&format!("Binary already installed: {}", bin_dest.display()));
        }
        if has_config {
            warn(&format!("Config already exists:   {}", init_lua.display()));
        }
        println!();
        if !prompt_yn("Reinstall / upgrade?", false) {
            println!("  Aborted.");
            return Ok(());
        }
        if has_config {
            keep_config =
                prompt_yn("Keep existing init.lua (preserves your LLM settings)?", true);
        }
    } else if !force {
        println!();
        println!("  This will:");
        println!("    • Copy ttyrell to {}", bin_dest.display());
        println!(
            "    • Write Lua config to {}",
            install_root.join("lua").display()
        );
        println!("    • Create session log directory");
        println!();
        if !prompt_yn("Proceed?", true) {
            println!("  Aborted.");
            return Ok(());
        }
    }

    // ── Binary ────────────────────────────────────────────────────────────────
    install_binary(&bin_dir)?;

    // ── Config ────────────────────────────────────────────────────────────────
    if keep_config {
        // upgrade=true: support files refreshed, user-edited plugin files preserved
        write_all_files(&install_root, &LlmProvider::None, None, true)?;
    } else {
        let provider = collect_llm_settings();

        say("Obsidian integration  (optional — workflow_journal plugin)");
        let vault_input = prompt_input("Obsidian vault path (leave blank to skip)", None);
        let obsidian_vault = if vault_input.is_empty() {
            None
        } else {
            Some(vault_input)
        };

        write_all_files(&install_root, &provider, obsidian_vault.as_deref(), false)?;
    }

    // ── Data dirs ─────────────────────────────────────────────────────────────
    if let Some(data_dir) = dirs::home_dir()
        .map(|h| h.join(".local").join("share").join("ttyrell").join("sessions"))
    {
        fs::create_dir_all(&data_dir)?;
        ok(&format!("Session logs: {}", data_dir.display()));
    }

    // ── Shell integration ─────────────────────────────────────────────────────
    offer_shell_integration(&install_root);

    // ── Done ──────────────────────────────────────────────────────────────────
    println!("\n\x1b[32m\x1b[1mInstallation complete!\x1b[0m\n");
    println!("  Next steps:");
    println!("  1. Point your terminal at ttyrell  (see README.md → Terminal setup)");
    println!("       Ghostty:  command = {}", bin_dest.display());
    println!("       tmux:     set -g default-shell {}", bin_dest.display());
    println!(
        "  2. Edit {} to customise plugins",
        init_lua.display()
    );
    println!("  3. Open a new terminal window to start using ttyrell\n");

    Ok(())
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── patch_llm_ref ─────────────────────────────────────────────────────────

    #[test]
    fn patch_llm_ref_replaces_active_line() {
        let input = "-- comment\nAI_QUERY_LLM = LLM.local_llama\n-- AI_QUERY_LLM = LLM.claude\n";
        let out = patch_llm_ref(input, "AI_QUERY_LLM", "LLM.claude");
        assert!(out.contains("AI_QUERY_LLM = LLM.claude\n"));
        // The commented-out alternative should be unchanged
        assert!(out.contains("-- AI_QUERY_LLM = LLM.claude"));
        // The old active assignment must be gone
        assert!(!out.contains("AI_QUERY_LLM = LLM.local_llama"));
    }

    #[test]
    fn patch_llm_ref_ignores_commented_lines() {
        let input = "-- AI_QUERY_LLM = LLM.local_llama\n";
        let out = patch_llm_ref(input, "AI_QUERY_LLM", "LLM.claude");
        // Commented line must not be activated
        assert_eq!(out, "-- AI_QUERY_LLM = LLM.local_llama\n");
    }

    #[test]
    fn patch_llm_ref_leaves_unrelated_lines_intact() {
        let input = "local x = 1\nERROR_HELP_LLM = LLM.local_llama\nlocal y = 2\n";
        let out = patch_llm_ref(input, "AI_QUERY_LLM", "LLM.claude");
        assert_eq!(out, input);
    }

    #[test]
    fn patch_llm_ref_different_vars_independent() {
        let input = "AI_QUERY_LLM = LLM.local_llama\nERROR_HELP_LLM = LLM.local_llama\n";
        let out = patch_llm_ref(input, "AI_QUERY_LLM", "LLM.claude");
        assert!(out.contains("AI_QUERY_LLM = LLM.claude"));
        // ERROR_HELP_LLM must be untouched
        assert!(out.contains("ERROR_HELP_LLM = LLM.local_llama"));
    }

    // ── patch_obsidian ────────────────────────────────────────────────────────

    const JOURNAL_SNIPPET: &str = "\
JOURNAL_LLM = LLM.local_llm\n\
-- JOURNAL_OBSIDIAN_VAULT = \"/path/to/your/vault\"\n\
-- JOURNAL_OBSIDIAN_DIR   = \"Work Journal\"\n\
local x = 1\n";

    #[test]
    fn patch_obsidian_enables_vault_when_path_given() {
        let out = patch_obsidian(JOURNAL_SNIPPET, Some("/my/vault"));
        assert!(out.contains("JOURNAL_OBSIDIAN_VAULT = \"/my/vault\""));
        // DIR line should be uncommented (keeping its default value)
        assert!(out.contains("JOURNAL_OBSIDIAN_DIR"));
        assert!(!out.contains("-- JOURNAL_OBSIDIAN_DIR"));
    }

    #[test]
    fn patch_obsidian_none_leaves_commented_lines_alone() {
        let out = patch_obsidian(JOURNAL_SNIPPET, None);
        // Already commented — must stay commented
        assert!(out.contains("-- JOURNAL_OBSIDIAN_VAULT"));
        assert!(out.contains("-- JOURNAL_OBSIDIAN_DIR"));
    }

    #[test]
    fn patch_obsidian_none_comments_out_active_vault() {
        let input = "JOURNAL_OBSIDIAN_VAULT = \"/old/path\"\nJOURNAL_OBSIDIAN_DIR   = \"Work Journal\"\n";
        let out = patch_obsidian(input, None);
        // No line may start with the bare variable (i.e. be uncommented)
        assert!(out.lines().all(|l| !l.starts_with("JOURNAL_OBSIDIAN_VAULT")));
        assert!(out.lines().all(|l| !l.starts_with("JOURNAL_OBSIDIAN_DIR")));
        assert!(out.contains("-- JOURNAL_OBSIDIAN_VAULT"));
        assert!(out.contains("-- JOURNAL_OBSIDIAN_DIR"));
    }

    #[test]
    fn patch_obsidian_empty_string_treated_as_none() {
        let input = "JOURNAL_OBSIDIAN_VAULT = \"/old/path\"\n";
        let out = patch_obsidian(input, Some(""));
        assert!(out.contains("-- JOURNAL_OBSIDIAN_VAULT"));
    }

    // ── patch_file dispatch ───────────────────────────────────────────────────

    #[test]
    fn patch_file_routes_ai_query() {
        let input = "AI_QUERY_LLM = LLM.local_llama\n";
        let out = patch_file("ai_query.lua", input, Some("LLM.claude"), None);
        assert!(out.contains("AI_QUERY_LLM = LLM.claude"));
    }

    #[test]
    fn patch_file_routes_error_help() {
        let input = "ERROR_HELP_LLM = LLM.local_llama\n";
        let out = patch_file("error_help.lua", input, Some("LLM.openai"), None);
        assert!(out.contains("ERROR_HELP_LLM = LLM.openai"));
    }

    #[test]
    fn patch_file_routes_workflow_journal_llm_and_obsidian() {
        let input = "JOURNAL_LLM = LLM.local_llama\n-- JOURNAL_OBSIDIAN_VAULT = \"/x\"\n";
        let out = patch_file(
            "workflow_journal.lua",
            input,
            Some("LLM.claude"),
            Some("/my/vault"),
        );
        assert!(out.contains("JOURNAL_LLM = LLM.claude"));
        assert!(out.contains("JOURNAL_OBSIDIAN_VAULT = \"/my/vault\""));
    }

    #[test]
    fn patch_file_unknown_file_passthrough() {
        let input = "some content\n";
        let out = patch_file("session_log.lua", input, Some("LLM.claude"), None);
        assert_eq!(out, input);
    }

    #[test]
    fn patch_file_no_llm_ref_leaves_plugin_unchanged() {
        let input = "AI_QUERY_LLM = LLM.local_llama\n";
        let out = patch_file("ai_query.lua", input, None, None);
        assert_eq!(out, input);
    }

    // ── is_user_editable ──────────────────────────────────────────────────────

    #[test]
    fn is_user_editable_true_for_plugin_files() {
        assert!(is_user_editable("ai_query.lua"));
        assert!(is_user_editable("error_help.lua"));
        assert!(is_user_editable("workflow_journal.lua"));
    }

    #[test]
    fn is_user_editable_false_for_support_files() {
        assert!(!is_user_editable("llm.lua"));
        assert!(!is_user_editable("secret_guard.lua"));
        assert!(!is_user_editable("session_log.lua"));
        assert!(!is_user_editable("activity_log.lua"));
        assert!(!is_user_editable("init.lua"));
    }

    // ── llm_palette_block ─────────────────────────────────────────────────────

    #[test]
    fn palette_local_contains_endpoint_and_model() {
        let p = llm_palette_block(&LlmProvider::Local {
            name: "my_llm".into(),
            endpoint: "http://localhost:1234/v1/chat/completions".into(),
            model: "llama3".into(),
        });
        assert!(p.contains("my_llm"));
        assert!(p.contains("http://localhost:1234/v1/chat/completions"));
        assert!(p.contains("llama3"));
        // Must not contain api_key field for local
        assert!(!p.contains("api_key"));
    }

    #[test]
    fn palette_openai_literal_key() {
        let p = llm_palette_block(&LlmProvider::OpenAI {
            endpoint: "https://api.openai.com/v1/chat/completions".into(),
            model: "gpt-4o".into(),
            api_key: "sk-abc123".into(),
        });
        assert!(p.contains("\"sk-abc123\""));
        assert!(!p.contains("os.getenv"));
    }

    #[test]
    fn palette_openai_env_var_when_key_blank() {
        let p = llm_palette_block(&LlmProvider::OpenAI {
            endpoint: "https://api.openai.com/v1/chat/completions".into(),
            model: "gpt-4o".into(),
            api_key: String::new(),
        });
        assert!(p.contains("os.getenv(\"OPENAI_API_KEY\")"));
    }

    #[test]
    fn palette_anthropic_has_custom_headers() {
        let p = llm_palette_block(&LlmProvider::Anthropic {
            model: "claude-opus-4-8".into(),
            api_key: String::new(),
        });
        assert!(p.contains("x-api-key"));
        assert!(p.contains("anthropic-version"));
        assert!(p.contains("parse_response"));
        assert!(p.contains("os.getenv(\"ANTHROPIC_API_KEY\")"));
    }

    #[test]
    fn palette_anthropic_literal_key() {
        let p = llm_palette_block(&LlmProvider::Anthropic {
            model: "claude-opus-4-8".into(),
            api_key: "sk-ant-xyz".into(),
        });
        assert!(p.contains("\"sk-ant-xyz\""));
        assert!(!p.contains("os.getenv"));
    }

    #[test]
    fn palette_none_is_all_comments() {
        let p = llm_palette_block(&LlmProvider::None);
        for line in p.lines() {
            let trimmed = line.trim();
            assert!(
                trimmed.is_empty() || trimmed.starts_with("--"),
                "expected comment line, got: {line}"
            );
        }
    }

    // ── provider_lua_ref ──────────────────────────────────────────────────────

    #[test]
    fn lua_ref_local_uses_custom_name() {
        let r = provider_lua_ref(&LlmProvider::Local {
            name: "my_llm".into(),
            endpoint: String::new(),
            model: String::new(),
        });
        assert_eq!(r, Some("LLM.my_llm".to_string()));
    }

    #[test]
    fn lua_ref_openai() {
        assert_eq!(
            provider_lua_ref(&LlmProvider::OpenAI {
                endpoint: String::new(),
                model: String::new(),
                api_key: String::new(),
            }),
            Some("LLM.openai".to_string())
        );
    }

    #[test]
    fn lua_ref_anthropic() {
        assert_eq!(
            provider_lua_ref(&LlmProvider::Anthropic {
                model: String::new(),
                api_key: String::new(),
            }),
            Some("LLM.claude".to_string())
        );
    }

    #[test]
    fn lua_ref_none_is_none() {
        assert_eq!(provider_lua_ref(&LlmProvider::None), None);
    }

    // ── generate_init_lua ─────────────────────────────────────────────────────

    #[test]
    fn generate_init_lua_placeholder_is_replaced() {
        let out = generate_init_lua(&LlmProvider::None);
        assert!(!out.contains("{{LLM_PALETTE}}"));
    }

    #[test]
    fn generate_init_lua_contains_template_structure() {
        let out = generate_init_lua(&LlmProvider::None);
        assert!(out.contains("PROXY_LUA_DIR"));
        assert!(out.contains("try_load"));
        assert!(out.contains("session_start"));
        assert!(out.contains("plugins"));
    }

    #[test]
    fn generate_init_lua_embeds_local_provider() {
        let out = generate_init_lua(&LlmProvider::Local {
            name: "my_llm".into(),
            endpoint: "http://localhost:9999/v1/chat/completions".into(),
            model: "mistral".into(),
        });
        assert!(out.contains("my_llm"));
        assert!(out.contains("http://localhost:9999/v1/chat/completions"));
        assert!(out.contains("mistral"));
    }

    #[test]
    fn generate_init_lua_embeds_anthropic_provider() {
        let out = generate_init_lua(&LlmProvider::Anthropic {
            model: "claude-opus-4-8".into(),
            api_key: String::new(),
        });
        assert!(out.contains("anthropic.com"));
        assert!(out.contains("ANTHROPIC_API_KEY"));
        assert!(out.contains("parse_response"));
    }
}
