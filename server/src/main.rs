/// mimalloc on Linux: fast, and it keeps a long-running server's memory from fragmenting and
/// slowly growing over weeks. Elsewhere the system allocator is used (it measured better on
/// macOS).
#[cfg(target_os = "linux")]
#[global_allocator]
static ALLOCATOR: mimalloc::MiMalloc = mimalloc::MiMalloc;

fn main() -> std::process::ExitCode {
    halden::cli::main()
}
