#[derive(Debug, Clone, Copy)]
pub enum RoiErrorCode {
    InvalidPayload,
    MissingPayload,
    UnsupportedAction,
    RoiQuicPortBusy,
    RoiQuicPortUnavailable,
}

impl RoiErrorCode {
    pub const fn as_str(self) -> &'static str {
        match self {
            RoiErrorCode::InvalidPayload => "invalid_payload",
            RoiErrorCode::MissingPayload => "missing_payload",
            RoiErrorCode::UnsupportedAction => "unsupported_action",
            RoiErrorCode::RoiQuicPortBusy => "roi_quic_port_busy",
            RoiErrorCode::RoiQuicPortUnavailable => "roi_quic_port_unavailable",
        }
    }
}
