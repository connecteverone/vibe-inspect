use std::collections::HashMap;

use crate::roi::RoiSessionInfo;
use crate::roi::capture::RoiFrame;

#[derive(Clone, Debug)]
pub struct RoiViewport {
    pub center_x: f64,
    pub center_y: f64,
    pub viewport_width: f64,
    pub viewport_height: f64,
    pub prefetch_radius: f64,
    #[allow(dead_code)]
    pub zoom: f64,
}

#[derive(Clone, Debug)]
pub struct RoiTile {
    pub logical_x: u16,
    pub logical_y: u16,
    pub logical_w: u16,
    pub logical_h: u16,
    pub pixel_w: u16,
    pub pixel_h: u16,
    pub pixels: Vec<u8>,
    pub frame_id: u32,
}

pub struct RoiTileCache {
    hashes: HashMap<(u16, u16, u16, u16), u64>,
}

impl RoiTileCache {
    pub fn new() -> Self {
        Self {
            hashes: HashMap::new(),
        }
    }

    pub fn should_send(&mut self, tile: &RoiTile) -> bool {
        let hash = fnv1a_hash(&tile.pixels);
        let key = (tile.logical_x, tile.logical_y, tile.logical_w, tile.logical_h);
        if let Some(prev) = self.hashes.get(&key) {
            if *prev == hash {
                return false;
            }
        }
        self.hashes.insert(key, hash);
        if self.hashes.len() > 4096 {
            self.hashes.clear();
        }
        true
    }
}

pub fn build_tiles(
    frame: &RoiFrame,
    info: &RoiSessionInfo,
    viewport: &RoiViewport,
    tile_size: u32,
    frame_id: u32,
    scan_reverse: bool,
    budget: usize,
    cache: &mut RoiTileCache,
) -> Vec<RoiTile> {
    if info.framebuffer_width == 0
        || info.framebuffer_height == 0
        || frame.width == 0
        || frame.height == 0
    {
        return Vec::new();
    }
    let tile_size = tile_size.max(8) as usize;
    let scale_x = frame.width as f64 / info.framebuffer_width as f64;
    let scale_y = frame.height as f64 / info.framebuffer_height as f64;
    let half_w = viewport.viewport_width.max(1.0) / 2.0;
    let half_h = viewport.viewport_height.max(1.0) / 2.0;
    let mut left = viewport.center_x - half_w - viewport.prefetch_radius;
    let mut top = viewport.center_y - half_h - viewport.prefetch_radius;
    let mut right = viewport.center_x + half_w + viewport.prefetch_radius;
    let mut bottom = viewport.center_y + half_h + viewport.prefetch_radius;
    left = left.clamp(0.0, info.framebuffer_width as f64);
    top = top.clamp(0.0, info.framebuffer_height as f64);
    right = right.clamp(0.0, info.framebuffer_width as f64);
    bottom = bottom.clamp(0.0, info.framebuffer_height as f64);
    if right <= left || bottom <= top {
        return Vec::new();
    }
    let phys_left = (left * scale_x).floor() as i64;
    let phys_top = (top * scale_y).floor() as i64;
    let phys_right = (right * scale_x).ceil() as i64;
    let phys_bottom = (bottom * scale_y).ceil() as i64;
    let phys_left = phys_left.clamp(0, frame.width as i64) as usize;
    let phys_top = phys_top.clamp(0, frame.height as i64) as usize;
    let phys_right = phys_right.clamp(0, frame.width as i64) as usize;
    let phys_bottom = phys_bottom.clamp(0, frame.height as i64) as usize;
    if phys_right <= phys_left || phys_bottom <= phys_top {
        return Vec::new();
    }

    let mut tiles = Vec::new();
    let mut sent = 0usize;
    let max_x = phys_right.min(frame.width);
    let max_y = phys_bottom.min(frame.height);
    if !scan_reverse {
        let mut y = phys_top;
        while y < max_y {
            let mut x = phys_left;
            let tile_h = tile_size.min(max_y - y);
            while x < max_x {
                let tile_w = tile_size.min(max_x - x);
                if tile_w == 0 || tile_h == 0 {
                    break;
                }
                let (logical_left, logical_right) = map_physical_to_logical_bounds(
                    x,
                    x + tile_w,
                    info.framebuffer_width,
                    frame.width,
                );
                let (logical_top, logical_bottom) = map_physical_to_logical_bounds(
                    y,
                    y + tile_h,
                    info.framebuffer_height,
                    frame.height,
                );
                let logical_w = logical_right.saturating_sub(logical_left).max(1);
                let logical_h = logical_bottom.saturating_sub(logical_top).max(1);
                let tile = RoiTile {
                    logical_x: logical_left.min(u16::MAX as u32) as u16,
                    logical_y: logical_top.min(u16::MAX as u32) as u16,
                    logical_w: logical_w.min(u16::MAX as u32) as u16,
                    logical_h: logical_h.min(u16::MAX as u32) as u16,
                    pixel_w: tile_w as u16,
                    pixel_h: tile_h as u16,
                    pixels: extract_tile(frame, x, y, tile_w, tile_h),
                    frame_id,
                };
                if cache.should_send(&tile) {
                    tiles.push(tile);
                    sent += 1;
                    if sent >= budget {
                        return tiles;
                    }
                }
                x += tile_w;
            }
            y += tile_h;
        }
        return tiles;
    }

    let mut y = max_y;
    while y > phys_top {
        let tile_h = tile_size.min(y - phys_top);
        y -= tile_h;
        let mut x = max_x;
        while x > phys_left {
            let tile_w = tile_size.min(x - phys_left);
            x -= tile_w;
            if tile_w == 0 || tile_h == 0 {
                break;
            }
            let (logical_left, logical_right) = map_physical_to_logical_bounds(
                x,
                x + tile_w,
                info.framebuffer_width,
                frame.width,
            );
            let (logical_top, logical_bottom) = map_physical_to_logical_bounds(
                y,
                y + tile_h,
                info.framebuffer_height,
                frame.height,
            );
            let logical_w = logical_right.saturating_sub(logical_left).max(1);
            let logical_h = logical_bottom.saturating_sub(logical_top).max(1);
            let tile = RoiTile {
                logical_x: logical_left.min(u16::MAX as u32) as u16,
                logical_y: logical_top.min(u16::MAX as u32) as u16,
                logical_w: logical_w.min(u16::MAX as u32) as u16,
                logical_h: logical_h.min(u16::MAX as u32) as u16,
                pixel_w: tile_w as u16,
                pixel_h: tile_h as u16,
                pixels: extract_tile(frame, x, y, tile_w, tile_h),
                frame_id,
            };
            if cache.should_send(&tile) {
                tiles.push(tile);
                sent += 1;
                if sent >= budget {
                    return tiles;
                }
            }
        }
    }
    tiles
}

