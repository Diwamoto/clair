use std::env;
use std::ffi::OsStr;
use std::fs;
use std::io::{self, BufRead, BufWriter, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{self, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value, json};

const MAX_MESSAGE_BYTES: usize = 1024 * 1024;
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(3);
const PROBE_TIMEOUT: Duration = Duration::from_millis(350);
const APP_READY_TIMEOUT: Duration = Duration::from_secs(8);
const RETRY_INTERVAL: Duration = Duration::from_millis(100);
const CLI_VERSION: &str = env!("CARGO_PKG_VERSION");

static REQUEST_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Channel {
    Stable,
    Dev,
}

impl Channel {
    fn parse(value: &str) -> Result<Self, CliError> {
        match value {
            "stable" => Ok(Self::Stable),
            "dev" => Ok(Self::Dev),
            other => Err(CliError::usage(format!(
                "invalid channel {other:?}; expected stable or dev"
            ))),
        }
    }

    const fn application_name(self) -> &'static str {
        match self {
            Self::Stable => "Clair.app",
            Self::Dev => "Clair Dev.app",
        }
    }

    const fn application_support_name(self) -> &'static str {
        match self {
            Self::Stable => "Clair",
            Self::Dev => "Clair Dev",
        }
    }
}

#[derive(Debug)]
struct Config {
    channel: Channel,
    no_launch: bool,
    socket_override: Option<PathBuf>,
    app_override: Option<PathBuf>,
}

impl Config {
    fn from_environment() -> Result<Self, CliError> {
        let channel = match env::var("CLAIR_CHANNEL") {
            Ok(value) => Channel::parse(&value)?,
            Err(env::VarError::NotPresent) => Channel::Dev,
            Err(error) => {
                return Err(CliError::runtime(format!(
                    "could not read CLAIR_CHANNEL: {error}"
                )));
            }
        };
        Ok(Self {
            channel,
            no_launch: false,
            socket_override: env::var_os("CLAIR_COMMAND_SOCKET").map(PathBuf::from),
            app_override: env::var_os("CLAIR_APP_PATH").map(PathBuf::from),
        })
    }

    fn socket_path(&self) -> Result<PathBuf, CliError> {
        if let Some(path) = &self.socket_override {
            return Ok(path.clone());
        }
        let home = env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or_else(|| CliError::runtime("HOME is not set; use --socket"))?;
        Ok(home
            .join("Library")
            .join("Application Support")
            .join(self.channel.application_support_name())
            .join("command-v1.sock"))
    }

    fn application_path(&self) -> PathBuf {
        if let Some(path) = &self.app_override {
            return path.clone();
        }

        if let Ok(executable) = env::current_exe() {
            let resolved = fs::canonicalize(&executable).unwrap_or(executable);
            if let Some(bundle) = enclosing_app_bundle(&resolved) {
                return bundle;
            }
        }

        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
        let product = self.channel.application_name();
        let candidates = [
            repo_root
                .join(".build/xcode")
                .join(if self.channel == Channel::Dev {
                    "dev"
                } else {
                    "stable"
                })
                .join("Build/Products/Debug")
                .join(product),
            repo_root
                .join(".build/xcode/p13/Build/Products/Debug")
                .join(product),
            repo_root
                .join(".build/xcode/p13-build/Build/Products/Debug")
                .join(product),
            repo_root
                .join(".build/xcode/p12-manual/Build/Products/Debug")
                .join(product),
        ];
        candidates
            .iter()
            .find(|candidate| candidate.exists())
            .cloned()
            .unwrap_or_else(|| candidates[0].clone())
    }
}

#[derive(Debug)]
struct CliError {
    exit_code: u8,
    message: String,
}

impl CliError {
    fn usage(message: impl Into<String>) -> Self {
        Self {
            exit_code: 2,
            message: message.into(),
        }
    }

    fn runtime(message: impl Into<String>) -> Self {
        Self {
            exit_code: 1,
            message: message.into(),
        }
    }
}

impl std::fmt::Display for CliError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

#[derive(Debug)]
enum Action {
    Help,
    Version,
    Open { location: String },
    List,
    Agent(AgentAction),
    Command(CommandAction),
    Mcp,
}

#[derive(Debug)]
enum AgentAction {
    List {
        project_id: Option<String>,
    },
    Status {
        session_id: String,
    },
    Launch {
        project_id: String,
        profile_id: String,
        model_id: Option<String>,
        worktree_id: Option<String>,
        confirmed: bool,
    },
    Reveal {
        project_id: String,
        session_id: String,
    },
    Input {
        session_id: String,
        text: String,
        confirmed: bool,
    },
    Interrupt {
        session_id: String,
        confirmed: bool,
    },
    Stop {
        session_id: String,
        confirmed: bool,
    },
}

