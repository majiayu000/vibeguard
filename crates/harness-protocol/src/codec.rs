use crate::methods::{RpcRequest, RpcResponse};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum CodecError {
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("missing newline delimiter")]
    MissingDelimiter,
}

/// Encode a response as a JSONL line.
pub fn encode_response(resp: &RpcResponse) -> Result<String, CodecError> {
    let mut line = serde_json::to_string(resp)?;
    line.push('\n');
    Ok(line)
}

/// Decode a response from a JSONL line.
pub fn decode_response(line: &str) -> Result<RpcResponse, CodecError> {
    let trimmed = line.trim_end_matches('\n');
    let resp: RpcResponse = serde_json::from_str(trimmed)?;
    Ok(resp)
}

/// Decode a request from a JSON string.
pub fn decode_request(input: &str) -> Result<RpcRequest, CodecError> {
    let trimmed = input.trim_end_matches('\n');
    let req: RpcRequest = serde_json::from_str(trimmed)?;
    Ok(req)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_decode_response_round_trip() {
        let resp = RpcResponse::success(42, serde_json::json!({"data": [1, 2, 3]}));
        let encoded = encode_response(&resp).expect("encode");
        assert!(encoded.ends_with('\n'));

        let decoded = decode_response(&encoded).expect("decode");
        assert_eq!(decoded.id, 42);
        assert_eq!(
            decoded.result.expect("should have result")["data"],
            serde_json::json!([1, 2, 3])
        );
    }

    #[test]
    fn decode_request_with_valid_json() {
        let input = r#"{"method":"initialize","params":{"version":"1.0"},"id":1}"#;
        let req = decode_request(input).expect("decode request");
        assert_eq!(req.method, crate::methods::Method::Initialize);
        assert_eq!(req.id, Some(1));
        assert_eq!(req.params["version"], "1.0");
    }
}
