//! Small UTC time helpers used by log-query and session-metrics code.

/// Returns seconds since Unix epoch via SystemTime.
pub(crate) fn now_unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// Returns milliseconds since Unix epoch via SystemTime.
pub(crate) fn now_unix_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

/// Parse ISO 8601 timestamp to Unix seconds.
/// Returns None if the string cannot be parsed.
pub(crate) fn parse_iso_ts(ts: &str) -> Option<u64> {
    let s = ts.trim();
    let (date_part, time_part) = s.split_once('T')?;
    let dp: Vec<&str> = date_part.split('-').collect();
    if dp.len() != 3 {
        return None;
    }
    let year: i64 = dp[0].parse().ok()?;
    let month: i64 = dp[1].parse().ok()?;
    let day: i64 = dp[2].parse().ok()?;
    if !(1..=12).contains(&month) {
        return None;
    }
    let (time_part, offset_secs) = split_iso_time_and_offset(time_part)?;
    let tp: Vec<&str> = time_part.split(':').collect();
    if tp.len() != 3 {
        return None;
    }
    let hour: i64 = tp[0].parse().ok()?;
    let min: i64 = tp[1].parse().ok()?;
    let sec_part = match tp[2].split_once('.') {
        Some((whole, fraction)) => {
            if whole.is_empty()
                || fraction.is_empty()
                || !fraction.bytes().all(|b| b.is_ascii_digit())
            {
                return None;
            }
            whole
        }
        None => tp[2],
    };
    let sec: i64 = sec_part.parse().ok()?;
    if !(0..=23).contains(&hour) || !(0..=59).contains(&min) || !(0..=59).contains(&sec) {
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

    let total =
        days_from_civil(year, month, day) * 86400 + hour * 3600 + min * 60 + sec - offset_secs;
    if total < 0 {
        return None;
    }
    Some(total as u64)
}

fn split_iso_time_and_offset(time_part: &str) -> Option<(&str, i64)> {
    if let Some(stripped) = time_part.strip_suffix('Z') {
        return Some((stripped, 0));
    }
    if time_part.len() >= 6 {
        let offset_start = time_part.len() - 6;
        let sign = time_part.as_bytes()[offset_start];
        if matches!(sign, b'+' | b'-') && time_part.as_bytes()[offset_start + 3] == b':' {
            let hours: i64 = time_part[offset_start + 1..offset_start + 3].parse().ok()?;
            let mins: i64 = time_part[offset_start + 4..offset_start + 6].parse().ok()?;
            if hours > 23 || mins > 59 {
                return None;
            }
            let offset = hours * 3600 + mins * 60;
            let signed_offset = if sign == b'+' { offset } else { -offset };
            return Some((&time_part[..offset_start], signed_offset));
        }
    }
    Some((time_part, 0))
}

fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = year - if month <= 2 { 1 } else { 0 };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let m = month + if month > 2 { -3 } else { 9 };
    let doy = (153 * m + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
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