#[derive(Debug)]
struct CommandAction {
    command_id: String,
    params: Value,
    confirmed: bool,
}

fn main() -> process::ExitCode {
    match run() {
        Ok(()) => process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            process::ExitCode::from(error.exit_code)
        }
    }
}

fn run() -> Result<(), CliError> {
    let arguments: Vec<String> = env::args().skip(1).collect();
    let (config, action) = parse_arguments(&arguments)?;
    match action {
        Action::Help => {
            print_help();
            Ok(())
        }
        Action::Version => {
            println!("clair {CLI_VERSION}");
            Ok(())
        }
        Action::Mcp => handle_mcp(&config),
        action => execute_action(&config, action),
    }
}

fn parse_arguments(arguments: &[String]) -> Result<(Config, Action), CliError> {
    let mut config = Config::from_environment()?;
    let mut index = 0;
    while index < arguments.len() {
        match arguments[index].as_str() {
            "-h" | "--help" => return Ok((config, Action::Help)),
            "--version" => return Ok((config, Action::Version)),
            "--channel" => {
                let value = required_value(arguments, &mut index, "--channel")?;
                config.channel = Channel::parse(&value)?;
            }
            "--no-launch" => config.no_launch = true,
            "--socket" => {
                config.socket_override = Some(PathBuf::from(required_value(
                    arguments, &mut index, "--socket",
                )?));
            }
            "--app" => {
                config.app_override = Some(PathBuf::from(required_value(
                    arguments, &mut index, "--app",
                )?));
            }
            "open" => return Ok((config, parse_open(&arguments[index + 1..])?)),
            "list" => return Ok((config, parse_list(&arguments[index + 1..])?)),
            "agent" => return Ok((config, parse_agent(&arguments[index + 1..])?)),
            "command" => return Ok((config, parse_command(&arguments[index + 1..])?)),
            "mcp" => return Ok((config, parse_mcp(&arguments[index + 1..])?)),
            other => {
                return Err(CliError::usage(format!(
                    "unknown argument {other:?}\n\n{}",
                    usage_text()
                )));
            }
        }
        index += 1;
    }
    Err(CliError::usage(usage_text()))
}

fn required_value(
    arguments: &[String],
    index: &mut usize,
    option: &str,
) -> Result<String, CliError> {
    *index += 1;
    arguments
        .get(*index)
        .cloned()
        .ok_or_else(|| CliError::usage(format!("{option} requires a value")))
}

fn parse_open(arguments: &[String]) -> Result<Action, CliError> {
    if arguments.len() != 1 || arguments[0] == "--help" {
        return if arguments.first().is_some_and(|value| value == "--help") {
            Ok(Action::Help)
        } else {
            Err(CliError::usage(
                "open requires one path[:line[:column]] argument",
            ))
        };
    }
    Ok(Action::Open {
        location: arguments[0].clone(),
    })
}

fn parse_list(arguments: &[String]) -> Result<Action, CliError> {
    if arguments.is_empty() {
        Ok(Action::List)
    } else if arguments.len() == 1 && arguments[0] == "--help" {
        Ok(Action::Help)
    } else {
        Err(CliError::usage("list does not accept arguments"))
    }
}

fn parse_agent(arguments: &[String]) -> Result<Action, CliError> {
    let Some(action) = arguments.first().map(String::as_str) else {
        return Err(CliError::usage("agent requires an action"));
    };
    if action == "--help" || action == "-h" {
        return Ok(Action::Help);
    }
    let rest = &arguments[1..];
    match action {
        "list" => parse_agent_list(rest),
        "status" => parse_agent_status(rest),
        "launch" => parse_agent_launch(rest),
        "reveal" => parse_agent_reveal(rest),
        "input" => parse_agent_input(rest),
        "interrupt" => parse_agent_signal(rest, false),
        "stop" => parse_agent_signal(rest, true),
        other => Err(CliError::usage(format!(
            "unknown agent action {other:?}\n\n{}",
            usage_text()
        ))),
    }
}

fn parse_agent_list(arguments: &[String]) -> Result<Action, CliError> {
    let mut project_id = None;
    let mut index = 0;
    while index < arguments.len() {
        match arguments[index].as_str() {
            "--help" | "-h" => return Ok(Action::Help),
            "--project-id" => {
                project_id = Some(required_value(arguments, &mut index, "--project-id")?);
            }
            other => {
                return Err(CliError::usage(format!(
                    "unknown agent list argument {other:?}"
                )));
            }
        }
        index += 1;
    }
    Ok(Action::Agent(AgentAction::List { project_id }))
}

