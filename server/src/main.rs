/// mimalloc instead of the system allocator: faster, and it keeps a long-running server's memory
/// from fragmenting and slowly growing over weeks.
#[global_allocator]
static ALLOCATOR: mimalloc::MiMalloc = mimalloc::MiMalloc;

fn main() -> std::process::ExitCode {
    halden::cli::main()
}
