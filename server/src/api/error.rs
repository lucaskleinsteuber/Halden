//! Errors as the apps see them: a status code and a JSON body
//! `{"error": "invalid_credentials", "message": "…"}`. `error` is stable and meant for code,
//! `message` is an English sentence that may be shown to the person.

use axum::{
    Json,
    http::{HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use serde_json::json;

use crate::{accounts::AccountError, auth::ratelimit::RetryAfter};

#[derive(Debug)]
pub struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: String,
    retry_after: Option<u64>,
    /// Where an upload stands; sent as `Upload-Offset` and as `offset` in the body.
    offset: Option<u64>,
}

impl ApiError {
    pub fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            code,
            message: message.into(),
            retry_after: None,
            offset: None,
        }
    }

    pub fn with_offset(mut self, offset: u64) -> Self {
        self.offset = Some(offset);
        self
    }

    pub fn status(&self) -> StatusCode {
        self.status
    }

    pub fn code(&self) -> &'static str {
        self.code
    }

    /// No token, or one that doesn't work (any more). The app should sign in again.
    pub fn unauthorized(message: impl Into<String>) -> Self {
        Self::new(StatusCode::UNAUTHORIZED, "unauthorized", message)
    }

    /// The same answer for a wrong password and an unknown username.
    pub fn invalid_credentials() -> Self {
        Self::new(
            StatusCode::UNAUTHORIZED,
            "invalid_credentials",
            "The username or password is wrong.",
        )
    }

    pub fn invalid_code() -> Self {
        Self::new(
            StatusCode::UNAUTHORIZED,
            "invalid_credentials",
            "The pairing code is wrong, expired or already used.",
        )
    }

    /// The signed-in person confirmed an action with the wrong password.
    pub fn wrong_current_password() -> Self {
        Self::new(
            StatusCode::FORBIDDEN,
            "invalid_credentials",
            "Your current password is wrong.",
        )
    }

    pub fn rate_limited(wait: RetryAfter) -> Self {
        let seconds = wait.seconds();
        Self {
            retry_after: Some(seconds),
            ..Self::new(
                StatusCode::TOO_MANY_REQUESTS,
                "rate_limited",
                format!("Too many attempts. Try again in {seconds} seconds."),
            )
        }
    }

    pub fn device_blocked() -> Self {
        Self::new(
            StatusCode::FORBIDDEN,
            "device_blocked",
            "This device was blocked for this account.",
        )
    }

    pub fn forbidden(message: impl Into<String>) -> Self {
        Self::new(StatusCode::FORBIDDEN, "forbidden", message)
    }

    pub fn password_required(message: impl Into<String>) -> Self {
        Self::new(StatusCode::FORBIDDEN, "password_required", message)
    }

    pub fn password_login_disabled() -> Self {
        Self::new(
            StatusCode::FORBIDDEN,
            "password_login_disabled",
            "Signing in with a password is turned off on this server. Pair the device with a QR code instead.",
        )
    }

    pub fn validation(message: impl Into<String>) -> Self {
        Self::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "validation_failed",
            message,
        )
    }

    pub fn not_found() -> Self {
        Self::new(StatusCode::NOT_FOUND, "not_found", "There is nothing here.")
    }

    pub fn conflict(message: impl Into<String>) -> Self {
        Self::new(StatusCode::CONFLICT, "conflict", message)
    }

    pub fn unsupported_media_type(message: impl Into<String>) -> Self {
        Self::new(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "unsupported_media_type",
            message,
        )
    }

    pub fn too_large(message: impl Into<String>) -> Self {
        Self::new(StatusCode::PAYLOAD_TOO_LARGE, "too_large", message)
    }

    pub fn insufficient_storage(message: impl Into<String>) -> Self {
        Self::new(
            StatusCode::INSUFFICIENT_STORAGE,
            "insufficient_storage",
            message,
        )
    }

    pub fn internal() -> Self {
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "internal_error",
            "Something went wrong on the server. Its log has the details.",
        )
    }
}

impl From<AccountError> for ApiError {
    fn from(error: AccountError) -> Self {
        match error {
            AccountError::Invalid(message) => Self::validation(message),
            AccountError::UsernameTaken(name) => {
                Self::conflict(format!("The username {name} is already taken."))
            }
            AccountError::NotFound => Self::not_found(),
            AccountError::LastOwner => Self::conflict(
                "The server needs at least one active owner. Make someone else an owner first.",
            ),
            AccountError::Database(error) => {
                tracing::error!(%error, "database error");
                Self::internal()
            }
        }
    }
}

impl From<anyhow::Error> for ApiError {
    fn from(error: anyhow::Error) -> Self {
        tracing::error!(error = format!("{error:#}"), "request failed");
        Self::internal()
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let mut body = json!({ "error": self.code, "message": self.message });
        if let Some(offset) = self.offset {
            body["offset"] = json!(offset);
        }
        let mut response = (self.status, Json(body)).into_response();
        if let Some(offset) = self.offset {
            response
                .headers_mut()
                .insert(super::uploads::UPLOAD_OFFSET, HeaderValue::from(offset));
        }
        if let Some(seconds) = self.retry_after {
            response
                .headers_mut()
                .insert(header::RETRY_AFTER, HeaderValue::from(seconds));
        }
        response
    }
}
