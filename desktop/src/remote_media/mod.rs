use std::time::Duration;

pub mod protocol;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoCodec {
    RawRgba,
    H264,
    H265,
    Av1,
}

#[derive(Debug, Clone, Copy)]
pub struct FrameMeta {
    pub seq: u32,
    pub timestamp_ms: u64,
    pub width: u16,
    pub height: u16,
    pub keyframe: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct RoiRect {
    pub x: u16,
    pub y: u16,
    pub w: u16,
    pub h: u16,
}

#[derive(Debug, Clone)]
pub struct CaptureFrame {
    pub meta: FrameMeta,
    pub roi: Option<RoiRect>,
    pub rgba: Vec<u8>,
}

pub trait CaptureSource: Send {
    fn start(&mut self) -> Result<(), String>;
    fn stop(&mut self);
    fn next_frame(&mut self, timeout: Duration) -> Option<CaptureFrame>;
    fn set_roi(&mut self, roi: Option<RoiRect>);
}

#[derive(Debug, Clone)]
pub struct EncodedFrame {
    pub meta: FrameMeta,
    pub roi: Option<RoiRect>,
    pub codec: VideoCodec,
    pub payload: Vec<u8>,
}

pub trait VideoEncoder: Send {
    fn codec(&self) -> VideoCodec;
    fn configure(&mut self, width: u32, height: u32) -> Result<(), String>;
    fn encode(&mut self, frame: CaptureFrame) -> Result<EncodedFrame, String>;
    fn force_keyframe(&mut self);
}

pub trait FrameTransport: Send {
    fn send(&mut self, frame: EncodedFrame) -> Result<(), String>;
}
