//! Small UTC time helpers used by log-query and session-metrics code.

/// Returns seconds since Unix epoch via SystemTime.
pub(crate) fn now_unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// Parse ISO 8601 UTC timestamp (YYYY-MM-DDTHH:MM:SSZ or +00:00) to Unix seconds.
/// Returns None if the string cannot be parsed.
pub(crate) fn parse_iso_ts(ts: &str) -> Option<u64> {
    let s = ts.trim_end_matches('Z');
    let s = s.strip_suffix("+00:00").unwrap_or(s);
    let (date_part, time_part) = s.split_once('T')?;
    let dp: Vec<&str> = date_part.split('-').collect();
    let tp: Vec<&str> = time_part.split(':').collect();
    if dp.len() < 3 || tp.len() < 3 {
        return None;
    }
    let year: i64 = dp[0].parse().ok()?;
    let month: i64 = dp[1].parse().ok()?;
    let day: i64 = dp[2].parse().ok()?;
    if month < 1 || month > 12 {
        return None;
    }
    let hour: i64 = tp[0].parse().ok()?;
    let min: i64 = tp[1].parse().ok()?;
    let sec: i64 = tp[2].trim_end_matches('Z').parse().ok()?;
    if hour < 0 || hour > 23 || min < 0 || min > 59 || sec < 0 || sec > 59 {
        return None;
    }

    let is_leap = |y: i64| (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let month_days: [i64; 12] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let max_day = if month == 2 && is_leap(year) {
        29
    } else {
        month_days[(month - 1) as usize]
    };
    if day < 1 || day > max_day {
        return None;
    }

    let mut days: i64 = 0;
    for y in 1970..year {
        days += if is_leap(y) { 366 } else { 365 };
    }
    for m in 1..month {
        days += month_days[(m - 1) as usize];
        if m == 2 && is_leap(year) {
            days += 1;
        }
    }
    days += day - 1;

    let total = days * 86400 + hour * 3600 + min * 60 + sec;
    if total < 0 {
        return None;
    }
    Some(total as u64)
}

pub(crate) fn format_unix_secs_utc(secs: u64) -> String {
    let days = (secs / 86400) as i64;
    let second_of_day = secs % 86400;
    let (year, month, day) = civil_from_days(days);
    let hour = second_of_day / 3600;
    let min = (second_of_day % 3600) / 60;
    let sec = second_of_day % 60;
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{min:02}:{sec:02}Z")
}

fn civil_from_days(days_since_epoch: i64) -> (i64, u32, u32) {
    let z = days_since_epoch + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = mp + if mp < 10 { 3 } else { -9 };
    let year = y + if m <= 2 { 1 } else { 0 };
    (year, m as u32, d as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unix_epoch_formats_as_utc_iso() {
        assert_eq!(format_unix_secs_utc(0), "1970-01-01T00:00:00Z");
    }

    #[test]
    fn parser_and_formatter_roundtrip_known_leap_day() {
        let ts = "2024-02-29T12:34:56Z";
        assert_eq!(format_unix_secs_utc(parse_iso_ts(ts).unwrap()), ts);
    }
}
