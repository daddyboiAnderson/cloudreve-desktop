use cloudreve_api::models::uri::CrUri;
use std::{collections::HashSet, future::Future};

/// Exclude the incoming link from the recipient's manageable links.
pub fn can_manage_share(
    share: &cloudreve_api::models::explorer::Share,
    user_id: &str,
    target_uri: &str,
) -> bool {
    let incoming = CrUri::new(target_uri)
        .ok()
        .filter(|uri| matches!(uri.fs().as_str(), "shared_with_me" | "share"));
    !user_id.is_empty()
        && share.owner.id == user_id
        && !incoming.is_some_and(|uri| uri.id() == share.id)
}

/// Resolve server-provided shortcuts. Cloudreve still enforces access.
pub async fn resolve<F, Fut>(uri: &str, mut lookup: F) -> Result<String, String>
where
    F: FnMut(String) -> Fut,
    Fut: Future<Output = Result<Option<String>, String>>,
{
    let mut current = CrUri::new(uri).map_err(|e| e.to_string())?;
    let mut visited = HashSet::new();
    for _ in 0..32 {
        if !visited.insert(current.to_string()) {
            return Err("This shared shortcut contains a circular reference".into());
        }
        let elements = current.elements();
        let mut prefix = current.clone();
        prefix.set_path("");
        let mut redirected = false;
        for (index, element) in elements.iter().enumerate() {
            prefix.join(&[element]);
            if let Some(target) = lookup(prefix.to_string()).await? {
                let mut target = CrUri::new(&target).map_err(|e| e.to_string())?;
                if target.is_search() {
                    return Err("Invalid shared shortcut target".into());
                }
                for child in &elements[index + 1..] {
                    target.join(&[child]);
                }
                current = target;
                redirected = true;
                break;
            }
        }
        if !redirected {
            return Ok(current.to_string());
        }
    }
    Err("Too many shared shortcut redirects".into())
}

#[cfg(test)]
mod tests {
    #[test]
    fn incoming_links_are_not_manageable_even_when_resharing_is_allowed() {
        use cloudreve_api::models::{explorer::Share, user::User};
        let incoming = Share {
            owner: User {
                id: "sender".into(),
                ..Default::default()
            },
            permissions: Some("all".into()),
            ..Default::default()
        };
        let own = Share {
            owner: User {
                id: "recipient".into(),
                ..Default::default()
            },
            ..Default::default()
        };
        assert!(!super::can_manage_share(
            &incoming,
            "recipient",
            "cloudreve://my/file.txt"
        ));
        assert!(super::can_manage_share(
            &own,
            "recipient",
            "cloudreve://my/file.txt"
        ));
        assert!(!super::can_manage_share(
            &Share::default(),
            "",
            "cloudreve://my/file.txt"
        ));
        let originating_link = Share {
            id: "incoming-link".into(),
            ..own.clone()
        };
        assert!(!super::can_manage_share(
            &originating_link,
            "recipient",
            "cloudreve://incoming-link@shared_with_me/"
        ));
        assert!(!super::can_manage_share(
            &originating_link,
            "recipient",
            "cloudreve://incoming-link@shared_with_me/child.txt"
        ));
        assert!(super::can_manage_share(
            &own,
            "recipient",
            "cloudreve://incoming-link@shared_with_me/"
        ));
    }
    use super::*;

    #[tokio::test]
    async fn resolves_nested_shortcuts_and_preserves_special_names() {
        let resolved = resolve(
            "cloudreve://my/Shared/nested/file%20%23%25.txt",
            |uri| async move {
                Ok(match uri.as_str() {
                    "cloudreve://my/Shared" => Some("cloudreve://abc@shared_with_me/".into()),
                    "cloudreve://abc@shared_with_me/nested" => {
                        Some("cloudreve://xyz@shared_with_me/sub".into())
                    }
                    _ => None,
                })
            },
        )
        .await
        .unwrap();
        assert_eq!(
            resolved,
            "cloudreve://xyz@shared_with_me/sub/file%20%23%25.txt"
        );
    }

    #[tokio::test]
    async fn rejects_cycles_and_permission_errors() {
        assert!(resolve("cloudreve://my/loop", |_| async {
            Ok(Some("cloudreve://my/loop".into()))
        })
        .await
        .unwrap_err()
        .contains("circular"));
        assert_eq!(
            resolve("cloudreve://my/denied/file", |_| async {
                Err("Permission denied".into())
            })
            .await
            .unwrap_err(),
            "Permission denied"
        );
        assert_eq!(
            resolve("cloudreve://my/ordinary", |_| async { Ok(None) })
                .await
                .unwrap(),
            "cloudreve://my/ordinary"
        );
    }
}
