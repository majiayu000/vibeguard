use criterion::{Criterion, black_box, criterion_group, criterion_main};
use vibeguard_runtime::core_classifiers::{classify_bash_command, classify_clean_rust_write};

fn core_us(c: &mut Criterion) {
    let mut group = c.benchmark_group("core_us");

    group.bench_function("bash_destructive_restore", |bench| {
        bench.iter(|| {
            classify_bash_command(black_box("git restore ."), black_box("/tmp/vibeguard"))
        });
    });

    group.bench_function("bash_package_rewrite", |bench| {
        bench.iter(|| {
            classify_bash_command(
                black_box("npm install serde_json --save-dev"),
                black_box("/tmp/vibeguard"),
            )
        });
    });

    group.bench_function("write_clean_rust_fast_path", |bench| {
        bench.iter(|| {
            classify_clean_rust_write(
                black_box("src/new_file.rs"),
                black_box("let value = 1;\nlet doubled = value * 2;\n"),
                black_box(800),
            )
        });
    });

    group.finish();
}

criterion_group!(benches, core_us);
criterion_main!(benches);
