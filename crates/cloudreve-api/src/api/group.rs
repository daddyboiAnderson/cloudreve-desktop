use crate::client::{Client, RequestOptions};
use crate::error::ApiResult;
use crate::models::user::Group;
use async_trait::async_trait;

/// Group API methods.
#[async_trait]
pub trait GroupApi {
    /// List groups available to the authenticated user.
    async fn list_groups(&self) -> ApiResult<Vec<Group>>;
}

#[async_trait]
impl GroupApi for Client {
    async fn list_groups(&self) -> ApiResult<Vec<Group>> {
        self.get("/group/list", RequestOptions::new()).await
    }
}
