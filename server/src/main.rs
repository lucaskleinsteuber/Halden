/// The system allocator is used: it measured better than mimalloc for Halden on macOS and on
/// Linux (see `docs/TESTING.md`). `--features mimalloc` builds with mimalloc to compare again.
#[cfg(feature = "mimalloc")]
#[global_allocator]
static ALLOCATOR: mimalloc::MiMalloc = mimalloc::MiMalloc;

fn main() -> std::process::ExitCode {
    halden::cli::main()
}
