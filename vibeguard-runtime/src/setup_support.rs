use serde_json::Value;
use std::collections::hash_map::DefaultHasher;
use std::fs::{self, File};
use std::hash::{Hash, Hasher};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub type SetupResult<T> = Result<T, Box<dyn std::error::Error>>;

pub fn read_json_object(
    path: &Path,
    missing_as_empty: bool,
) -> SetupResult<serde_json::Map<String, Value>> {
    if missing_as_empty && !path.exists() {
        return Ok(serde_json::Map::new());
    }
    let text = fs::read_to_string(path)?;
    let value: Value = serde_json::from_str(&text)?;
    value
        .as_object()
        .cloned()
        .ok_or_else(|| format!("{} root must be an object", path.display()).into())
}

pub fn write_text_atomic(path: &Path, content: &str) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = temp_path_for(path);
    {
        let mut file = File::create(&tmp)?;
        file.write_all(content.as_bytes())?;
        file.sync_all()?;
    }
    fs::rename(&tmp, path)?;
    if let Some(parent) = path.parent() {
        let _ = File::open(parent).and_then(|file| file.sync_all());
    }
    Ok(())
}

pub fn write_json_atomic(path: &Path, value: &Value) -> SetupResult<()> {
    let text = serde_json::to_string_pretty(value)? + "\n";
    write_text_atomic(path, &text)?;
    Ok(())
}

pub fn sha256_file(path: &Path) -> SetupResult<String> {
    let mut file = File::open(path)?;
    let mut data = Vec::new();
    file.read_to_end(&mut data)?;
    let mut hasher = sha256::Sha256::new();
    hasher.update(&data);
    Ok(hasher.digest().to_string())
}

pub fn display_home_path(path: &Path) -> String {
    if let Some(home) = home_dir() {
        if let Ok(rel) = path.strip_prefix(&home) {
            return format!("~/{}", rel.display());
        }
    }
    path.display().to_string()
}

pub fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

pub fn shell_split(command: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut current = String::new();
    let mut chars = command.chars().peekable();
    let mut quote: Option<char> = None;
    let mut escaped = false;

    while let Some(ch) = chars.next() {
        if escaped {
            current.push(ch);
            escaped = false;
            continue;
        }
        if ch == '\\' && quote != Some('\'') {
            escaped = true;
            continue;
        }
        if let Some(active) = quote {
            if ch == active {
                quote = None;
            } else {
                current.push(ch);
            }
            continue;
        }
        match ch {
            '\'' | '"' => quote = Some(ch),
            c if c.is_whitespace() => {
                if !current.is_empty() {
                    out.push(std::mem::take(&mut current));
                }
                while matches!(chars.peek(), Some(next) if next.is_whitespace()) {
                    chars.next();
                }
            }
            _ => current.push(ch),
        }
    }
    if !current.is_empty() {
        out.push(current);
    }
    out
}