fn parse_agent_status(arguments: &[String]) -> Result<Action, CliError> {
    if arguments.len() == 1 {
        return Ok(Action::Agent(AgentAction::Status {
            session_id: arguments[0].clone(),
        }));
    }
    if arguments
        .first()
        .is_some_and(|value| value == "--help" || value == "-h")
    {
        return Ok(Action::Help);
    }
    Err(CliError::usage("agent status requires one session ID"))
}

fn parse_agent_launch(arguments: &[String]) -> Result<Action, CliError> {
    let mut positional = Vec::new();
    let mut model_id = None;
    let mut worktree_id = None;
    let mut confirmed = false;
    let mut index = 0;
    while index < arguments.len() {
        match arguments[index].as_str() {
            "--help" | "-h" => return Ok(Action::Help),
            "--worktree-id" => {
                worktree_id = Some(required_value(arguments, &mut index, "--worktree-id")?);
            }
            "--model" => {
                model_id = Some(required_value(arguments, &mut index, "--model")?);
            }
            "--yes" => confirmed = true,
            argument if argument.starts_with('-') => {
                return Err(CliError::usage(format!(
                    "unknown agent launch argument {argument:?}"
                )));
            }
            argument => positional.push(argument.to_owned()),
        }
        index += 1;
    }
    if positional.len() != 2 {
        return Err(CliError::usage(
            "agent launch requires PROJECT_ID PROFILE_ID",
        ));
    }
    Ok(Action::Agent(AgentAction::Launch {
        project_id: positional[0].clone(),
        profile_id: positional[1].clone(),
        model_id,
        worktree_id,
        confirmed,
    }))
}

fn parse_agent_reveal(arguments: &[String]) -> Result<Action, CliError> {
    if arguments.len() == 2 && arguments.iter().all(|value| !value.starts_with('-')) {
        return Ok(Action::Agent(AgentAction::Reveal {
            project_id: arguments[0].clone(),
            session_id: arguments[1].clone(),
        }));
    }
    if arguments
        .first()
        .is_some_and(|value| value == "--help" || value == "-h")
    {
        return Ok(Action::Help);
    }
    Err(CliError::usage(
        "agent reveal requires PROJECT_ID SESSION_ID",
    ))
}

fn parse_agent_input(arguments: &[String]) -> Result<Action, CliError> {
    let mut positional = Vec::new();
    let mut text = None;
    let mut confirmed = false;
    let mut index = 0;
    while index < arguments.len() {
        match arguments[index].as_str() {
            "--help" | "-h" => return Ok(Action::Help),
            "--text" => text = Some(required_value(arguments, &mut index, "--text")?),
            "--yes" => confirmed = true,
            argument if argument.starts_with('-') => {
                return Err(CliError::usage(format!(
                    "unknown agent input argument {argument:?}"
                )));
            }
            argument => positional.push(argument.to_owned()),
        }
        index += 1;
    }
    if positional.len() != 1 {
        return Err(CliError::usage("agent input requires SESSION_ID"));
    }
    let text = text.ok_or_else(|| CliError::usage("agent input requires --text"))?;
    Ok(Action::Agent(AgentAction::Input {
        session_id: positional[0].clone(),
        text,
        confirmed,
    }))
}

fn parse_agent_signal(arguments: &[String], stop: bool) -> Result<Action, CliError> {
    let mut positional = Vec::new();
    let mut confirmed = false;
    let mut index = 0;
    while index < arguments.len() {
        match arguments[index].as_str() {
            "--help" | "-h" => return Ok(Action::Help),
            "--yes" => confirmed = true,
            argument if argument.starts_with('-') => {
                return Err(CliError::usage(format!(
                    "unknown agent control argument {argument:?}"
                )));
            }
            argument => positional.push(argument.to_owned()),
        }
        index += 1;
    }
    if positional.len() != 1 {
        return Err(CliError::usage("agent control requires SESSION_ID"));
    }
    if stop {
        Ok(Action::Agent(AgentAction::Stop {
            session_id: positional[0].clone(),
            confirmed,
        }))
    } else {
        Ok(Action::Agent(AgentAction::Interrupt {
            session_id: positional[0].clone(),
            confirmed,
        }))
    }
}

