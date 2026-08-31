use std::process::ExitCode;

const SMOKE_RESPONSE: &str = "clair-ptyhost/0 smoke=ok";

fn smoke_response() -> &'static str {
    SMOKE_RESPONSE
}

fn main() -> ExitCode {
    match std::env::args().nth(1).as_deref() {
        Some("--smoke") => {
            println!("{}", smoke_response());
            ExitCode::SUCCESS
        }
        Some("--version") => {
            println!("clair-ptyhost {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        None => {
            println!("clair-ptyhost {} (skeleton)", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        Some(argument) => {
            eprintln!("unknown argument: {argument}");
            eprintln!("usage: clair-ptyhost [--smoke|--version]");
            ExitCode::from(2)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::smoke_response;

    #[test]
    fn smoke_response_is_versioned_and_stable() {
        assert_eq!(smoke_response(), "clair-ptyhost/0 smoke=ok");
    }
}