pub fn shell_quote(value: &str) -> String {
    if value.chars().all(|ch| {
        ch.is_ascii_alphanumeric() || matches!(ch, '/' | '.' | '_' | '-' | ':' | '@' | '%')
    }) {
        return value.to_string();
    }
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

pub fn basename(text: &str) -> &str {
    text.rsplit('/').next().unwrap_or(text)
}

pub fn simple_unified_diff(path: &Path, before: &str, after: &str) -> String {
    let mut diff = String::new();
    let label = path.display();
    diff.push_str(&format!("--- {label}\n+++ {label}\n"));
    diff.push_str("@@\n");
    for line in before.split_inclusive('\n') {
        diff.push('-');
        diff.push_str(line);
        if !line.ends_with('\n') {
            diff.push('\n');
        }
    }
    for line in after.split_inclusive('\n') {
        diff.push('+');
        diff.push_str(line);
        if !line.ends_with('\n') {
            diff.push('\n');
        }
    }
    diff
}

fn temp_path_for(path: &Path) -> PathBuf {
    let mut hasher = DefaultHasher::new();
    std::process::id().hash(&mut hasher);
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
        .hash(&mut hasher);
    let suffix = hasher.finish();
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("vibeguard");
    path.with_file_name(format!(".{file_name}.{suffix}.tmp"))
}

mod sha256 {
    pub struct Sha256 {
        state: [u32; 8],
        data: [u8; 64],
        datalen: usize,
        bitlen: u64,
    }

    impl Sha256 {
        pub fn new() -> Self {
            Self {
                state: [
                    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c,
                    0x1f83d9ab, 0x5be0cd19,
                ],
                data: [0; 64],
                datalen: 0,
                bitlen: 0,
            }
        }

        pub fn update(&mut self, input: &[u8]) {
            for &byte in input {
                self.data[self.datalen] = byte;
                self.datalen += 1;
                if self.datalen == 64 {
                    self.transform();
                    self.bitlen += 512;
                    self.datalen = 0;
                }
            }
        }

        pub fn digest(mut self) -> Digest {
            let i = self.datalen;
            if self.datalen < 56 {
                self.data[i] = 0x80;
                for item in &mut self.data[i + 1..56] {
                    *item = 0;
                }
            } else {
                self.data[i] = 0x80;
                for item in &mut self.data[i + 1..64] {
                    *item = 0;
                }
                self.transform();
                self.data = [0; 64];
            }
            self.bitlen += (self.datalen as u64) * 8;
            self.data[56..64].copy_from_slice(&self.bitlen.to_be_bytes());
            self.transform();
            let mut out = [0u8; 32];
            for (idx, value) in self.state.iter().enumerate() {
                out[idx * 4..idx * 4 + 4].copy_from_slice(&value.to_be_bytes());
            }
            Digest(out)
        }

        fn transform(&mut self) {
            const K: [u32; 64] = [
                0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
                0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
                0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
                0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
                0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
                0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
                0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
                0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
                0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
                0xc67178f2,
            ];
            let mut m = [0u32; 64];
            for (idx, chunk) in self.data.chunks_exact(4).take(16).enumerate() {
                m[idx] = u32::from_be_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
            }
            for idx in 16..64 {
                let s0 =
                    m[idx - 15].rotate_right(7) ^ m[idx - 15].rotate_right(18) ^ (m[idx - 15] >> 3);
                let s1 =
                    m[idx - 2].rotate_right(17) ^ m[idx - 2].rotate_right(19) ^ (m[idx - 2] >> 10);
                m[idx] = m[idx - 16]
                    .wrapping_add(s0)
                    .wrapping_add(m[idx - 7])
                    .wrapping_add(s1);
            }
            let mut a = self.state[0];
            let mut b = self.state[1];
            let mut c = self.state[2];
            let mut d = self.state[3];
            let mut e = self.state[4];
            let mut f = self.state[5];
            let mut g = self.state[6];
            let mut h = self.state[7];
            for idx in 0..64 {
                let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
                let ch = (e & f) ^ ((!e) & g);
                let temp1 = h
                    .wrapping_add(s1)
                    .wrapping_add(ch)
                    .wrapping_add(K[idx])
                    .wrapping_add(m[idx]);
                let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
                let maj = (a & b) ^ (a & c) ^ (b & c);
                let temp2 = s0.wrapping_add(maj);
                h = g;
                g = f;
                f = e;
                e = d.wrapping_add(temp1);
                d = c;
                c = b;
                b = a;
                a = temp1.wrapping_add(temp2);
            }
            self.state[0] = self.state[0].wrapping_add(a);
            self.state[1] = self.state[1].wrapping_add(b);
            self.state[2] = self.state[2].wrapping_add(c);
            self.state[3] = self.state[3].wrapping_add(d);
            self.state[4] = self.state[4].wrapping_add(e);
            self.state[5] = self.state[5].wrapping_add(f);
            self.state[6] = self.state[6].wrapping_add(g);
            self.state[7] = self.state[7].wrapping_add(h);
        }
    }

    pub struct Digest([u8; 32]);

    impl std::fmt::Display for Digest {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            for byte in self.0 {
                write!(f, "{byte:02x}")?;
            }
            Ok(())
        }
    }
}