fn parse_command(arguments: &[String]) -> Result<Action, CliError> {
    let Some(command_id) = arguments.first() else {
        return Err(CliError::usage("command requires COMMAND_ID"));
    };
    if command_id == "--help" || command_id == "-h" {
        return Ok(Action::Help);
    }
    let mut params = Value::Object(Map::new());
    let mut confirmed = false;
    let mut index = 1;
    while index < arguments.len() {
        match arguments[index].as_str() {
            "--help" | "-h" => return Ok(Action::Help),
            "--params" => {
                let raw = required_value(arguments, &mut index, "--params")?;
                params = serde_json::from_str(&raw)
                    .map_err(|error| CliError::usage(format!("invalid --params JSON: {error}")))?;
                if !params.is_object() {
                    return Err(CliError::usage("--params must contain a JSON object"));
                }
            }
            "--yes" => confirmed = true,
            other => {
                return Err(CliError::usage(format!(
                    "unknown command argument {other:?}"
                )));
            }
        }
        index += 1;
    }
    Ok(Action::Command(CommandAction {
        command_id: command_id.clone(),
        params,
        confirmed,
    }))
}

fn parse_mcp(arguments: &[String]) -> Result<Action, CliError> {
    if arguments == ["serve"] {
        Ok(Action::Mcp)
    } else if arguments
        .first()
        .is_some_and(|value| value == "--help" || value == "-h")
    {
        Ok(Action::Help)
    } else {
        Err(CliError::usage("mcp requires the serve subcommand"))
    }
}

fn execute_action(config: &Config, action: Action) -> Result<(), CliError> {
    match action {
        Action::Open { location } => {
            let (path, line, column) = parse_location(&location);
            let expanded = expand_path(&path)?;
            let mut params = Map::new();
            params.insert("path".to_owned(), Value::String(expanded));
            if let Some(line) = line {
                params.insert("line".to_owned(), Value::from(line));
            }
            if let Some(column) = column {
                params.insert("column".to_owned(), Value::from(column));
            }
            let response = request(
                config,
                "call",
                Some("navigation.openFile"),
                Some(Value::Object(params)),
                "cli",
                false,
            )?;
            print_response(&response)
        }
        Action::List => {
            let response = request(config, "list", None, None, "cli", false)?;
            print_response(&response)
        }
        Action::Agent(action) => execute_agent_action(config, action),
        Action::Command(action) => {
            let response = request(
                config,
                "call",
                Some(&action.command_id),
                Some(action.params),
                "cli",
                action.confirmed,
            )?;
            print_response(&response)
        }
        Action::Help | Action::Version | Action::Mcp => Err(CliError::runtime(
            "internal error: action was not executable",
        )),
    }
}

fn execute_agent_action(config: &Config, action: AgentAction) -> Result<(), CliError> {
    let (command_id, params, confirmed) = match action {
        AgentAction::List { project_id } => {
            let mut params = Map::new();
            if let Some(project_id) = project_id {
                params.insert("projectID".to_owned(), Value::String(project_id));
            }
            ("agent.list", Value::Object(params), false)
        }
        AgentAction::Status { session_id } => (
            "agent.status",
            object_params([(String::from("sessionID"), Value::String(session_id))]),
            false,
        ),
        AgentAction::Launch {
            project_id,
            profile_id,
            model_id,
            worktree_id,
            confirmed,
        } => {
            let mut params = Map::new();
            params.insert("projectID".to_owned(), Value::String(project_id));
            params.insert("profileID".to_owned(), Value::String(profile_id));
            if let Some(model_id) = model_id {
                params.insert("modelID".to_owned(), Value::String(model_id));
            }
            if let Some(worktree_id) = worktree_id {
                params.insert("worktreeID".to_owned(), Value::String(worktree_id));
            }
            ("agent.launch", Value::Object(params), confirmed)
        }
        AgentAction::Reveal {
            project_id,
            session_id,
        } => (
            "agent.reveal",
            object_params([
                (String::from("projectID"), Value::String(project_id)),
                (String::from("sessionID"), Value::String(session_id)),
            ]),
            false,
        ),
        AgentAction::Input {
            session_id,
            text,
            confirmed,
        } => (
            "agent.input",
            object_params([
                (String::from("sessionID"), Value::String(session_id)),
                (String::from("text"), Value::String(text)),
            ]),
            confirmed,
        ),
        AgentAction::Interrupt {
            session_id,
            confirmed,
        } => (
            "agent.interrupt",
            object_params([(String::from("sessionID"), Value::String(session_id))]),
            confirmed,
        ),
        AgentAction::Stop {
            session_id,
            confirmed,
        } => (
            "agent.stop",
            object_params([(String::from("sessionID"), Value::String(session_id))]),
            confirmed,
        ),
    };
    let response = request(
        config,
        "call",
        Some(command_id),
        Some(params),
        "cli",
        confirmed,
    )?;
    print_response(&response)
}

fn object_params<const N: usize>(entries: [(String, Value); N]) -> Value {
    Value::Object(entries.into_iter().collect())
}

