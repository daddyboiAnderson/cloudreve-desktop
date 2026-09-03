use crate::models::common::PaginationResults;
use crate::models::explorer::{PermissionSettingReq, Share};
use serde::{de::Deserializer, Deserialize, Serialize};

fn deserialize_null_default<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de> + Default,
{
    Ok(Option::<T>::deserialize(deserializer)?.unwrap_or_default())
}

/// Parameters used when creating or editing a share link.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ShareLinkRequest {
    pub permissions: PermissionSettingReq,
    pub uri: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_private: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub share_view: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expire: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub downloads: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub price: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub password: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub show_readme: Option<bool>,
}

/// List share service
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListShareService {
    pub page_size: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub order_by: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub order_direction: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next_page_token: Option<String>,
}

/// List share response
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ListShareResponse {
    #[serde(default, deserialize_with = "deserialize_null_default")]
    pub shares: Vec<Share>,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    pub pagination: PaginationResults,
}

#[cfg(test)]
mod tests {
    use super::{ListShareResponse, ShareLinkRequest};

    #[test]
    fn accepts_null_share_list() {
        let response: ListShareResponse = serde_json::from_str(
            r#"{"shares":null,"pagination":{"page":1,"page_size":100}}"#,
        )
        .unwrap();

        assert!(response.shares.is_empty());
        assert_eq!(response.pagination.page, 1);
    }

    #[test]
    fn accepts_null_pagination() {
        let response: ListShareResponse =
            serde_json::from_str(r#"{"shares":[],"pagination":null}"#).unwrap();

        assert!(response.shares.is_empty());
        assert_eq!(response.pagination.page, 0);
    }

    #[test]
    fn serializes_download_limit() {
        let request = ShareLinkRequest {
            uri: "cloudreve://my/report.pdf".to_string(),
            downloads: Some(1),
            ..Default::default()
        };
        let value = serde_json::to_value(request).unwrap();

        assert_eq!(value["downloads"], 1);
    }
}
