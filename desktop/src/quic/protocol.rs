use serde::{Deserialize, Serialize};

pub const ROI_DATAGRAM_MAGIC: &[u8; 4] = b"ROI1";
pub const ROI_DATAGRAM_HEADER_SIZE: usize = 28;
pub const ROI_CODEC_RAW: u8 = 0;
pub const ROI_CODEC_ZLIB: u8 = 1;

pub const VNC_DATAGRAM_MAGIC: &[u8; 4] = b"VQC1";
pub const VNC_DATAGRAM_VERSION: u8 = 1;
pub const VNC_DATAGRAM_HEADER_SIZE: usize = 22;

pub const VNC_CHANNEL_VIDEO_DELTA: u8 = 1;
pub const VNC_CHANNEL_VIDEO_KEYFRAME: u8 = 2;
pub const VNC_CHANNEL_ROI_TILE: u8 = 3;

pub const VNC_FLAG_KEYFRAME: u8 = 1 << 0;
pub const VNC_FLAG_COMPRESSED: u8 = 1 << 1;
pub const VNC_FLAG_HAS_FEC: u8 = 1 << 2;

pub const VNC_CODEC_RFB: u8 = 0;
pub const VNC_CODEC_ZLIB: u8 = 1;
pub const VNC_CODEC_TIGHT: u8 = 2;
pub const VNC_CODEC_H264: u8 = 3;
pub const VNC_CODEC_H265: u8 = 4;
pub const VNC_CODEC_AV1: u8 = 5;

#[derive(Debug, Clone, Copy)]
pub struct VncDatagramHeader {
    pub version: u8,
    pub channel: u8,
    pub flags: u8,
    pub codec: u8,
    pub seq: u32,
    pub frame_id: u32,
    pub chunk_index: u16,
    pub chunk_count: u16,
    pub payload_len: u16,
}

pub fn encode_vnc_datagram_chunks(
    payload: &[u8],
    seq: u32,
    frame_id: u32,
    channel: u8,
    flags: u8,
    codec: u8,
    max_datagram: usize,
) -> Result<Vec<Vec<u8>>, String> {
    if max_datagram <= VNC_DATAGRAM_HEADER_SIZE {
        return Err("max datagram size too small".to_string());
    }
    let max_payload = max_datagram - VNC_DATAGRAM_HEADER_SIZE;
    if max_payload == 0 {
        return Err("max payload size too small".to_string());
    }
    let chunk_count = ((payload.len() + max_payload - 1) / max_payload).max(1);
    if chunk_count > u16::MAX as usize {
        return Err("payload requires too many datagram chunks".to_string());
    }
    let mut out = Vec::with_capacity(chunk_count);
    for chunk_index in 0..chunk_count {
        let start = chunk_index * max_payload;
        let end = (start + max_payload).min(payload.len());
        let chunk = &payload[start..end];
        let header = VncDatagramHeader {
            version: VNC_DATAGRAM_VERSION,
            channel,
            flags,
            codec,
            seq,
            frame_id,
            chunk_index: chunk_index as u16,
            chunk_count: chunk_count as u16,
            payload_len: chunk.len().min(u16::MAX as usize) as u16,
        };
        let mut buffer = Vec::with_capacity(VNC_DATAGRAM_HEADER_SIZE + chunk.len());
        buffer.extend_from_slice(VNC_DATAGRAM_MAGIC);
        buffer.push(header.version);
        buffer.push(header.channel);
        buffer.push(header.flags);
        buffer.push(header.codec);
        buffer.extend_from_slice(&header.seq.to_le_bytes());
        buffer.extend_from_slice(&header.frame_id.to_le_bytes());
        buffer.extend_from_slice(&header.chunk_index.to_le_bytes());
        buffer.extend_from_slice(&header.chunk_count.to_le_bytes());
        buffer.extend_from_slice(&header.payload_len.to_le_bytes());
        buffer.extend_from_slice(chunk);
        out.push(buffer);
    }
    Ok(out)
}

pub fn decode_vnc_datagram_header(data: &[u8]) -> Option<VncDatagramHeader> {
    if data.len() < VNC_DATAGRAM_HEADER_SIZE {
        return None;
    }
    if &data[..4] != VNC_DATAGRAM_MAGIC {
        return None;
    }
    let version = data[4];
    let channel = data[5];
    let flags = data[6];
    let codec = data[7];
    let seq = u32::from_le_bytes(data[8..12].try_into().ok()?);
    let frame_id = u32::from_le_bytes(data[12..16].try_into().ok()?);
    let chunk_index = u16::from_le_bytes(data[16..18].try_into().ok()?);
    let chunk_count = u16::from_le_bytes(data[18..20].try_into().ok()?);
    let payload_len = u16::from_le_bytes(data[20..22].try_into().ok()?);
    Some(VncDatagramHeader {
        version,
        channel,
        flags,
        codec,
        seq,
        frame_id,
        chunk_index,
        chunk_count,
        payload_len,
    })
}

#[derive(Debug, Deserialize, Serialize)]
pub struct RoiHello {
    pub session_id: String,
    pub token: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct RoiReady {
    pub status: String,
    pub session_id: String,
    pub max_datagram_size: usize,
    pub quic_port: u16,
    pub display_index: Option<usize>,
    pub framebuffer_width: u32,
    pub framebuffer_height: u32,
    pub screen_width: u32,
    pub screen_height: u32,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct RoiRequest {
    pub center_x: f64,
    pub center_y: f64,
    pub zoom: f64,
    pub viewport_width: f64,
    pub viewport_height: f64,
    pub prefetch_radius: f64,
}

impl RoiRequest {
    pub fn is_valid(&self) -> bool {
        self.center_x.is_finite()
            && self.center_y.is_finite()
            && self.zoom.is_finite()
            && self.viewport_width.is_finite()
            && self.viewport_height.is_finite()
            && self.prefetch_radius.is_finite()
    }
}

#[derive(Debug, Deserialize, Serialize)]
pub struct VncHello {
    #[serde(rename = "type")]
    pub message_type: String,
    pub session_id: String,
    pub token: String,
    pub auth_token: Option<String>,
    pub client_id: Option<String>,
    pub client_name: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct VncReady {
    pub status: String,
    pub session_id: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct VncError {
    pub status: String,
    pub code: String,
    pub message: String,
    pub retry_after: Option<u64>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct RemoteHello {
    #[serde(rename = "type")]
    pub message_type: String,
    pub session_id: String,
    pub token: String,
    pub auth_token: Option<String>,
    pub client_id: Option<String>,
    pub client_name: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct RemoteReady {
    pub status: String,
    pub session_id: String,
    pub data_stream: String,
    pub codec_preference: Option<String>,
    pub hwcodec: Option<bool>,
    pub idle_timeout_ms: Option<u64>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct RemoteError {
    pub status: String,
    pub code: String,
    pub message: String,
    pub retry_after: Option<u64>,
}