fn request(
    config: &Config,
    operation: &str,
    command_id: Option<&str>,
    params: Option<Value>,
    source: &str,
    confirmed: bool,
) -> Result<Value, CliError> {
    ensure_running(config)?;
    let payload = build_request(operation, command_id, params, source, confirmed);
    send_json(&config.socket_path()?, &payload, DEFAULT_TIMEOUT)
}

fn ensure_running(config: &Config) -> Result<(), CliError> {
    let socket_path = config.socket_path()?;
    let probe = build_request("list", None, None, "cli", false);
    match send_json(&socket_path, &probe, PROBE_TIMEOUT) {
        Ok(_) => Ok(()),
        Err(error) if config.no_launch => {
            Err(CliError::runtime(format!("Clair is not running: {error}")))
        }
        Err(first_error) => {
            let app = config.application_path();
            if !app.exists() {
                return Err(CliError::runtime(format!(
                    "Clair is not running and the app was not found: {}",
                    app.display()
                )));
            }
            launch_application(&app)?;

            let deadline = Instant::now() + APP_READY_TIMEOUT;
            let mut last_error = first_error.to_string();
            while Instant::now() < deadline {
                match send_json(&socket_path, &probe, PROBE_TIMEOUT) {
                    Ok(_) => return Ok(()),
                    Err(error) => last_error = error.to_string(),
                }
                thread::sleep(RETRY_INTERVAL);
            }
            Err(CliError::runtime(format!(
                "Clair did not become ready: {last_error}"
            )))
        }
    }
}

fn build_request(
    operation: &str,
    command_id: Option<&str>,
    params: Option<Value>,
    source: &str,
    confirmed: bool,
) -> Value {
    let mut request = Map::new();
    request.insert("requestID".to_owned(), Value::String(request_id()));
    request.insert("operation".to_owned(), Value::String(operation.to_owned()));
    request.insert("source".to_owned(), Value::String(source.to_owned()));
    if let Some(command_id) = command_id {
        request.insert(
            "commandID".to_owned(),
            Value::String(
                command_id
                    .strip_prefix("clair.")
                    .unwrap_or(command_id)
                    .to_owned(),
            ),
        );
    }
    if let Some(params) = params {
        request.insert("params".to_owned(), params);
    }
    if confirmed {
        request.insert("confirmed".to_owned(), Value::Bool(true));
    }
    Value::Object(request)
}

fn request_id() -> String {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let counter = REQUEST_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("clair-cli-{}-{timestamp:x}-{counter:x}", process::id())
}

fn send_json(path: &Path, request: &Value, timeout: Duration) -> Result<Value, CliError> {
    let mut stream = UnixStream::connect(path).map_err(|error| {
        CliError::runtime(format!(
            "could not connect to Clair command socket {}: {error}",
            path.display()
        ))
    })?;
    stream.set_read_timeout(Some(timeout)).map_err(|error| {
        CliError::runtime(format!("could not configure command socket: {error}"))
    })?;
    stream.set_write_timeout(Some(timeout)).map_err(|error| {
        CliError::runtime(format!("could not configure command socket: {error}"))
    })?;

    let mut encoded = serde_json::to_vec(request)
        .map_err(|error| CliError::runtime(format!("could not encode command request: {error}")))?;
    encoded.push(b'\n');
    if encoded.len() > MAX_MESSAGE_BYTES {
        return Err(CliError::runtime(format!(
            "command request is too large ({} bytes)",
            encoded.len()
        )));
    }
    stream
        .write_all(&encoded)
        .map_err(|error| CliError::runtime(format!("could not write command request: {error}")))?;
    stream
        .shutdown(std::net::Shutdown::Write)
        .map_err(|error| CliError::runtime(format!("could not finish command request: {error}")))?;

    let mut response = Vec::new();
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        let count = stream.read(&mut buffer).map_err(|error| {
            CliError::runtime(format!("could not read command response: {error}"))
        })?;
        if count == 0 {
            break;
        }
        let bytes_to_append = buffer[..count]
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(count, |position| position + 1);
        if response.len() + bytes_to_append > MAX_MESSAGE_BYTES {
            return Err(CliError::runtime(format!(
                "command response is too large ({} bytes)",
                response.len() + bytes_to_append
            )));
        }
        response.extend_from_slice(&buffer[..bytes_to_append]);
        if bytes_to_append < count || buffer[count - 1] == b'\n' {
            break;
        }
    }

    let line = response
        .split(|byte| *byte == b'\n')
        .next()
        .filter(|line| !line.is_empty())
        .ok_or_else(|| CliError::runtime("Clair returned an empty command response"))?;
    let value: Value = serde_json::from_slice(line)
        .map_err(|_| CliError::runtime("Clair returned malformed command JSON"))?;
    if !value.is_object() {
        return Err(CliError::runtime(
            "Clair returned a non-object command response",
        ));
    }
    Ok(value)
}

