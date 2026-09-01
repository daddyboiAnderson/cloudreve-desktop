use crate::client::{Client, RequestOptions};
use crate::error::ApiResult;
use crate::models::explorer::Share;
use crate::models::share::{ListShareResponse, ListShareService, ShareLinkRequest};
use async_trait::async_trait;

/// Share-link API methods.
#[async_trait]
pub trait ShareApi {
    /// Create a share link and return its public URL.
    async fn create_share_link(&self, request: &ShareLinkRequest) -> ApiResult<String>;

    /// Update an existing share link and return its public URL.
    async fn edit_share_link(
        &self,
        share_id: &str,
        request: &ShareLinkRequest,
    ) -> ApiResult<String>;

    /// Get the complete settings for one share link.
    async fn get_share_link_info(&self, share_id: &str) -> ApiResult<Share>;

    /// List share links owned by the current user.
    async fn list_share_links(&self, params: &ListShareService) -> ApiResult<ListShareResponse>;

    /// Delete one share link.
    async fn delete_share_link(&self, share_id: &str) -> ApiResult<()>;
}

#[async_trait]
impl ShareApi for Client {
    async fn create_share_link(&self, request: &ShareLinkRequest) -> ApiResult<String> {
        self.put("/share", request, RequestOptions::new()).await
    }

    async fn edit_share_link(
        &self,
        share_id: &str,
        request: &ShareLinkRequest,
    ) -> ApiResult<String> {
        self.post(
            &format!("/share/{}", urlencoding::encode(share_id)),
            request,
            RequestOptions::new(),
        )
        .await
    }

    async fn get_share_link_info(&self, share_id: &str) -> ApiResult<Share> {
        self.get(
            &format!("/share/info/{}", urlencoding::encode(share_id)),
            RequestOptions::new(),
        )
        .await
    }

    async fn list_share_links(&self, params: &ListShareService) -> ApiResult<ListShareResponse> {
        let mut query = vec![format!("page_size={}", params.page_size)];
        if let Some(order_by) = &params.order_by {
            query.push(format!("order_by={}", urlencoding::encode(order_by)));
        }
        if let Some(order_direction) = &params.order_direction {
            query.push(format!(
                "order_direction={}",
                urlencoding::encode(order_direction)
            ));
        }
        if let Some(next_page_token) = &params.next_page_token {
            query.push(format!(
                "next_page_token={}",
                urlencoding::encode(next_page_token)
            ));
        }

        self.get(
            &format!("/share?{}", query.join("&")),
            RequestOptions::new(),
        )
        .await
    }

    async fn delete_share_link(&self, share_id: &str) -> ApiResult<()> {
        self.delete(
            &format!("/share/{}", urlencoding::encode(share_id)),
            RequestOptions::new(),
        )
        .await
    }
}
