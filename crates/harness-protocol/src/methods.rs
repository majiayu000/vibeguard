use serde::{Deserialize, Serialize};

/// JSON-RPC method identifiers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Method {
    Initialize,
    ThreadStart,
    ThreadDelete,
    TurnStart,
    TurnComplete,
    Shutdown,
}

/// JSON-RPC request.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RpcRequest {
    pub method: Method,
    pub params: serde_json::Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
}

/// JSON-RPC error object.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RpcError {
    pub code: i32,
    pub message: String,
}

/// JSON-RPC response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RpcResponse {
    pub id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

impl RpcResponse {
    /// Create a success response.
    pub fn success(id: u64, result: serde_json::Value) -> Self {
        Self {
            id,
            result: Some(result),
            error: None,
        }
    }

    /// Create an error response.
    pub fn error(id: u64, code: i32, message: &str) -> Self {
        Self {
            id,
            result: None,
            error: Some(RpcError {
                code,
                message: message.to_string(),
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rpc_response_success_serialization() {
        let resp = RpcResponse::success(1, serde_json::json!({"status": "ok"}));
        let json = serde_json::to_value(&resp).expect("serialize");
        assert_eq!(json["id"], 1);
        assert_eq!(json["result"]["status"], "ok");
        assert!(json.get("error").is_none());
    }

    #[test]
    fn rpc_response_error_serialization() {
        let resp = RpcResponse::error(2, -32600, "invalid request");
        let json = serde_json::to_value(&resp).expect("serialize");
        assert_eq!(json["id"], 2);
        assert!(json.get("result").is_none());
        assert_eq!(json["error"]["code"], -32600);
        assert_eq!(json["error"]["message"], "invalid request");
    }

    #[test]
    fn method_serde_round_trip() {
        let methods = vec![Method::Initialize, Method::ThreadStart];
        for method in methods {
            let json = serde_json::to_string(&method).expect("serialize method");
            let decoded: Method = serde_json::from_str(&json).expect("deserialize method");
            assert_eq!(decoded, method);
        }
    }
}