fn map_physical_to_logical_bounds(
    start: usize,
    end: usize,
    logical: u32,
    physical: usize,
) -> (u32, u32) {
    if logical == 0 || physical == 0 || end <= start {
        return (0, 0);
    }
    let logical = logical as u64;
    let physical = physical as u64;
    let start = start as u64;
    let end = end as u64;
    let left = div_ceil(start.saturating_mul(logical), physical).min(logical);
    let right = div_ceil(end.saturating_mul(logical), physical).min(logical);
    (left as u32, right as u32)
}

fn div_ceil(numerator: u64, denominator: u64) -> u64 {
    if denominator == 0 {
        return 0;
    }
    (numerator + denominator - 1) / denominator
}

fn extract_tile(frame: &RoiFrame, x: usize, y: usize, width: usize, height: usize) -> Vec<u8> {
    let mut pixels = vec![0u8; width * height * 4];
    let stride = frame.width * 4;
    for row in 0..height {
        let src_start = (y + row) * stride + x * 4;
        let src_end = src_start + width * 4;
        let dst_start = row * width * 4;
        pixels[dst_start..dst_start + width * 4]
            .copy_from_slice(&frame.data[src_start..src_end]);
    }
    pixels
}

fn fnv1a_hash(data: &[u8]) -> u64 {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in data {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::map_physical_to_logical_bounds;

    fn brute_bounds(
        start: usize,
        end: usize,
        logical: u32,
        physical: usize,
    ) -> Option<(u32, u32)> {
        if logical == 0 || physical == 0 || end <= start {
            return None;
        }
        let mut min: Option<u32> = None;
        let mut max: u32 = 0;
        for l in 0..logical {
            let phys = (l as usize * physical) / logical as usize;
            if phys >= start && phys < end {
                min = Some(min.map_or(l, |v| v.min(l)));
                if l > max {
                    max = l;
                }
            }
        }
        min.map(|min| (min, max + 1))
    }

    #[test]
    fn map_physical_to_logical_matches_vnc_sampling() {
        let cases = [
            (1920usize, 1080u32),
            (1440usize, 927u32),
            (2560usize, 1440u32),
            (1280usize, 720u32),
        ];
        for (physical, logical) in cases {
            let mut x0 = 0usize;
            while x0 < physical {
                let x1 = (x0 + 64).min(physical);
                let expected = brute_bounds(x0, x1, logical, physical)
                    .expect("expected logical coverage");
                let actual = map_physical_to_logical_bounds(x0, x1, logical, physical);
                assert_eq!(
                    expected, actual,
                    "physical [{x0},{x1}) logical {logical} physical {physical}"
                );
                x0 += 37;
            }
        }
    }
}