fn print_response(response: &Value) -> Result<(), CliError> {
    let object = response
        .as_object()
        .ok_or_else(|| CliError::runtime("Clair returned a non-object command response"))?;
    let ok = object
        .get("ok")
        .and_then(Value::as_bool)
        .ok_or_else(|| CliError::runtime("Clair returned a response without an ok flag"))?;
    let output = if ok {
        object.get("result").cloned().unwrap_or(Value::Null)
    } else {
        object.get("error").cloned().unwrap_or(Value::Null)
    };
    let encoded = serde_json::to_string(&output)
        .map_err(|error| CliError::runtime(format!("could not encode command output: {error}")))?;
    if ok {
        println!("{encoded}");
        Ok(())
    } else {
        Err(CliError::runtime(encoded))
    }
}

fn handle_mcp(config: &Config) -> Result<(), CliError> {
    let stdin = io::stdin();
    let mut stdout = BufWriter::new(io::stdout().lock());
    for line in stdin.lock().lines() {
        let line =
            line.map_err(|error| CliError::runtime(format!("could not read MCP input: {error}")))?;
        if line.trim().is_empty() {
            continue;
        }
        let response = match serde_json::from_str::<Value>(&line) {
            Ok(message) => {
                let message_id = message.get("id").cloned().unwrap_or(Value::Null);
                match mcp_message(config, &message) {
                    Ok(Some(response)) => response,
                    Ok(None) => continue,
                    Err(error) => mcp_error(message_id, -32_000, &error),
                }
            }
            Err(error) => mcp_error(Value::Null, -32_700, &error.to_string()),
        };
        let encoded = serde_json::to_string(&response).map_err(|error| {
            CliError::runtime(format!("could not encode MCP response: {error}"))
        })?;
        writeln!(stdout, "{encoded}")
            .map_err(|error| CliError::runtime(format!("could not write MCP response: {error}")))?;
        stdout
            .flush()
            .map_err(|error| CliError::runtime(format!("could not flush MCP response: {error}")))?;
    }
    Ok(())
}

fn mcp_message(config: &Config, message: &Value) -> Result<Option<Value>, String> {
    let object = message
        .as_object()
        .ok_or_else(|| String::from("MCP request must be an object"))?;
    let message_id = object.get("id").cloned().unwrap_or(Value::Null);
    let method = object
        .get("method")
        .and_then(Value::as_str)
        .ok_or_else(|| String::from("MCP request requires a method"))?;
    match method {
        "initialize" => Ok(Some(json!({
            "jsonrpc": "2.0",
            "id": message_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "clair", "version": CLI_VERSION},
            },
        }))),
        "notifications/initialized" => Ok(None),
        "tools/list" => {
            let raw = request(config, "list", None, None, "mcp", false)
                .map_err(|error| error.to_string())?;
            let result = successful_result(&raw)?;
            let commands = result
                .get("commands")
                .and_then(Value::as_array)
                .ok_or_else(|| String::from("Clair returned an invalid command list"))?;
            let tools = commands
                .iter()
                .map(|command| {
                    let command = command.as_object().ok_or_else(|| {
                        String::from("Clair returned an invalid command descriptor")
                    })?;
                    let name = command
                        .get("name")
                        .and_then(Value::as_str)
                        .ok_or_else(|| String::from("Clair returned a command without a name"))?;
                    let title = command.get("title").and_then(Value::as_str).unwrap_or(name);
                    let description = command
                        .get("description")
                        .cloned()
                        .unwrap_or_else(|| Value::String(title.to_owned()));
                    let input_schema = command
                        .get("inputSchema")
                        .cloned()
                        .unwrap_or_else(|| Value::Object(Map::new()));
                    Ok(json!({
                        "name": name,
                        "description": description,
                        "inputSchema": input_schema,
                    }))
                })
                .collect::<Result<Vec<_>, String>>()?;
            Ok(Some(mcp_success(message_id, json!({"tools": tools}))))
        }
        "tools/call" => {
            let params = object
                .get("params")
                .and_then(Value::as_object)
                .ok_or_else(|| String::from("tools/call requires an object params value"))?;
            let name = params
                .get("name")
                .and_then(Value::as_str)
                .ok_or_else(|| String::from("tools/call requires a name"))?;
            let arguments = params
                .get("arguments")
                .cloned()
                .unwrap_or_else(|| Value::Object(Map::new()));
            if !arguments.is_object() {
                return Err(String::from("tools/call requires object arguments"));
            }
            let raw = request(config, "call", Some(name), Some(arguments), "mcp", false)
                .map_err(|error| error.to_string())?;
            let (content, is_error) = if raw.get("ok").and_then(Value::as_bool) == Some(true) {
                let result = raw.get("result").cloned().unwrap_or(Value::Null);
                let text = serde_json::to_string(&result).map_err(|error| error.to_string())?;
                (text, false)
            } else {
                let error = raw.get("error").cloned().unwrap_or(Value::Null);
                let text = serde_json::to_string(&error).map_err(|error| error.to_string())?;
                (text, true)
            };
            Ok(Some(mcp_success(
                message_id,
                json!({
                    "content": [{"type": "text", "text": content}],
                    "isError": is_error,
                }),
            )))
        }
        other => Ok(Some(mcp_error(
            message_id,
            -32_601,
            &format!("Method not found: {other}"),
        ))),
    }
}

