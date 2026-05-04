fn main() {
    if let Err(error) = codex_backup::cli::run() {
        eprintln!("error: {error:#}");
        std::process::exit(1);
    }
}
