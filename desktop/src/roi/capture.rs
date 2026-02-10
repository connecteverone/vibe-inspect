use scrap::{Capturer, Display, Frame, TraitCapturer, TraitPixelBuffer};
use std::io::ErrorKind;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

pub struct RoiFrame {
    pub data: Vec<u8>,
    pub width: usize,
    pub height: usize,
}

pub struct RoiCapturer {
    capturer: Capturer,
    capture_width: usize,
    capture_height: usize,
    fallback_width: usize,
    fallback_height: usize,
}

impl RoiCapturer {
    pub fn new(
        display_index: Option<usize>,
        fallback_width: u32,
        fallback_height: u32,
    ) -> Result<Self, String> {
        let display = resolve_display(display_index)?;
        let init_lock = CAPTURE_INIT_LOCK.get_or_init(|| Mutex::new(()));
        let _guard = match init_lock.lock() {
            Ok(lock) => lock,
            Err(poisoned) => poisoned.into_inner(),
        };
        let capturer = Capturer::new(display)
            .map_err(|error| format!("Unable to capture display: {error}"))?;
        let (capture_width, capture_height) =
            resolve_capture_dimensions(display_index.unwrap_or(0), fallback_width, fallback_height);
        Ok(Self {
            capturer,
            capture_width: capture_width as usize,
            capture_height: capture_height as usize,
            fallback_width: fallback_width as usize,
            fallback_height: fallback_height as usize,
        })
    }

    pub fn capture(&mut self) -> Option<RoiFrame> {
        match self.capturer.frame(Duration::from_millis(0)) {
            Ok(frame) => match frame {
                Frame::PixelBuffer(pixelbuffer) => {
                    let frame_bytes = pixelbuffer.data();
                    let mut width = pixelbuffer.width();
                    let mut height = pixelbuffer.height();
                    if width == 0 || height == 0 {
                        width = self.capture_width;
                        height = self.capture_height;
                    }
                    if width == 0 || height == 0 {
                        return None;
                    }
                    let mut stride = pixelbuffer.stride().get(0).copied().unwrap_or(0);
                    if stride == 0 {
                        stride = if frame_bytes.len() % height == 0 {
                            frame_bytes.len() / height
                        } else {
                            0
                        };
                    }
                    let expected_min = width.saturating_mul(height).saturating_mul(4);
                    if frame_bytes.len() >= expected_min && stride == 0 {
                        let extra = frame_bytes.len().saturating_sub(expected_min);
                        if extra % height != 0 {
                            stride = width.saturating_mul(4);
                        }
                    }
                    let frame_len = frame_bytes.len();
                    if frame_len < expected_min || stride == 0 || stride < width * 4 {
                        if let Some((guess_w, guess_h, guess_stride)) = guess_capture_dimensions(
                            frame_len,
                            self.fallback_width,
                            self.fallback_height,
                        ) {
                            width = guess_w;
                            height = guess_h;
                            stride = guess_stride;
                        } else {
                            return None;
                        }
                    }
                    let expected_min = width.saturating_mul(height).saturating_mul(4);
                    if frame_len < expected_min || stride < width * 4 {
                        return None;
                    }
                    let data = extract_frame(frame_bytes, stride, width, height)?;
                    Some(RoiFrame {
                        data,
                        width,
                        height,
                    })
                }
                Frame::Texture(_) => None,
            },
            Err(error) if error.kind() == ErrorKind::WouldBlock => None,
            Err(_) => None,
        }
    }
}

static CAPTURE_INIT_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn resolve_display(display_index: Option<usize>) -> Result<Display, String> {
    if let Some(index) = display_index {
        let mut displays =
            Display::all().map_err(|error| format!("Unable to list displays: {error}"))?;
        if index >= displays.len() {
            return Err(format!("Display index {index} is out of range."));
        }
        return Ok(displays.swap_remove(index));
    }
    Display::primary().map_err(|error| format!("Unable to access primary display: {error}"))
}

#[cfg(target_os = "macos")]
fn resolve_capture_dimensions(
    display_index: usize,
    fallback_width: u32,
    fallback_height: u32,
) -> (u32, u32) {
    use core_graphics::display::CGDisplay;
    let mut display = CGDisplay::main();
    if let Ok(displays) = CGDisplay::active_displays() {
        if display_index < displays.len() {
            display = CGDisplay::new(displays[display_index]);
        }
    }
    let width = display.pixels_wide() as u32;
    let height = display.pixels_high() as u32;
    if width > 0 && height > 0 {
        return (width, height);
    }
    (fallback_width, fallback_height)
}

#[cfg(not(target_os = "macos"))]
fn resolve_capture_dimensions(
    _display_index: usize,
    fallback_width: u32,
    fallback_height: u32,
) -> (u32, u32) {
    (fallback_width, fallback_height)
}

fn guess_capture_dimensions(
    frame_len: usize,
    logical_width: usize,
    logical_height: usize,
) -> Option<(usize, usize, usize)> {
    if logical_width == 0 || logical_height == 0 || frame_len == 0 {
        return None;
    }
    let mut best: Option<(usize, usize, usize, usize)> = None;
    for scale in 1..=4 {
        let height = logical_height.saturating_mul(scale);
        if height == 0 || frame_len % height != 0 {
            continue;
        }
        let stride = frame_len / height;
        if stride < 4 {
            continue;
        }
        let width = logical_width.saturating_mul(scale);
        if width == 0 || stride < width * 4 {
            continue;
        }
        let padding = stride - width * 4;
        match best {
            Some((_, _, _, best_padding)) if padding >= best_padding => {}
            _ => best = Some((width, height, stride, padding)),
        }
    }
    best.map(|(width, height, stride, _)| (width, height, stride))
}

fn extract_frame(frame: &[u8], stride: usize, width: usize, height: usize) -> Option<Vec<u8>> {
    let expected = width.saturating_mul(height).saturating_mul(4);
    if expected == 0 || frame.len() < stride.saturating_mul(height) {
        return None;
    }
    let mut data = vec![0u8; expected];
    for y in 0..height {
        let src_start = y * stride;
        let src_end = src_start + width * 4;
        if src_end > frame.len() {
            return None;
        }
        let dst_start = y * width * 4;
        data[dst_start..dst_start + width * 4].copy_from_slice(&frame[src_start..src_end]);
    }
    Some(data)
}