fn successful_result(response: &Value) -> Result<&Map<String, Value>, String> {
    if response.get("ok").and_then(Value::as_bool) != Some(true) {
        let error = response.get("error").cloned().unwrap_or(Value::Null);
        return Err(serde_json::to_string(&error).map_err(|error| error.to_string())?);
    }
    response
        .get("result")
        .and_then(Value::as_object)
        .ok_or_else(|| String::from("Clair returned a command response without a result"))
}

fn mcp_success(message_id: Value, result: Value) -> Value {
    let mut response = Map::new();
    response.insert("jsonrpc".to_owned(), Value::String("2.0".to_owned()));
    response.insert("id".to_owned(), message_id);
    response.insert("result".to_owned(), result);
    Value::Object(response)
}

fn mcp_error(message_id: Value, code: i32, message: &str) -> Value {
    let mut error = Map::new();
    error.insert("code".to_owned(), Value::from(code));
    error.insert("message".to_owned(), Value::String(message.to_owned()));
    let mut response = Map::new();
    response.insert("jsonrpc".to_owned(), Value::String("2.0".to_owned()));
    response.insert("id".to_owned(), message_id);
    response.insert("error".to_owned(), Value::Object(error));
    Value::Object(response)
}

fn parse_location(value: &str) -> (String, Option<i64>, Option<i64>) {
    let pieces: Vec<&str> = value.rsplitn(3, ':').collect();
    if pieces.len() == 3 {
        if let (Ok(column), Ok(line)) = (pieces[0].parse(), pieces[1].parse()) {
            return (pieces[2].to_owned(), Some(line), Some(column));
        }
    }
    if pieces.len() >= 2 {
        if let Ok(line) = pieces[0].parse() {
            let path = pieces[1..]
                .iter()
                .rev()
                .copied()
                .collect::<Vec<_>>()
                .join(":");
            return (path, Some(line), None);
        }
    }
    (value.to_owned(), None, None)
}

fn expand_path(path: &str) -> Result<String, CliError> {
    let path = if path == "~" {
        env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or_else(|| CliError::usage("HOME is not set; cannot expand ~"))?
    } else if let Some(rest) = path.strip_prefix("~/") {
        env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or_else(|| CliError::usage("HOME is not set; cannot expand ~"))?
            .join(rest)
    } else {
        PathBuf::from(path)
    };
    let absolute = if path.is_absolute() {
        path
    } else {
        env::current_dir()
            .map_err(|error| {
                CliError::runtime(format!("could not read current directory: {error}"))
            })?
            .join(path)
    };
    Ok(fs::canonicalize(&absolute)
        .unwrap_or(absolute)
        .to_string_lossy()
        .into_owned())
}

fn launch_application(app: &Path) -> Result<(), CliError> {
    Command::new("open")
        .arg("-n")
        .arg(app)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| CliError::runtime(format!("could not launch Clair: {error}")))?;
    Ok(())
}

fn enclosing_app_bundle(path: &Path) -> Option<PathBuf> {
    path.ancestors()
        .find(|ancestor| ancestor.extension() == Some(OsStr::new("app")))
        .map(Path::to_path_buf)
}

fn usage_text() -> &'static str {
    "usage: clair [--channel stable|dev] [--no-launch] [--socket PATH] [--app PATH] <command>"
}

