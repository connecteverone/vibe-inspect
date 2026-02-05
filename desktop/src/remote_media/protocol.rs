use crate::remote_media::{FrameMeta, RoiRect, VideoCodec};

const MAGIC: [u8; 2] = [0x56, 0x32];
const VERSION: u8 = 1;

pub const FLAG_KEYFRAME: u8 = 0x01;
pub const FLAG_HAS_ROI: u8 = 0x02;
pub const FLAG_ZLIB: u8 = 0x04;

pub fn encode_header(
    meta: &FrameMeta,
    codec: VideoCodec,
    roi: Option<RoiRect>,
    payload_len: u32,
    extra_flags: u8,
) -> Vec<u8> {
    let mut flags = extra_flags;
    if meta.keyframe {
        flags |= FLAG_KEYFRAME;
    }
    if roi.is_some() {
        flags |= FLAG_HAS_ROI;
    }
    let (rx, ry, rw, rh) = roi
        .map(|r| (r.x, r.y, r.w, r.h))
        .unwrap_or((0, 0, 0, 0));
    let mut buf = Vec::with_capacity(33);
    buf.extend_from_slice(&MAGIC);
    buf.push(VERSION);
    buf.push(flags);
    buf.extend_from_slice(&meta.seq.to_be_bytes());
    buf.extend_from_slice(&meta.timestamp_ms.to_be_bytes());
    buf.push(codec_id(codec));
    buf.extend_from_slice(&meta.width.to_be_bytes());
    buf.extend_from_slice(&meta.height.to_be_bytes());
    buf.extend_from_slice(&rx.to_be_bytes());
    buf.extend_from_slice(&ry.to_be_bytes());
    buf.extend_from_slice(&rw.to_be_bytes());
    buf.extend_from_slice(&rh.to_be_bytes());
    buf.extend_from_slice(&payload_len.to_be_bytes());
    buf
}

fn codec_id(codec: VideoCodec) -> u8 {
    match codec {
        VideoCodec::RawRgba => 0,
        VideoCodec::H264 => 1,
        VideoCodec::H265 => 2,
        VideoCodec::Av1 => 3,
    }
}