fn print_help() {
    println!(
        "{usage}\n\nCommands:\n  open PATH[:LINE[:COLUMN]]  Open a file in Clair\n  list                       List registered commands\n  agent list                 List known agent sessions\n  agent status SESSION_ID    Show one agent session\n  agent launch PROJECT_ID PROFILE_ID [--model MODEL] [--worktree-id ID] [--yes]\n                             Launch a registered agent profile\n  agent reveal PROJECT_ID SESSION_ID\n                             Reveal an agent session in Clair\n  agent input SESSION_ID --text TEXT [--yes]\n                             Send UTF-8 input to an agent PTY\n  agent interrupt SESSION_ID [--yes]\n                             Send Ctrl-C to an agent PTY\n  agent stop SESSION_ID [--yes]\n                             Stop an agent session\n  command COMMAND_ID [--params JSON] [--yes]\n                             Call any registered command\n  mcp serve                  Run the MCP stdio adapter\n\nMutating commands require --yes when used from the CLI.\nThe CLI talks to the same local command server used by Clair's other surfaces.",
        usage = usage_text()
    );
}

#[cfg(test)]
mod tests {
    use super::{
        Action, AgentAction, Channel, Config, enclosing_app_bundle, parse_arguments,
        parse_location, send_json,
    };
    use serde_json::json;
    use std::fs;
    use std::io::{Read, Write};
    use std::os::unix::net::UnixListener;
    use std::path::Path;
    use std::thread;
    use std::time::Duration;

    fn arguments(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    #[test]
    fn parses_agent_control_commands_with_explicit_confirmation() {
        let (config, action) = parse_arguments(&arguments(&[
            "--channel",
            "stable",
            "agent",
            "input",
            "session-1",
            "--text",
            "continue\n",
            "--yes",
        ]))
        .expect("agent input should parse");
        assert_eq!(config.channel, Channel::Stable);
        assert!(matches!(
            action,
            Action::Agent(AgentAction::Input {
                session_id,
                text,
                confirmed: true
            }) if session_id == "session-1" && text == "continue\n"
        ));
    }

    #[test]
    fn parses_generic_command_json_as_an_object() {
        let (_, action) = parse_arguments(&arguments(&[
            "command",
            "clair.agent.list",
            "--params",
            "{\"projectID\":\"project-1\"}",
        ]))
        .expect("generic command should parse");
        let Action::Command(command) = action else {
            panic!("expected generic command");
        };
        assert_eq!(command.command_id, "clair.agent.list");
        assert_eq!(command.params["projectID"], "project-1");
        assert!(!command.confirmed);
    }

    #[test]
    fn parses_path_locations_without_losing_colons() {
        assert_eq!(
            parse_location("/tmp/example.swift:12:4"),
            (String::from("/tmp/example.swift"), Some(12), Some(4))
        );
        assert_eq!(
            parse_location("/tmp/volume:name.swift:12"),
            (String::from("/tmp/volume:name.swift"), Some(12), None)
        );
        assert_eq!(
            parse_location("/tmp/example.swift"),
            (String::from("/tmp/example.swift"), None, None)
        );
    }

    #[test]
    fn discovers_an_enclosing_app_bundle() {
        let path = Path::new("/Applications/Clair.app/Contents/Resources/clair");
        assert_eq!(
            enclosing_app_bundle(path),
            Some(Path::new("/Applications/Clair.app").to_path_buf())
        );
    }

    #[test]
    fn exchanges_one_newline_delimited_json_response_over_unix_socket() {
        let root = Path::new("/private/tmp").join(format!(
            "clair-cli-test-{}-{}",
            std::process::id(),
            super::REQUEST_COUNTER.load(std::sync::atomic::Ordering::Relaxed)
        ));
        fs::create_dir_all(&root).expect("test directory should be created");
        let socket = root.join("command.sock");
        let listener = UnixListener::bind(&socket).expect("test socket should bind");
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("test client should connect");
            let mut request = Vec::new();
            stream
                .read_to_end(&mut request)
                .expect("test request should be readable");
            assert!(request.ends_with(b"\n"));
            let response = serde_json::to_vec(&json!({
                "requestID": "test",
                "ok": true,
                "result": {"kind": "agents"},
                "error": null
            }))
            .expect("test response should encode");
            stream
                .write_all(&[response, b"\n".to_vec()].concat())
                .expect("test response should be writable");
        });

        let response = send_json(
            &socket,
            &json!({"operation": "list"}),
            Duration::from_secs(1),
        )
        .expect("client should receive a response");
        assert_eq!(response["result"]["kind"], "agents");
        server.join().expect("test server should finish");
        fs::remove_dir_all(root).expect("test directory should be removed");
    }

    #[test]
    fn config_uses_the_channel_specific_socket_directory() {
        let config = Config {
            channel: Channel::Stable,
            no_launch: true,
            socket_override: None,
            app_override: None,
        };
        assert!(
            config
                .socket_path()
                .expect("HOME should be available in tests")
                .ends_with("Library/Application Support/Clair/command-v1.sock")
        );
    }
}
